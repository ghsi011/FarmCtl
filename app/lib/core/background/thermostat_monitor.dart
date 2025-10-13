import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import '../../features/thermostats/data/thermostat_client.dart';
import '../../features/thermostats/data/thermostat_database.dart';
import '../../features/thermostats/data/thermostat_repository.dart';
import '../../features/thermostats/models/thermostat_state.dart';

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

const int _monitoringNotificationId = 1001;
const Duration _minimumFrequency = Duration(minutes: 15);

Future<void> initializeBackgroundMonitoring({
  Duration pollFrequency = const Duration(minutes: 5),
}) async {
  // Ensure notification channel exists even if the app has not shown one yet.
  final notifications = FlutterLocalNotificationsPlugin();
  await _initializeNotifications(notifications);

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
    DateTime Function()? clock,
  }) : _repository = repository,
       _network = network,
       _clock = clock ?? _defaultClock;

  final ThermostatRepository _repository;
  final ThermostatNetworkDataSource _network;
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
        await _repository.saveState(
          thermostatId: thermostat.id,
          status: ThermostatReadingStatus.ok,
          valueC: result.valueC,
          fetchedAt: result.fetchedAt,
          etag: result.etag,
          message: 'Fetched ${result.valueC.toStringAsFixed(1)}°C',
        );
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

Future<void> _initializeNotifications(
  FlutterLocalNotificationsPlugin plugin,
) async {
  const initializationSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await plugin.initialize(initializationSettings);
  final androidPlugin = plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  await androidPlugin?.createNotificationChannel(_monitoringChannel);
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
