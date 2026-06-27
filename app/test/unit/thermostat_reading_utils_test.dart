import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/data/thermostat_reading_utils.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';

Thermostat _thermostat({
  required double minC,
  required double maxC,
  bool hysteresisEnabled = false,
}) {
  final timestamp = DateTime.utc(2025, 1, 1);
  return Thermostat(
    id: 'id',
    name: 'Sensor',
    rawUrl: 'a' * 32,
    minC: minC,
    maxC: maxC,
    hysteresisEnabled: hysteresisEnabled,
    monitoringEnabled: true,
    createdAt: timestamp,
    updatedAt: timestamp,
  );
}

ThermostatState _state(ThermostatReadingStatus status) {
  final timestamp = DateTime.utc(2025, 1, 1);
  return ThermostatState(
    thermostatId: 'id',
    status: status,
    createdAt: timestamp,
    updatedAt: timestamp,
  );
}

bool _outOfRange(
  Thermostat thermostat,
  double value, {
  ThermostatState? previousState,
}) {
  return isThermostatReadingOutOfRange(
    thermostat: thermostat,
    currentValue: value,
    previousState: previousState,
  );
}

void main() {
  group('isThermostatReadingOutOfRange', () {
    group('hysteresis disabled — inclusive bounds', () {
      final thermostat = _thermostat(minC: 10, maxC: 20);

      test('values inside the range (including the bounds) are in range', () {
        expect(_outOfRange(thermostat, 10.0), isFalse);
        expect(_outOfRange(thermostat, 15.0), isFalse);
        expect(_outOfRange(thermostat, 20.0), isFalse);
      });

      test('values past either bound are out of range', () {
        expect(_outOfRange(thermostat, 9.9), isTrue);
        expect(_outOfRange(thermostat, 20.1), isTrue);
      });
    });

    group('hysteresis enabled, not previously out — entry bounds', () {
      final thermostat = _thermostat(
        minC: 10,
        maxC: 20,
        hysteresisEnabled: true,
      );

      test('uses inclusive entry bounds when previous state is null', () {
        expect(_outOfRange(thermostat, 20.0), isFalse);
        expect(_outOfRange(thermostat, 20.1), isTrue);
        expect(_outOfRange(thermostat, 9.9), isTrue);
      });

      test('uses inclusive entry bounds when previously OK', () {
        final previous = _state(ThermostatReadingStatus.ok);
        expect(_outOfRange(thermostat, 19.5, previousState: previous), isFalse);
        expect(_outOfRange(thermostat, 20.5, previousState: previous), isTrue);
      });
    });

    group(
      'hysteresis enabled, previously out — exit buffer (min+1 / max-1)',
      () {
        final thermostat = _thermostat(
          minC: 10,
          maxC: 20,
          hysteresisEnabled: true,
        );
        final previous = _state(ThermostatReadingStatus.outOfRange);

        test('stays out until the reading clears the exit buffer', () {
          // bufferMin = 11.0, bufferMax = 19.0
          expect(
            _outOfRange(thermostat, 19.5, previousState: previous),
            isTrue,
          );
          expect(
            _outOfRange(thermostat, 10.5, previousState: previous),
            isTrue,
          );
        });

        test('clears once the reading is inside the exit buffer', () {
          expect(
            _outOfRange(thermostat, 18.9, previousState: previous),
            isFalse,
          );
          expect(
            _outOfRange(thermostat, 11.0, previousState: previous),
            isFalse,
          );
        });
      },
    );

    group('hysteresis enabled, previously out, narrow range — fallback', () {
      // max - min < 2.0, so the exit buffer collapses and we fall back to the
      // inclusive bounds instead of an inverted buffer.
      final thermostat = _thermostat(
        minC: 19,
        maxC: 20,
        hysteresisEnabled: true,
      );
      final previous = _state(ThermostatReadingStatus.outOfRange);

      test('falls back to inclusive bounds', () {
        expect(_outOfRange(thermostat, 19.5, previousState: previous), isFalse);
        expect(_outOfRange(thermostat, 20.1, previousState: previous), isTrue);
        expect(_outOfRange(thermostat, 18.9, previousState: previous), isTrue);
      });
    });
  });
}
