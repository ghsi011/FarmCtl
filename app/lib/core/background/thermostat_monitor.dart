import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
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

const String thermostatMonitorTask = 'thermostat_monitor_task';
const String thermostatMonitorUniqueName = 'thermostat_monitor_periodic';

const AndroidNotificationChannel _monitoringChannel =
    AndroidNotificationChannel(
      'farmctl_monitoring',
      'Thermostat monitoring',
      description:
          'Shows when FarmCtl is checking thermostats in the background.',
      importance: Importance.low,
    );

const String _alarmChannelPrefix = 'farmctl_alarm';
const String _alarmChannelName = 'Thermostat alarms';
const String _alarmChannelDescription =
    'Alerts when a thermostat leaves the configured range.';
const String _defaultAlarmSoundUri = 'content://settings/system/alarm_alert';

const int _monitoringNotificationId = 1001;
const int _alarmNotificationBaseId = 4000;
const Duration _minimumFrequency = Duration(minutes: 15);
const int _alarmRequestId = 5001;

// Collapses the near-simultaneous WorkManager + AlarmManager fires (which land
// within a few seconds of each other) into a single monitor run. Kept short so
// it stays below both the 60s+ gap between legitimate consecutive runs AND the
// WorkManager retry backoff — otherwise a failed run's own retry could be
// debounced away (the run-start stamp is written before the run and persists on
// failure).
const Duration _monitorRunDebounce = Duration(seconds: 10);

bool _alarmManagerInitialized = false;

bool get _supportsAlarmScheduling => !kIsWeb && Platform.isAndroid;

Future<void> _ensureAlarmManagerInitialized() async {
  if (!_supportsAlarmScheduling) {
    return;
  }
  if (_alarmManagerInitialized) {
    return;
  }
  try {
    final initialized = await AndroidAlarmManager.initialize();
    if (initialized) {
      _alarmManagerInitialized = true;
    } else {
      debugPrint('AndroidAlarmManager.initialize returned false');
    }
  } catch (error, stackTrace) {
    debugPrint('Failed to initialize AndroidAlarmManager: $error');
    debugPrint('$stackTrace');
  }
}

DateTime? _computeNextAlarmTime(AlertConfig config, DateTime nowUtc) {
  final interval = config.pollInterval;
  if (interval <= Duration.zero) {
    return null;
  }

  var target = nowUtc.add(interval);
  final pauseUntil = config.pauseAllUntil;
  if (pauseUntil != null && pauseUntil.isAfter(target)) {
    target = pauseUntil;
  }

  return target.toLocal();
}

Future<void> _updateAlarmSchedule(AlertConfig config, {DateTime? now}) async {
  if (!_supportsAlarmScheduling) {
    return;
  }

  await _ensureAlarmManagerInitialized();
  if (!_alarmManagerInitialized) {
    return;
  }

  final nowUtc = (now ?? DateTime.now()).toUtc();
  final nextRun = _computeNextAlarmTime(config, nowUtc);
  if (nextRun == null) {
    await AndroidAlarmManager.cancel(_alarmRequestId);
    return;
  }

  final useExact = config.exactAlarmsEnabled;
  var scheduled = await _scheduleMonitorOneShot(nextRun, exact: useExact);
  if (!scheduled && useExact) {
    // Exact scheduling throws if SCHEDULE_EXACT_ALARM was revoked since the user
    // enabled it. Downgrade to a flexible alarm so checks keep happening rather
    // than silently breaking the one-shot chain.
    debugPrint(
      'Exact alarm scheduling failed; falling back to a flexible alarm.',
    );
    scheduled = await _scheduleMonitorOneShot(nextRun, exact: false);
  }
  if (!scheduled) {
    debugPrint('Unable to schedule the next monitor alarm.');
  }
}

Future<bool> _scheduleMonitorOneShot(
  DateTime nextRun, {
  required bool exact,
}) async {
  try {
    // oneShotAt returns false if scheduling was refused without throwing; honour
    // it so the exact -> flexible downgrade still triggers in that case.
    return await AndroidAlarmManager.oneShotAt(
      nextRun,
      _alarmRequestId,
      thermostatAlarmCallback,
      allowWhileIdle: true,
      exact: exact,
      wakeup: true,
      rescheduleOnReboot: true,
    );
  } catch (error, stackTrace) {
    debugPrint(
      'Failed to schedule ${exact ? 'exact' : 'flexible'} alarm: $error',
    );
    debugPrint('$stackTrace');
    return false;
  }
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
      pollFrequency ?? config?.pollInterval ?? const Duration(minutes: 5);
  final effectiveFrequency = configuredInterval < _minimumFrequency
      ? _minimumFrequency
      : configuredInterval;

  await Workmanager().initialize(thermostatMonitorCallbackDispatcher);
  await Workmanager().registerPeriodicTask(
    thermostatMonitorUniqueName,
    thermostatMonitorTask,
    frequency: effectiveFrequency,
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    constraints: Constraints(networkType: NetworkType.connected),
  );

  if (config != null) {
    final schedulingConfig = pollFrequency != null
        ? config.copyWith(pollInterval: pollFrequency)
        : config;
    await _updateAlarmSchedule(schedulingConfig);
  }

  // Keep a persistent low-priority notification visible between runs so the
  // user knows monitoring is active.
  await _showMonitoringActiveNotification(notifications);
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
    return _runMonitorTask();
  });
}

@pragma('vm:entry-point')
Future<void> thermostatAlarmCallback() async {
  await _runMonitorTask();
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

Future<bool> _runMonitorTask() async {
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
    // Treat a failed config load as a failure so WorkManager retries.
    return false;
  }

  final now = DateTime.now().toUtc();

  // Debounce the overlapping WorkManager + AlarmManager triggers into a single
  // run rather than fetching and writing the same rows twice.
  if (shouldSkipMonitorRun(
    lastRunStartedAt: config.lastMonitorRunAt,
    now: now,
  )) {
    debugPrint('Skipping monitor run; another run started recently.');
    await _updateAlarmSchedule(config, now: now);
    await database.close();
    return true;
  }

  // Record the run start up-front so a near-simultaneous trigger debounces.
  try {
    await database.setLastMonitorRunAt(now);
  } catch (error, stackTrace) {
    debugPrint('Failed to record monitor run start: $error');
    debugPrint('$stackTrace');
  }

  // Show a transient notification while the check is running.
  await _showMonitoringNotification(notifications);

  // Reschedule from the freshest config so a pollInterval / pause change made
  // during this (possibly multi-second) run is honored by the next wakeup.
  var scheduleConfig = config;
  var success = true;
  try {
    final alertConfig = config; // promote to non-null for closures
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

    try {
      scheduleConfig = AlertConfig.fromEntry(await database.getAlertConfig());
    } catch (_) {
      // Keep the run-start config if the re-read fails.
    }
  } catch (error, stackTrace) {
    success = false;
    debugPrint('Thermostat monitor failed: $error');
    debugPrint('$stackTrace');
  } finally {
    // Switch back to the persistent monitoring indicator when the run ends.
    await _showMonitoringActiveNotification(notifications);
    await database.close();
  }

  await _updateAlarmSchedule(scheduleConfig, now: now);
  return success;
}

class ThermostatMonitorRunner {
  ThermostatMonitorRunner({
    required ThermostatRepository repository,
    required ThermostatNetworkDataSource network,
    required ThermostatAlarmDispatcher alarmDispatcher,
    DateTime Function()? clock,
  }) : _repository = repository,
       _network = network,
       _alarmDispatcher = alarmDispatcher,
       _clock = clock ?? _defaultClock;

  final ThermostatRepository _repository;
  final ThermostatNetworkDataSource _network;
  final ThermostatAlarmDispatcher _alarmDispatcher;
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
        } else {
          final message = 'Fetched ${value.toStringAsFixed(2)}°C';
          final shouldClearSnooze = previousState?.snoozedUntil != null;
          final hadSilence = previousState?.silenceUntilOk == true;
          await _repository.saveState(
            thermostatId: thermostat.id,
            status: ThermostatReadingStatus.ok,
            valueC: value,
            fetchedAt: fetchedAt,
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
  );
  final runner = ThermostatMonitorRunner(
    repository: repository,
    network: network,
    alarmDispatcher: NotificationAlarmDispatcher(notifications, config: config),
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
      '${thermostat.name} out of range',
      'Current ${valueC.toStringAsFixed(2)}°C • '
          'Range ${thermostat.minC.toStringAsFixed(2)}°C – '
          '${thermostat.maxC.toStringAsFixed(2)}°C',
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
  _NotificationResponseHandler? onDidReceiveNotificationResponse,
  AlertConfig? config,
}) async {
  const initializationSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await plugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: onDidReceiveNotificationResponse,
  );
  final androidPlugin = plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  await androidPlugin?.createNotificationChannel(_monitoringChannel);
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

Future<void> _showMonitoringNotification(
  FlutterLocalNotificationsPlugin plugin,
) {
  return plugin.show(
    _monitoringNotificationId,
    'FarmCtl monitoring',
    'Checking thermostats…',
    NotificationDetails(
      android: AndroidNotificationDetails(
        _monitoringChannel.id,
        _monitoringChannel.name,
        channelDescription: _monitoringChannel.description,
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        showWhen: false,
        playSound: false,
        enableVibration: false,
      ),
    ),
  );
}

Future<void> _showMonitoringActiveNotification(
  FlutterLocalNotificationsPlugin plugin,
) {
  return plugin.show(
    _monitoringNotificationId,
    'FarmCtl monitoring',
    'Monitoring active',
    NotificationDetails(
      android: AndroidNotificationDetails(
        _monitoringChannel.id,
        _monitoringChannel.name,
        channelDescription: _monitoringChannel.description,
        importance: Importance.low,
        priority: Priority.low,
        // Make this notification non-dismissible by swipe
        autoCancel: false,
        ongoing: true,
        category: AndroidNotificationCategory.service,
        showWhen: false,
        playSound: false,
        enableVibration: false,
      ),
    ),
  );
}

Future<void> _handleNotificationResponse(NotificationResponse response) async {
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
      GoRouter.of(context).push(AlarmRoute.pathFor(thermostatId));
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
