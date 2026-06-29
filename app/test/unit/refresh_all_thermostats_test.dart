import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';
import 'package:flutter_test/flutter_test.dart';

ThermostatSummary _summary(String id) {
  final now = DateTime.utc(2025, 1, 1);
  return ThermostatSummary(
    thermostat: Thermostat(
      id: id,
      name: 'Thermostat $id',
      rawUrl: 'gist-$id',
      minC: 0,
      maxC: 30,
      hysteresisEnabled: false,
      monitoringEnabled: true,
      createdAt: now,
      updatedAt: now,
    ),
  );
}

void main() {
  group('refreshAllThermostats', () {
    test('refreshes every thermostat in order', () async {
      final summaries = [_summary('a'), _summary('b'), _summary('c')];
      final refreshed = <String>[];

      await refreshAllThermostats(summaries, (thermostat) async {
        refreshed.add(thermostat.id);
      });

      expect(refreshed, ['a', 'b', 'c']);
    });

    test('continues past a thermostat whose refresh throws', () async {
      final summaries = [_summary('a'), _summary('b'), _summary('c')];
      final refreshed = <String>[];

      await refreshAllThermostats(summaries, (thermostat) async {
        refreshed.add(thermostat.id);
        if (thermostat.id == 'b') {
          throw StateError('network down');
        }
      });

      // 'b' threw but the sweep still reached 'c'.
      expect(refreshed, ['a', 'b', 'c']);
    });

    test('does nothing for an empty list', () async {
      var called = false;
      await refreshAllThermostats(const [], (_) async {
        called = true;
      });
      expect(called, isFalse);
    });
  });
}
