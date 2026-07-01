import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:workmanager/workmanager.dart';

import '../../features/settings/data/alert_config_repository.dart';
import '../../features/settings/models/alert_config.dart';
import '../../features/thermostats/data/thermostat_client.dart';
import '../../features/thermostats/data/thermostat_database.dart';
import '../../features/thermostats/data/thermostat_reading_utils.dart';
import '../../features/thermostats/data/thermostat_repository.dart';
import '../../features/thermostats/data/thermostat_service.dart';
import '../../features/thermostats/models/thermostat.dart';
import '../../features/thermostats/models/thermostat_state.dart';
import '../router/app_router.dart';
import '../router/router_keys.dart';

// WorkManager now only restarts the foreground service if it's dead — it
// never performs the monitor run itself (see `_runWatchdogTask`).
const String thermostatWatchdogTask = 'thermostat_watchdog_task';
const String thermostatWatchdogUniqueName = 'thermostat_monitor_periodic';

const String _monitoringChannelId = 'farmctl_monitoring';
const String _monitoringChannelName = 'Thermostat monitoring';
const String _monitoringChannelDescription =
    'Shows when FarmCtl is checking thermostats in the background.';
const int _foregroundServiceId = 256;

const String _alarmChannelPrefix = 'farmctl_alarm';
const String _alarmChannelName = 'Thermostat alarms';
const String _alarmChannelDescription =
    'Alerts when a thermostat leaves the configured range.';
const String _defaultAlarmSoundUri = 'content://settings/system/alarm_alert';

const int _alarmNotificationBaseId = 4000;

// WorkManager can't run more often than every 15 minutes; the watchdog only
// needs to notice a dead foreground service, not track the user's poll
// interval, so it always uses the platform floor.
const Duration _watchdogFrequency = Duration(minutes: 15);

// Cadence used when the real poll interval can't be loaded (config/DB
// transiently unreadable), so the service keeps retrying at a sane pace.
const Duration _fallbackPollInterval = Duration(minutes: 5);

// Secondary safety net behind the in-isolate `_monitorRunInProgress` lock (see
// below): collapses a near-simultaneous onStart + onRepeatEvent fire into a
// single monitor run if they ever reach the DB check before the lock is set.
// Kept well short of the 60s+ gap between legitimate consecutive runs.
const Duration _monitorRunDebounce = Duration(seconds: 10);

bool get _supportsForegroundService => !kIsWeb && Platform.isAndroid;

/// Converts [pollInterval] to milliseconds for the foreground service's
/// `onRepeatEvent` cadence, clamped to a defensive floor so a corrupt/zero
/// config value can't spin the repeat loop unreasonably fast. Pure for
/// testability.
int pollIntervalMillis(
  Duration pollInterval, {
  Duration minimum = const Duration(seconds: 30),
}) {
  final effective = pollInterval < minimum ? minimum : pollInterval;
  return effective.inMilliseconds;
}

/// The cadence the foreground service should tick at for [config] at [nowUtc].
///
/// During an active pause that is longer than one poll interval, the service
/// sleeps until the pause ends instead of waking every interval only to notice
/// it's paused and bail — so the remaining pause is used as the interval. A
/// single tick then fires at the pause end and, seeing monitoring un-paused,
/// resets the cadence back to the poll interval. Pure for testability.
Duration effectiveServiceInterval(AlertConfig config, DateTime nowUtc) {
  final remaining = config.remainingPause(nowUtc);
  if (remaining != null && remaining > config.pollInterval) {
    return remaining;
  }
  return config.pollInterval;
}

/// How the ongoing "monitoring" notification should change after a run.
enum MonitorNotificationAction { none, showDegraded, showHealthy }

/// After 2 consecutive failed runs the notification is flipped once to show
/// that monitoring is broken.
const int _monitorFailureThreshold = 2;

/// Pure state transition for the ongoing-notification health indicator, given
/// the [failures] seen so far and whether the notification is already
/// [degraded]. Escalates only after [threshold] consecutive failures (so a
/// single transient blip doesn't trip it) and only emits an action on the
/// healthy<->degraded transition, so a steady state makes no platform calls.
({int failures, bool degraded, MonitorNotificationAction action})
nextMonitorHealth({
  required int failures,
  required bool degraded,
  required bool runSucceeded,
  int threshold = _monitorFailureThreshold,
}) {
  if (runSucceeded) {
    return (
      failures: 0,
      degraded: false,
      action: degraded
          ? MonitorNotificationAction.showHealthy
          : MonitorNotificationAction.none,
    );
  }
  final nextFailures = failures + 1;
  final reachedThreshold = nextFailures >= threshold;
  return (
    failures: nextFailures,
    degraded: degraded || reachedThreshold,
    action: (reachedThreshold && !degraded)
        ? MonitorNotificationAction.showDegraded
        : MonitorNotificationAction.none,
  );
}

ForegroundTaskOptions _foregroundTaskOptions(Duration pollInterval) {
  return ForegroundTaskOptions(
    eventAction: ForegroundTaskEventAction.repeat(
      pollIntervalMillis(pollInterval),
    ),
    autoRunOnBoot: true,
    autoRunOnMyPackageReplaced: true,
    allowWakeLock: true,
  );
}

/// Starts (or reconfigures) the foreground service that drives every monitor
/// run. Unlike the old WorkManager+AlarmManager pair, a live foreground
/// service is exempt from Doze/App Standby deferral, so this is the single
/// source of truth for polling cadence — no exact-alarm permission needed.
///
/// Returns whether the service is confirmed running/updated, so a caller like
/// the watchdog can propagate a failure instead of reporting success for a
/// service that never actually started.
Future<bool> _ensureForegroundServiceRunning(Duration pollInterval) async {
  if (!_supportsForegroundService) {
    return true;
  }

  try {
    final running = await FlutterForegroundTask.isRunningService;
    if (running) {
      final result = await FlutterForegroundTask.updateService(
        foregroundTaskOptions: _foregroundTaskOptions(pollInterval),
      );
      if (result is ServiceRequestFailure) {
        debugPrint('Failed to update monitoring service: ${result.error}');
        return false;
      }
      return true;
    }

    // init() populates isolate-local static config that startService() reads
    // (updateService() doesn't need it — it's a self-contained call), so it
    // only needs to run on this, the cold-start, path.
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: _monitoringChannelId,
        channelName: _monitoringChannelName,
        channelDescription: _monitoringChannelDescription,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: _foregroundTaskOptions(pollInterval),
    );

    final result = await FlutterForegroundTask.startService(
      serviceId: _foregroundServiceId,
      serviceTypes: const [ForegroundServiceTypes.specialUse],
      notificationTitle: 'FarmCtl monitoring',
      notificationText: 'Monitoring active',
      callback: thermostatForegroundTaskCallback,
    );
    if (result is ServiceRequestFailure) {
      debugPrint('Failed to start monitoring service: ${result.error}');
      return false;
    }
    return true;
  } catch (error, stackTrace) {
    debugPrint('Failed to ensure monitoring service is running: $error');
    debugPrint('$stackTrace');
    return false;
  }
}

/// Entry point run in the foreground service's own isolate; must be a
/// top-level function per the flutter_foreground_task contract.
@pragma('vm:entry-point')
void thermostatForegroundTaskCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  ui.DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_ThermostatMonitorTaskHandler());
}

class _ThermostatMonitorTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Check immediately on start (fresh install, reboot, or a watchdog
    // restart) rather than waiting a full poll interval for the first read.
    unawaited(_runMonitorTask());
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_runMonitorTask());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

const String _snooze5ActionId = 'alarm_snooze_5';
const String _snooze10ActionId = 'alarm_snooze_10';
const String _snooze30ActionId = 'alarm_snooze_30';
const String _silenceActionId = 'alarm_silence_until_ok';

/// Maps a notification snooze action id to its snooze duration, or null when the
/// action is not a snooze (silence, body tap, or unknown). Pure for testability.
Duration? snoozeDurationForAction(String? actionId) {
  switch (actionId) {
    case _snooze5ActionId:
      return const Duration(minutes: 5);
    case _snooze10ActionId:
      return const Duration(minutes: 10);
    case _snooze30ActionId:
      return const Duration(minutes: 30);
    default:
      return null;
  }
}

Future<void> initializeBackgroundMonitoring({Duration? pollFrequency}) async {
  final notifications = FlutterLocalNotificationsPlugin();

  AlertConfig? config;
  final database = ThermostatDatabase();
  try {
    config = await AlertConfigRepository(database).loadConfig();
  } catch (error, stackTrace) {
    debugPrint('Failed to load alert config for scheduling: $error');
    debugPrint('$stackTrace');
  } finally {
    await database.close();
  }

  await _initializeNotifications(
    notifications,
    onDidReceiveNotificationResponse: _handleNotificationResponse,
    config: config,
  );

  final configuredInterval =
      pollFrequency ?? config?.pollInterval ?? _fallbackPollInterval;

  // The foreground service is the single source of truth for polling cadence.
  // Pause-stretching (sleeping the service until a pause ends) is handled
  // solely by the service isolate's own reconcile — see _reconcileServiceInterval
  // — so its cadence memo stays consistent; this always uses the plain interval.
  await _ensureForegroundServiceRunning(configuredInterval);

  // WorkManager is demoted to a watchdog: it only restarts the foreground
  // service if the OS killed the whole app process, never runs the monitor
  // itself, so it can't double-poll alongside the live service.
  await Workmanager().initialize(thermostatMonitorCallbackDispatcher);
  await Workmanager().registerPeriodicTask(
    thermostatWatchdogUniqueName,
    thermostatWatchdogTask,
    frequency: _watchdogFrequency,
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    constraints: Constraints(networkType: NetworkType.connected),
  );
}

// Entry point used by the Android BootCompletedReceiver to restore scheduling
// after device reboot or app update without launching the full UI.
@pragma('vm:entry-point')
Future<void> initializeMonitoringOnBoot() async {
  WidgetsFlutterBinding.ensureInitialized();
  ui.DartPluginRegistrant.ensureInitialized();
  try {
    await initializeBackgroundMonitoring();
  } catch (error, stackTrace) {
    debugPrint('Boot init failed: $error');
    debugPrint('$stackTrace');
  }
}

@pragma('vm:entry-point')
void thermostatMonitorCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    // Returning false on failure lets WorkManager retry with backoff instead of
    // waiting a full period after a transient error.
    return _runWatchdogTask();
  });
}

/// Restarts the foreground service if it isn't running. Does not fetch or
/// write thermostat data itself — the live service already handles that.
///
/// Not redundant with the plugin's own `allowAutoRestart`/`autoRunOnBoot`:
/// those recover from the OS killing the *service* (or a device reboot), but
/// not from an OEM battery manager killing the whole app *process* outside
/// of a device reboot — which is the actual Pixel 9 failure mode this file
/// was reworked for. WorkManager's periodic work is OS-scheduled
/// (JobScheduler-backed) independent of the app process being alive, so it
/// still fires and can relaunch a fresh process. (A user-initiated "Force
/// stop" is the one thing nothing here can survive — Android deliberately
/// suspends all of an app's scheduled work, including WorkManager, until the
/// user manually reopens it.)
Future<bool> _runWatchdogTask() async {
  WidgetsFlutterBinding.ensureInitialized();
  ui.DartPluginRegistrant.ensureInitialized();

  if (!_supportsForegroundService) {
    return true;
  }

  try {
    if (await FlutterForegroundTask.isRunningService) {
      return true;
    }

    debugPrint('Watchdog: monitoring service is not running; restarting.');
    final database = ThermostatDatabase();
    AlertConfig? config;
    try {
      config = await AlertConfigRepository(database).loadConfig();
    } finally {
      await database.close();
    }

    // Propagate a failed restart so WorkManager retries with backoff instead
    // of waiting the full 15-minute watchdog period while monitoring is dead.
    return await _ensureForegroundServiceRunning(config.pollInterval);
  } catch (error, stackTrace) {
    debugPrint('Watchdog failed to restart monitoring service: $error');
    debugPrint('$stackTrace');
    return false;
  }
}

/// Whether a monitor run that observed [lastRunStartedAt] should be skipped
/// because another run started within [debounce]. Pure for testability.
bool shouldSkipMonitorRun({
  required DateTime? lastRunStartedAt,
  required DateTime now,
  Duration debounce = _monitorRunDebounce,
}) {
  if (lastRunStartedAt == null) {
    return false;
  }
  final elapsed = now.difference(lastRunStartedAt);
  return elapsed >= Duration.zero && elapsed < debounce;
}

// Guards against onStart and onRepeatEvent (the only two callers, both in the
// foreground service's own isolate) interleaving at an `await` inside a run:
// the DB-backed shouldSkipMonitorRun check is check-then-write across two
// separate awaits, so two calls that both reach it before either has written
// lastMonitorRunAt would both proceed. This flag's check-and-set is
// synchronous (no await in between), so within a single isolate it can't race
// the same way.
bool _monitorRunInProgress = false;

// Service-isolate-local health state. Lives for the lifetime of the foreground
// service isolate (reset to defaults if the OS kills and the watchdog restarts
// the process, which is fine — the service starts with a fresh healthy
// notification and normal cadence).
int _consecutiveMonitorFailures = 0;
bool _monitorHealthDegraded = false;

Future<bool> _runMonitorTask() async {
  if (_monitorRunInProgress) {
    debugPrint('Skipping monitor run; one is already in progress.');
    return true;
  }
  _monitorRunInProgress = true;
  try {
    final succeeded = await _runMonitorTaskLocked();
    await _updateMonitorHealth(runSucceeded: succeeded);
    return succeeded;
  } finally {
    _monitorRunInProgress = false;
  }
}

/// Flips the ongoing notification to an error state after repeated failures (and
/// back to healthy on recovery), so a silently-broken monitor is visible.
Future<void> _updateMonitorHealth({required bool runSucceeded}) async {
  if (!_supportsForegroundService) {
    return;
  }
  final next = nextMonitorHealth(
    failures: _consecutiveMonitorFailures,
    degraded: _monitorHealthDegraded,
    runSucceeded: runSucceeded,
  );
  // The failure counter always advances, but `_monitorHealthDegraded` tracks
  // what the notification actually shows — so only flip it once the notification
  // write succeeds. If the write fails, the flag is left unchanged and the next
  // run recomputes the same transition and retries, instead of the notification
  // silently getting stuck in the wrong state.
  _consecutiveMonitorFailures = next.failures;
  switch (next.action) {
    case MonitorNotificationAction.showDegraded:
      if (await _setMonitorNotification(
        title: 'FarmCtl monitoring — not running',
        text: 'Last check failed. Open FarmCtl to restore monitoring.',
      )) {
        _monitorHealthDegraded = true;
      }
    case MonitorNotificationAction.showHealthy:
      if (await _setMonitorNotification(
        title: 'FarmCtl monitoring',
        text: 'Monitoring active',
      )) {
        _monitorHealthDegraded = false;
      }
    case MonitorNotificationAction.none:
      break;
  }
}

/// Returns whether the notification was successfully updated, so the caller can
/// defer committing the degraded/healthy state until the write actually lands.
Future<bool> _setMonitorNotification({
  required String title,
  required String text,
}) async {
  try {
    final result = await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
    if (result is ServiceRequestFailure) {
      debugPrint('Failed to update monitoring notification: ${result.error}');
      return false;
    }
    return true;
  } catch (error, stackTrace) {
    debugPrint('Failed to update monitoring notification: $error');
    debugPrint('$stackTrace');
    return false;
  }
}

/// Sets the running service's tick cadence (e.g. stretching it out during a
/// pause, or restoring the poll interval afterwards). Called on every run so a
/// prior pause-stretch is always corrected; the plugin itself compares against
/// the service's actual current interval and only restarts the repeat timer
/// when it truly changed, so an unchanged interval is a cheap no-op. (A local
/// "last applied" memo was deliberately avoided — it would desync from the real
/// interval whenever the main isolate changed it, stranding a stale cadence.)
Future<void> _reconcileServiceInterval(Duration interval) async {
  if (!_supportsForegroundService) {
    return;
  }
  try {
    final result = await FlutterForegroundTask.updateService(
      foregroundTaskOptions: _foregroundTaskOptions(interval),
    );
    if (result is ServiceRequestFailure) {
      debugPrint('Failed to adjust monitoring cadence: ${result.error}');
    }
  } catch (error, stackTrace) {
    debugPrint('Failed to adjust monitoring cadence: $error');
    debugPrint('$stackTrace');
  }
}

Future<bool> _runMonitorTaskLocked() async {
  WidgetsFlutterBinding.ensureInitialized();
  ui.DartPluginRegistrant.ensureInitialized();

  final notifications = FlutterLocalNotificationsPlugin();

  final database = ThermostatDatabase();
  AlertConfig? config;
  try {
    config = await AlertConfigRepository(database).loadConfig();
  } catch (error, stackTrace) {
    debugPrint('Failed to load alert config: $error');
    debugPrint('$stackTrace');
  }

  await _initializeNotifications(notifications, config: config);

  if (config == null) {
    debugPrint('Alert config unavailable; skipping monitor run.');
    await database.close();
    // Don't strand the service at a stretched (pause) cadence when the config
    // is transiently unreadable: fall back to the default interval so it keeps
    // retrying at a normal pace and self-heals once the config is readable.
    await _reconcileServiceInterval(_fallbackPollInterval);
    return false;
  }

  final alertConfig = config; // promote to non-null
  final now = DateTime.now().toUtc();
  var success = true;
  try {
    // Debounce the overlapping onStart + onRepeatEvent triggers into a single
    // run rather than fetching and writing the same rows twice.
    if (shouldSkipMonitorRun(
      lastRunStartedAt: alertConfig.lastMonitorRunAt,
      now: now,
    )) {
      debugPrint('Skipping monitor run; another run started recently.');
      return true;
    }

    // Record the run start up-front so a near-simultaneous trigger debounces.
    try {
      await database.setLastMonitorRunAt(now);
    } catch (error, stackTrace) {
      debugPrint('Failed to record monitor run start: $error');
      debugPrint('$stackTrace');
    }

    final deps = buildMonitorDependencies(database, alertConfig, notifications);
    final repository = deps.repository;
    final service = deps.service;
    final runner = deps.runner;

    if (alertConfig.isPaused(now)) {
      debugPrint(
        'Monitoring paused until ${alertConfig.pauseAllUntil?.toIso8601String()}',
      );
    } else {
      await runner.run();
      try {
        final thermostats = await repository.fetchThermostats();
        for (final summary in thermostats) {
          await service.refreshHistory(summary.thermostat.id);
        }
      } catch (error, stackTrace) {
        debugPrint('Background history refresh failed: $error');
        debugPrint('$stackTrace');
      }
    }

    try {
      await repository.pruneRetention();
    } catch (error, stackTrace) {
      debugPrint('Retention pruning failed in background: $error');
      debugPrint('$stackTrace');
    }
  } catch (error, stackTrace) {
    success = false;
    debugPrint('Thermostat monitor failed: $error');
    debugPrint('$stackTrace');
  } finally {
    await database.close();
    // Reconcile cadence on EVERY exit path (debounce-skip, paused bail, or a
    // full run) so a prior pause-stretch is always corrected: during a pause,
    // stretch the next wake to the pause end; otherwise the normal interval.
    await _reconcileServiceInterval(effectiveServiceInterval(alertConfig, now));
  }

  return success;
}

class ThermostatMonitorRunner {
  ThermostatMonitorRunner({
    required ThermostatRepository repository,
    required ThermostatNetworkDataSource network,
    required ThermostatAlarmDispatcher alarmDispatcher,
    Duration pollInterval = _fallbackPollInterval,
    DateTime Function()? clock,
  }) : _repository = repository,
       _network = network,
       _alarmDispatcher = alarmDispatcher,
       _pollInterval = pollInterval,
       _clock = clock ?? _defaultClock;

  final ThermostatRepository _repository;
  final ThermostatNetworkDataSource _network;
  final ThermostatAlarmDispatcher _alarmDispatcher;

  /// Configured poll cadence, used to derive the stale-data threshold
  /// (max(3 × interval, 15 min)) for dead-sensor detection.
  final Duration _pollInterval;
  final DateTime Function() _clock;

  static DateTime _defaultClock() => DateTime.now().toUtc();

  Future<void> run() async {
    final thermostats = await _repository.fetchThermostats();
    for (final summary in thermostats) {
      final thermostat = summary.thermostat;
      if (!thermostat.monitoringEnabled) {
        continue;
      }

      final previousState = summary.state;
      try {
        final result = await _network.fetchCurrent(thermostat.rawUrl);
        final value = result.valueC;
        final fetchedAt = result.fetchedAt;
        final outOfRange = isThermostatReadingOutOfRange(
          thermostat: thermostat,
          currentValue: value,
          previousState: previousState,
        );
        if (outOfRange) {
          final now = _clock();
          final baseMessage = formatOutOfRangeThermostatMessage(
            thermostat,
            value,
          );
          // Atomic compare-and-set: the decision and the lastAlarmAt write
          // happen in one transaction that re-reads the latest state, so
          // concurrent snooze/silence writes are never lost and overlapping
          // runs cannot both fire.
          final shouldAlarm = await _repository.recordOutOfRangeAndShouldAlarm(
            thermostatId: thermostat.id,
            valueC: value,
            fetchedAt: fetchedAt,
            dataUpdatedAt: result.dataUpdatedAt,
            etag: result.etag,
            message: baseMessage,
            now: now,
          );
          if (shouldAlarm) {
            await _alarmDispatcher.showAlarm(
              thermostat: thermostat,
              valueC: value,
              triggeredAt: now,
            );
          }
        } else if (isThermostatDataStale(
          dataUpdatedAt: result.dataUpdatedAt,
          now: _clock(),
          pollInterval: _pollInterval,
        )) {
          // The gist is reachable but its content hasn't changed for longer
          // than the staleness threshold: the sensor-side uploader is likely
          // dead. Same transactional arbitration (snooze/silence/rate-limit)
          // as out-of-range so overlapping runs can't double-fire.
          final now = _clock();
          final dataUpdatedAt = result.dataUpdatedAt!;
          final message = formatStaleDataMessage(dataUpdatedAt);
          final shouldAlarm = await _repository.recordStaleDataAndShouldAlarm(
            thermostatId: thermostat.id,
            valueC: value,
            fetchedAt: fetchedAt,
            dataUpdatedAt: dataUpdatedAt,
            etag: result.etag,
            message: message,
            now: now,
          );
          if (shouldAlarm) {
            await _alarmDispatcher.showStaleDataAlarm(
              thermostat: thermostat,
              dataUpdatedAt: dataUpdatedAt,
              triggeredAt: now,
            );
          }
        } else {
          final message = 'Fetched ${value.toStringAsFixed(2)}°C';
          final shouldClearSnooze = previousState?.snoozedUntil != null;
          final hadSilence = previousState?.silenceUntilOk == true;
          await _repository.saveState(
            thermostatId: thermostat.id,
            status: ThermostatReadingStatus.ok,
            valueC: value,
            fetchedAt: fetchedAt,
            dataUpdatedAt: result.dataUpdatedAt,
            setDataUpdatedAt: true,
            etag: result.etag,
            message: message,
            setSnoozedUntil: shouldClearSnooze,
            snoozedUntil: null,
            setSilenceUntilOk: hadSilence,
            silenceUntilOk: false,
          );
          // Always clear any alarm notification on an OK reading: the decision
          // above is made from a pre-run snapshot that may be stale, so gating
          // the cancel on it could leave a stale alarm showing after the device
          // recovered. cancel is a no-op when nothing is showing.
          await cancelAlarmNotification(thermostat.id);
        }
      } on ThermostatFetchException catch (error) {
        await _repository.saveState(
          thermostatId: thermostat.id,
          status: error.status,
          valueC: previousState?.lastValueC,
          fetchedAt: _clock(),
          etag: previousState?.etag,
          message: error.message,
        );
      } catch (error) {
        await _repository.saveState(
          thermostatId: thermostat.id,
          status: ThermostatReadingStatus.unknown,
          valueC: previousState?.lastValueC,
          fetchedAt: _clock(),
          etag: previousState?.etag,
          message: 'Unexpected error: $error',
        );
      }
    }
  }
}

/// Bundle of the collaborators a monitor run needs, built from a database and
/// the loaded config. Centralised so the background isolate entry points don't
/// each re-wire the repository / client / service / runner by hand.
class MonitorDependencies {
  const MonitorDependencies({
    required this.repository,
    required this.network,
    required this.service,
    required this.runner,
  });

  final ThermostatRepository repository;
  final ThermostatHttpClient network;
  final ThermostatService service;
  final ThermostatMonitorRunner runner;
}

MonitorDependencies buildMonitorDependencies(
  ThermostatDatabase database,
  AlertConfig config,
  FlutterLocalNotificationsPlugin notifications,
) {
  final repository = ThermostatRepository(database);
  final network = ThermostatHttpClient(githubToken: config.githubToken);
  final service = ThermostatService(
    repository: repository,
    network: network,
    tokenSupplier: () async => config.githubToken,
    pollIntervalSupplier: () async => config.pollInterval,
  );
  final runner = ThermostatMonitorRunner(
    repository: repository,
    network: network,
    alarmDispatcher: NotificationAlarmDispatcher(notifications, config: config),
    pollInterval: config.pollInterval,
  );
  return MonitorDependencies(
    repository: repository,
    network: network,
    service: service,
    runner: runner,
  );
}

String _alarmChannelIdForSound(String? soundUri) {
  if (soundUri == null || soundUri.isEmpty) {
    return '${_alarmChannelPrefix}_default';
  }
  final hash = soundUri.hashCode & 0x7fffffff;
  return '${_alarmChannelPrefix}_${hash.toRadixString(36)}';
}

AndroidNotificationSound _alarmNotificationSound(String? soundUri) {
  final target = (soundUri != null && soundUri.isNotEmpty)
      ? soundUri
      : _defaultAlarmSoundUri;
  return UriAndroidNotificationSound(target);
}

AndroidNotificationChannel _buildAlarmChannel(String? soundUri) {
  final channelId = _alarmChannelIdForSound(soundUri);
  return AndroidNotificationChannel(
    channelId,
    _alarmChannelName,
    description: _alarmChannelDescription,
    importance: Importance.max,
    playSound: true,
    sound: _alarmNotificationSound(soundUri),
    audioAttributesUsage: AudioAttributesUsage.alarm,
    enableVibration: true,
  );
}

Future<NotificationDetails> _prepareAlarmNotificationDetails({
  required FlutterLocalNotificationsPlugin plugin,
  required AlertConfig config,
  required bool autoCancel,
  required bool ongoing,
  required List<AndroidNotificationAction> actions,
  bool fullScreenIntent = true,
  String ticker = 'Thermostat alarm',
}) async {
  final androidPlugin = plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  final channel = _buildAlarmChannel(config.soundUri);
  await androidPlugin?.createNotificationChannel(channel);
  final sound = _alarmNotificationSound(config.soundUri);

  final androidDetails = AndroidNotificationDetails(
    channel.id,
    channel.name,
    channelDescription: channel.description,
    importance: Importance.max,
    priority: Priority.high,
    fullScreenIntent: fullScreenIntent,
    category: AndroidNotificationCategory.alarm,
    ticker: ticker,
    autoCancel: autoCancel,
    ongoing: ongoing,
    enableVibration: config.vibrate,
    playSound: true,
    sound: sound,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    channelAction: AndroidNotificationChannelAction.createIfNotExists,
    actions: actions,
  );

  return NotificationDetails(android: androidDetails);
}

abstract class ThermostatAlarmDispatcher {
  Future<void> showAlarm({
    required Thermostat thermostat,
    required double valueC,
    required DateTime triggeredAt,
  });

  /// Raises the same alarm surface as [showAlarm], but for a silent sensor:
  /// the gist is reachable yet its content stopped updating at
  /// [dataUpdatedAt].
  Future<void> showStaleDataAlarm({
    required Thermostat thermostat,
    required DateTime dataUpdatedAt,
    required DateTime triggeredAt,
  });
}

class NotificationAlarmDispatcher implements ThermostatAlarmDispatcher {
  NotificationAlarmDispatcher(
    this._notifications, {
    required AlertConfig config,
  }) : _config = config;

  final FlutterLocalNotificationsPlugin _notifications;
  final AlertConfig _config;

  @override
  Future<void> showAlarm({
    required Thermostat thermostat,
    required double valueC,
    required DateTime triggeredAt,
  }) {
    return _show(
      thermostat: thermostat,
      title: '${thermostat.name} out of range',
      body:
          'Current ${valueC.toStringAsFixed(2)}°C • '
          'Range ${thermostat.minC.toStringAsFixed(2)}°C – '
          '${thermostat.maxC.toStringAsFixed(2)}°C',
    );
  }

  @override
  Future<void> showStaleDataAlarm({
    required Thermostat thermostat,
    required DateTime dataUpdatedAt,
    required DateTime triggeredAt,
  }) {
    return _show(
      thermostat: thermostat,
      title: '${thermostat.name} — no new data',
      body: formatStaleDataMessage(dataUpdatedAt),
    );
  }

  Future<void> _show({
    required Thermostat thermostat,
    required String title,
    required String body,
  }) async {
    final payload = jsonEncode({'thermostatId': thermostat.id});
    final details = await _prepareAlarmNotificationDetails(
      plugin: _notifications,
      config: _config,
      autoCancel: false,
      ongoing: true,
      actions: const [
        AndroidNotificationAction(_snooze5ActionId, 'Snooze 5 min'),
        AndroidNotificationAction(_snooze10ActionId, 'Snooze 10 min'),
        AndroidNotificationAction(_snooze30ActionId, 'Snooze 30 min'),
        AndroidNotificationAction(_silenceActionId, 'Silence until OK'),
      ],
    );
    await _notifications.show(
      _alarmNotificationId(thermostat.id),
      title,
      body,
      details,
      payload: payload,
    );
  }
}

Future<void> cancelAlarmNotification(String thermostatId) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.cancel(_alarmNotificationId(thermostatId));
  } catch (_) {
    // Ignore errors when notifications are not initialized (e.g., in tests).
  }
}

Future<void> showTestAlarmNotification({required AlertConfig config}) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await _initializeNotifications(plugin, config: config);

  final details = await _prepareAlarmNotificationDetails(
    plugin: plugin,
    config: config,
    autoCancel: true,
    ongoing: false,
    actions: const [],
    ticker: 'Test alarm',
  );

  await plugin.show(
    999999,
    'Test Alarm',
    'This is a test alarm notification',
    details,
  );
}

int _alarmNotificationId(String thermostatId) {
  final hash = thermostatId.hashCode & 0x7fffffff;
  return _alarmNotificationBaseId + (hash % 1000000);
}

typedef _NotificationResponseHandler =
    Future<void> Function(NotificationResponse response);

Future<void> _initializeNotifications(
  FlutterLocalNotificationsPlugin plugin, {
  // Defaults to the real handler so a caller that re-initialises the plugin in
  // the app isolate (e.g. the Settings "test alarm") can't null out the
  // foreground notification-tap handler that routes to the alarm screen.
  _NotificationResponseHandler? onDidReceiveNotificationResponse =
      _handleNotificationResponse,
  AlertConfig? config,
}) async {
  const initializationSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await plugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: onDidReceiveNotificationResponse,
    // Handles action buttons (snooze/silence) pressed while the app is
    // terminated/background, in a dedicated isolate.
    onDidReceiveBackgroundNotificationResponse: _handleNotificationResponse,
  );
  final androidPlugin = plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  // The persistent "monitoring active" notification/channel is owned by the
  // foreground service (flutter_foreground_task) now; only the alarm channels
  // are created here.
  final soundUris = <String?>{null};
  final customSound = config?.soundUri;
  if (customSound != null && customSound.isNotEmpty) {
    soundUris.add(customSound);
  }
  for (final soundUri in soundUris) {
    final channel = _buildAlarmChannel(soundUri);
    await androidPlugin?.createNotificationChannel(channel);
  }
}

/// Routes a cold-launch alarm-notification tap to the alarm screen.
///
/// `onDidReceiveNotificationResponse` only fires while the Dart isolate is
/// alive, so a tap that *launches* the app from a terminated state is delivered
/// only via the launch details. Call this once during app startup.
Future<void> handleNotificationLaunch() async {
  if (!_supportsForegroundService) {
    return;
  }
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    final details = await plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) {
      return;
    }
    final response = details.notificationResponse;
    if (response != null) {
      // Same path as a live tap: body tap -> open the alarm screen, action
      // button -> snooze/silence.
      await _handleNotificationResponse(response);
    }
  } catch (error, stackTrace) {
    debugPrint('Failed to handle notification launch: $error');
    debugPrint('$stackTrace');
  }
}

@pragma('vm:entry-point')
Future<void> _handleNotificationResponse(NotificationResponse response) async {
  // May run in a background isolate (an action button pressed while the app is
  // terminated), so ensure plugins/DB are available there. No-op in foreground.
  WidgetsFlutterBinding.ensureInitialized();
  ui.DartPluginRegistrant.ensureInitialized();
  final payload = response.payload;
  if (payload == null || payload.isEmpty) {
    return;
  }

  String? thermostatId;
  try {
    final data = jsonDecode(payload) as Map<String, dynamic>;
    thermostatId = data['thermostatId'] as String?;
  } catch (_) {
    thermostatId = null;
  }

  if (thermostatId == null) {
    return;
  }

  final actionId = response.actionId;
  if (actionId == null || actionId.isEmpty) {
    _navigateToAlarm(thermostatId);
    await cancelAlarmNotification(thermostatId);
    return;
  }

  final database = ThermostatDatabase();
  final repository = ThermostatRepository(database);
  try {
    final now = DateTime.now().toUtc();
    final snooze = snoozeDurationForAction(actionId);
    if (snooze != null) {
      await repository.updateSnoozedUntil(thermostatId, now.add(snooze));
    } else if (actionId == _silenceActionId) {
      await repository.updateSilenceUntilOk(thermostatId, true);
      await repository.updateSnoozedUntil(thermostatId, null);
    }
  } finally {
    await database.close();
  }

  await cancelAlarmNotification(thermostatId);
}

void _navigateToAlarm(String thermostatId) {
  // Bound the retry: if the root navigator never mounts (e.g. app bootstrap
  // failed after a cold launch from a notification tap), stop re-arming the
  // post-frame callback instead of spinning every frame forever.
  const maxAttempts = 60;
  var attempts = 0;
  void attemptNavigation() {
    final context = rootNavigatorKey.currentContext;
    if (context != null) {
      final target = AlarmRoute.pathFor(thermostatId);
      final router = GoRouter.of(context);
      // Don't stack a duplicate alarm page if this thermostat's alarm is already
      // on top (the ongoing notification is re-posted every cycle and may be
      // re-tapped) — pushing again would also drop the wakelock early when the
      // duplicate is popped.
      if (router.routerDelegate.currentConfiguration.uri.path != target) {
        router.push(target);
      }
      return;
    }
    if (attempts++ >= maxAttempts) {
      debugPrint(
        'Could not navigate to alarm: navigator unavailable after '
        '$maxAttempts attempts.',
      );
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => attemptNavigation());
  }

  attemptNavigation();
}
