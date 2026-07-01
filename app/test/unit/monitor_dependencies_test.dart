import 'package:drift/native.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/core/background/thermostat_monitor.dart';
import 'package:farmctl/features/settings/models/alert_config.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';

void main() {
  test('buildMonitorDependencies wires the monitor collaborators', () async {
    final database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    const config = AlertConfig(
      pollInterval: Duration(minutes: 5),
      soundUri: null,
      vibrate: true,
      volumeBoost: false,
      pauseAllUntil: null,
      githubToken: null,
    );

    final deps = buildMonitorDependencies(
      database,
      config,
      FlutterLocalNotificationsPlugin(),
    );

    expect(deps.repository, isNotNull);
    expect(deps.network, isNotNull);
    expect(deps.service, isNotNull);
    expect(deps.runner, isA<ThermostatMonitorRunner>());

    // The wired repository talks to the provided database.
    expect(await deps.repository.fetchThermostats(), isEmpty);
  });
}
