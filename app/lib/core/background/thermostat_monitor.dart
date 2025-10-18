import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:workmanager/workmanager.dart';

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
const Duration _alarmRateLimit = Duration(minutes: 5);
const int _alarmRequestId = 5001;

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
  try {
    await AndroidAlarmManager.oneShotAt(
      nextRun,
      _alarmRequestId,
      thermostatAlarmCallback,
      allowWhileIdle: true,
      exact: useExact,
      wakeup: true,
      rescheduleOnReboot: true,
    );
  } catch (error, stackTrace) {
    debugPrint(
      'Failed to schedule ${useExact ? 'exact' : 'flexible'} alarm: $error',
    );
    debugPrint('$stackTrace');
  }
}

const String _snooze5ActionId = 'alarm_snooze_5';
const String _snooze10ActionId = 'alarm_snooze_10';
const String _snooze30ActionId = 'alarm_snooze_30';
const String _silenceActionId = 'alarm_silence_until_ok';

Future<void> initializeBackgroundMonitoring({Duration? pollFrequency}) async {
  final notifications = FlutterLocalNotificationsPlugin();

  AlertConfig? config;
  final database = ThermostatDatabase();
  try {
    final entry = await database.getAlertConfig();
    config = AlertConfig.fromEntry(entry);
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

@pragma('vm:entry-point')
void thermostatMonitorCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    await _runMonitorTask();
    return true;
  });
}

@pragma('vm:entry-point')
Future<void> thermostatAlarmCallback() async {
  await _runMonitorTask();
}

Future<void> _runMonitorTask() async {
  WidgetsFlutterBinding.ensureInitialized();
  ui.DartPluginRegistrant.ensureInitialized();

  final notifications = FlutterLocalNotificationsPlugin();

  final database = ThermostatDatabase();
  AlertConfig? config;
  try {
    final entry = await database.getAlertConfig();
    config = AlertConfig.fromEntry(entry);
  } catch (error, stackTrace) {
    debugPrint('Failed to load alert config: $error');
    debugPrint('$stackTrace');
  }

  await _initializeNotifications(notifications, config: config);
  // Show a transient notification while the check is running.
  await _showMonitoringNotification(notifications);

  if (config == null) {
    debugPrint('Alert config unavailable; skipping monitor run.');
    await notifications.cancel(_monitoringNotificationId);
    await database.close();
    return;
  }

  try {
    final repository = ThermostatRepository(database);
    final alertConfig = config; // promote to non-null for closures
    final network = ThermostatHttpClient(githubToken: alertConfig.githubToken);
    final service = ThermostatService(
      repository: repository,
      network: network,
      tokenSupplier: () async => alertConfig.githubToken,
    );
    final runner = ThermostatMonitorRunner(
      repository: repository,
      network: network,
      alarmDispatcher: NotificationAlarmDispatcher(
        notifications,
        config: alertConfig,
      ),
    );

    final now = DateTime.now().toUtc();
    if (config.isPaused(now)) {
      debugPrint(
        'Monitoring paused until ${config.pauseAllUntil?.toIso8601String()}',
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
    debugPrint('Thermostat monitor failed: $error');
    debugPrint('$stackTrace');
  } finally {
    // Switch back to the persistent monitoring indicator when the run ends.
    await _showMonitoringActiveNotification(notifications);
    await database.close();
  }

  // config is non-null here
  await _updateAlarmSchedule(config);
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
          final shouldAlarm = _shouldTriggerAlarm(previousState, now);
          final clearSnooze =
              shouldAlarm && (previousState?.snoozedUntil != null);
          await _repository.saveState(
            thermostatId: thermostat.id,
            status: ThermostatReadingStatus.outOfRange,
            valueC: value,
            fetchedAt: fetchedAt,
            etag: result.etag,
            message: baseMessage,
            lastAlarmAt: shouldAlarm ? now : null,
            setLastAlarmAt: shouldAlarm,
            setSnoozedUntil: clearSnooze,
            snoozedUntil: null,
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
          final wasOutOfRange =
              previousState?.status == ThermostatReadingStatus.outOfRange;
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
          if (hadSilence || wasOutOfRange) {
            await cancelAlarmNotification(thermostat.id);
          }
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

  bool _shouldTriggerAlarm(ThermostatState? previousState, DateTime now) {
    if (previousState == null) {
      return true;
    }

    if (previousState.silenceUntilOk) {
      return false;
    }

    final snoozedUntil = previousState.snoozedUntil;
    if (snoozedUntil != null && now.isBefore(snoozedUntil)) {
      return false;
    }

    final lastAlarmAt = previousState.lastAlarmAt;
    if (lastAlarmAt != null &&
        previousState.status == ThermostatReadingStatus.outOfRange) {
      final diff = now.difference(lastAlarmAt);
      if (diff < _alarmRateLimit) {
        return false;
      }
    }

    return true;
  }
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
        ongoing: true,
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
    switch (actionId) {
      case _snooze5ActionId:
        await repository.updateSnoozedUntil(
          thermostatId,
          now.add(const Duration(minutes: 5)),
        );
        break;
      case _snooze10ActionId:
        await repository.updateSnoozedUntil(
          thermostatId,
          now.add(const Duration(minutes: 10)),
        );
        break;
      case _snooze30ActionId:
        await repository.updateSnoozedUntil(
          thermostatId,
          now.add(const Duration(minutes: 30)),
        );
        break;
      case _silenceActionId:
        await repository.updateSilenceUntilOk(thermostatId, true);
        await repository.updateSnoozedUntil(thermostatId, null);
        break;
      default:
        break;
    }
  } finally {
    await database.close();
  }

  await cancelAlarmNotification(thermostatId);
}

void _navigateToAlarm(String thermostatId) {
  void attemptNavigation() {
    final context = rootNavigatorKey.currentContext;
    if (context != null) {
      GoRouter.of(context).push(AlarmRoute.pathFor(thermostatId));
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => attemptNavigation());
    }
  }

  attemptNavigation();
}
