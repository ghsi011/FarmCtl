import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/models/history_range.dart';

void main() {
  group('ThermostatHistoryRange', () {
    test('window matches the named span; "All" is unbounded', () {
      expect(ThermostatHistoryRange.hour.window, const Duration(hours: 1));
      expect(ThermostatHistoryRange.day.window, const Duration(days: 1));
      expect(ThermostatHistoryRange.week.window, const Duration(days: 7));
      expect(ThermostatHistoryRange.month.window, const Duration(days: 30));
      expect(ThermostatHistoryRange.year.window, const Duration(days: 365));
      expect(ThermostatHistoryRange.all.window, isNull);
    });

    test('every value has a distinct, non-empty label and description', () {
      final labels = <String>{};
      final descriptions = <String>{};
      for (final range in ThermostatHistoryRange.values) {
        expect(range.label, isNotEmpty);
        expect(range.description, isNotEmpty);
        labels.add(range.label);
        descriptions.add(range.description);
      }
      expect(labels, hasLength(ThermostatHistoryRange.values.length));
      expect(descriptions, hasLength(ThermostatHistoryRange.values.length));
      expect(ThermostatHistoryRange.day.label, '24H');
      expect(ThermostatHistoryRange.all.label, 'All');
    });

    group('thermostatHistoryRangeFromName', () {
      test('round-trips every enum name', () {
        for (final range in ThermostatHistoryRange.values) {
          expect(thermostatHistoryRangeFromName(range.name), range);
        }
      });

      test('returns null for null, empty, or unknown names', () {
        // Guards the history route's ?range= query-param parse against bad input.
        expect(thermostatHistoryRangeFromName(null), isNull);
        expect(thermostatHistoryRangeFromName(''), isNull);
        expect(thermostatHistoryRangeFromName('decade'), isNull);
        expect(
          thermostatHistoryRangeFromName('Hour'),
          isNull,
        ); // case-sensitive
      });
    });
  });
}
