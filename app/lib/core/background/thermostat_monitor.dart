import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:go_router/go_router.dart';
import 'package:workmanager/workmanager.dart';

import '../../features/thermostats/data/thermostat_client.dart';
import '../../features/thermostats/data/thermostat_database.dart';
import '../../features/thermostats/data/thermostat_reading_utils.dart';
import '../../features/thermostats/data/thermostat_repository.dart';
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

const AndroidNotificationChannel _alarmChannel = AndroidNotificationChannel(
  'farmctl_alarm',
  'Thermostat alarms',
  description: 'Alerts when a thermostat leaves the configured range.',
  importance: Importance.max,
  playSound: true,
);

const int _monitoringNotificationId = 1001;
const int _alarmNotificationBaseId = 4000;
const Duration _minimumFrequency = Duration(minutes: 15);
const Duration _alarmRateLimit = Duration(minutes: 5);

const String _snooze5ActionId = 'alarm_snooze_5';
const String _snooze10ActionId = 'alarm_snooze_10';
const String _snooze30ActionId = 'alarm_snooze_30';
const String _silenceActionId = 'alarm_silence_until_ok';

Future<void> initializeBackgroundMonitoring({
  Duration pollFrequency = const Duration(minutes: 5),
}) async {
  final notifications = FlutterLocalNotificationsPlugin();
  await _initializeNotifications(
    notifications,
    onDidReceiveNotificationResponse: _handleNotificationResponse,
  );

  final effectiveFrequency = pollFrequency < _minimumFrequency
      ? _minimumFrequency
      : pollFrequency;

  await Workmanager().initialize(thermostatMonitorCallbackDispatcher);
  await Workmanager().registerPeriodicTask(
    thermostatMonitorUniqueName,
    thermostatMonitorTask,
    frequency: effectiveFrequency,
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    constraints: Constraints(networkType: NetworkType.connected),
  );
}

@pragma('vm:entry-point')
void thermostatMonitorCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    ui.DartPluginRegistrant.ensureInitialized();

    final notifications = FlutterLocalNotificationsPlugin();
    await _initializeNotifications(notifications);
    await _showMonitoringNotification(notifications);

    final database = ThermostatDatabase();
    final repository = ThermostatRepository(database);
    final network = ThermostatHttpClient();
    final runner = ThermostatMonitorRunner(
      repository: repository,
      network: network,
      alarmDispatcher: NotificationAlarmDispatcher(notifications),
    );

    try {
      await runner.run();
    } catch (error, stackTrace) {
      debugPrint('Thermostat monitor failed: $error');
      debugPrint('$stackTrace');
    } finally {
      await notifications.cancel(_monitoringNotificationId);
      await database.close();
    }

    return true;
  });
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

abstract class ThermostatAlarmDispatcher {
  Future<void> showAlarm({
    required Thermostat thermostat,
    required double valueC,
    required DateTime triggeredAt,
  });
}

class NotificationAlarmDispatcher implements ThermostatAlarmDispatcher {
  NotificationAlarmDispatcher(this._notifications);

  final FlutterLocalNotificationsPlugin _notifications;

  @override
  Future<void> showAlarm({
    required Thermostat thermostat,
    required double valueC,
    required DateTime triggeredAt,
  }) async {
    final payload = jsonEncode({'thermostatId': thermostat.id});
    await _notifications.show(
      _alarmNotificationId(thermostat.id),
      '${thermostat.name} out of range',
      'Current ${valueC.toStringAsFixed(2)}°C • '
          'Range ${thermostat.minC.toStringAsFixed(2)}°C – '
          '${thermostat.maxC.toStringAsFixed(2)}°C',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _alarmChannel.id,
          _alarmChannel.name,
          channelDescription: _alarmChannel.description,
          importance: Importance.max,
          priority: Priority.high,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
          ticker: 'Thermostat alarm',
          autoCancel: false,
          ongoing: true,
          enableVibration: true,
          playSound: true,
          actions: const [
            AndroidNotificationAction(_snooze5ActionId, 'Snooze 5 min'),
            AndroidNotificationAction(_snooze10ActionId, 'Snooze 10 min'),
            AndroidNotificationAction(_snooze30ActionId, 'Snooze 30 min'),
            AndroidNotificationAction(_silenceActionId, 'Silence until OK'),
          ],
        ),
      ),
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

Future<void> showTestAlarmNotification({required dynamic config}) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await _initializeNotifications(plugin);

  await plugin.show(
    999999,
    'Test Alarm',
    'This is a test alarm notification',
    NotificationDetails(
      android: AndroidNotificationDetails(
        _alarmChannel.id,
        _alarmChannel.name,
        channelDescription: _alarmChannel.description,
        importance: Importance.max,
        priority: Priority.high,
        fullScreenIntent: true,
        category: AndroidNotificationCategory.alarm,
        ticker: 'Test alarm',
        autoCancel: true,
        ongoing: false,
        enableVibration: true,
        playSound: true,
      ),
    ),
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
  await androidPlugin?.createNotificationChannel(_alarmChannel);
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
