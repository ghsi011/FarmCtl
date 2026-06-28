import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/settings/models/alert_config.dart';
import 'package:farmctl/features/thermostats/models/temperature_sample.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';

void main() {
  final timestamp = DateTime.utc(2025, 1, 1);

  Thermostat thermostat({String name = 'Barn'}) => Thermostat(
    id: 't1',
    name: name,
    rawUrl: 'a' * 32,
    minC: 0,
    maxC: 20,
    hysteresisEnabled: false,
    monitoringEnabled: true,
    createdAt: timestamp,
    updatedAt: timestamp,
  );

  ThermostatState state({double? value = 12.0}) => ThermostatState(
    thermostatId: 't1',
    status: ThermostatReadingStatus.ok,
    lastValueC: value,
    createdAt: timestamp,
    updatedAt: timestamp,
  );

  test('Thermostat has value equality', () {
    expect(thermostat(), thermostat());
    expect(thermostat().hashCode, thermostat().hashCode);
    expect(thermostat() == thermostat(name: 'Other'), isFalse);
  });

  test('ThermostatState has value equality', () {
    expect(state(), state());
    expect(state().hashCode, state().hashCode);
    expect(state() == state(value: 13.0), isFalse);
  });

  test('ThermostatSummary has value equality', () {
    final a = ThermostatSummary(thermostat: thermostat(), state: state());
    final b = ThermostatSummary(thermostat: thermostat(), state: state());
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == ThermostatSummary(thermostat: thermostat()), isFalse);
  });

  test('TemperatureSample has value equality', () {
    final a = TemperatureSample.revision(
      thermostatId: 't1',
      revisionId: 'r1',
      valueC: 10,
      observedAt: timestamp,
    );
    final b = TemperatureSample.revision(
      thermostatId: 't1',
      revisionId: 'r1',
      valueC: 10,
      observedAt: timestamp,
    );
    final c = TemperatureSample.revision(
      thermostatId: 't1',
      revisionId: 'r2',
      valueC: 10,
      observedAt: timestamp,
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == c, isFalse);
  });

  group('AlertConfig', () {
    const base = AlertConfig(
      pollInterval: Duration(minutes: 5),
      exactAlarmsEnabled: false,
      soundUri: null,
      vibrate: true,
      volumeBoost: false,
      pauseAllUntil: null,
      githubToken: null,
    );

    test('has value equality', () {
      expect(base, base.copyWith());
      expect(base.hashCode, base.copyWith().hashCode);
      expect(base == base.copyWith(vibrate: false), isFalse);
    });

    test('withToken sets and clears the token (where copyWith cannot)', () {
      expect(base.withToken('ghp_x').githubToken, 'ghp_x');
      expect(base.withToken('ghp_x') == base, isFalse);
      // copyWith cannot clear a nullable; withToken can.
      expect(base.withToken('ghp_x').withToken(null).githubToken, isNull);
    });

    test('isPaused / remainingPause reflect the pause window', () {
      final now = DateTime.utc(2025, 1, 1, 12);

      expect(base.isPaused(now), isFalse);
      expect(base.remainingPause(now), isNull);

      final paused = base.copyWith(
        pauseAllUntil: now.add(const Duration(hours: 2)),
      );
      expect(paused.isPaused(now), isTrue);
      expect(paused.remainingPause(now), const Duration(hours: 2));

      final expired = base.copyWith(
        pauseAllUntil: now.subtract(const Duration(minutes: 1)),
      );
      expect(expired.isPaused(now), isFalse);
      expect(expired.remainingPause(now), isNull);
    });
  });
}
