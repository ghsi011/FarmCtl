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

  group('shouldTriggerAlarm', () {
    final now = DateTime.utc(2025, 1, 1, 12);

    ThermostatState stateWith({
      ThermostatReadingStatus status = ThermostatReadingStatus.outOfRange,
      DateTime? lastAlarmAt,
      DateTime? snoozedUntil,
      bool silenceUntilOk = false,
    }) {
      final timestamp = DateTime.utc(2025, 1, 1);
      return ThermostatState(
        thermostatId: 'id',
        status: status,
        lastAlarmAt: lastAlarmAt,
        snoozedUntil: snoozedUntil,
        silenceUntilOk: silenceUntilOk,
        createdAt: timestamp,
        updatedAt: timestamp,
      );
    }

    test('fires when there is no previous state', () {
      expect(shouldTriggerAlarm(previousState: null, now: now), isTrue);
    });

    test('does not fire while silenced until OK', () {
      expect(
        shouldTriggerAlarm(
          previousState: stateWith(silenceUntilOk: true),
          now: now,
        ),
        isFalse,
      );
    });

    test('does not fire during an active snooze', () {
      expect(
        shouldTriggerAlarm(
          previousState: stateWith(
            snoozedUntil: now.add(const Duration(minutes: 5)),
          ),
          now: now,
        ),
        isFalse,
      );
    });

    test('fires once the snooze has expired', () {
      expect(
        shouldTriggerAlarm(
          previousState: stateWith(
            snoozedUntil: now.subtract(const Duration(minutes: 1)),
          ),
          now: now,
        ),
        isTrue,
      );
    });

    test('rate-limits within the window when previously out of range', () {
      expect(
        shouldTriggerAlarm(
          previousState: stateWith(
            lastAlarmAt: now.subtract(const Duration(minutes: 4)),
          ),
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldTriggerAlarm(
          previousState: stateWith(
            lastAlarmAt: now.subtract(const Duration(minutes: 6)),
          ),
          now: now,
        ),
        isTrue,
      );
    });

    test(
      'does not rate-limit when the previous status was not out of range',
      () {
        expect(
          shouldTriggerAlarm(
            previousState: stateWith(
              status: ThermostatReadingStatus.ok,
              lastAlarmAt: now.subtract(const Duration(minutes: 1)),
            ),
            now: now,
          ),
          isTrue,
        );
      },
    );

    test('rate-limits a stale alarm only against a persisted stale state', () {
      // Same stale condition persisted -> rate limit applies.
      expect(
        shouldTriggerAlarm(
          previousState: stateWith(
            status: ThermostatReadingStatus.stale,
            lastAlarmAt: now.subtract(const Duration(minutes: 4)),
          ),
          now: now,
          alarmStatus: ThermostatReadingStatus.stale,
        ),
        isFalse,
      );
      // Different persisted condition (out of range) -> a fresh stale alarm
      // is not rate-limited.
      expect(
        shouldTriggerAlarm(
          previousState: stateWith(
            lastAlarmAt: now.subtract(const Duration(minutes: 1)),
          ),
          now: now,
          alarmStatus: ThermostatReadingStatus.stale,
        ),
        isTrue,
      );
    });
  });

  group('staleDataThreshold', () {
    test('floors at 15 minutes for short poll intervals', () {
      expect(
        staleDataThreshold(const Duration(minutes: 1)),
        const Duration(minutes: 15),
      );
      expect(
        staleDataThreshold(const Duration(minutes: 5)),
        const Duration(minutes: 15),
      );
    });

    test('scales to 3x for longer poll intervals', () {
      expect(
        staleDataThreshold(const Duration(minutes: 10)),
        const Duration(minutes: 30),
      );
      expect(
        staleDataThreshold(const Duration(minutes: 30)),
        const Duration(minutes: 90),
      );
    });
  });

  group('isThermostatDataStale', () {
    final now = DateTime.utc(2025, 1, 1, 12);

    test('null data timestamp is never stale', () {
      expect(
        isThermostatDataStale(
          dataUpdatedAt: null,
          now: now,
          pollInterval: const Duration(minutes: 5),
        ),
        isFalse,
      );
    });

    test('flags data older than the threshold', () {
      expect(
        isThermostatDataStale(
          dataUpdatedAt: now.subtract(const Duration(minutes: 16)),
          now: now,
          pollInterval: const Duration(minutes: 5),
        ),
        isTrue,
      );
      expect(
        isThermostatDataStale(
          dataUpdatedAt: now.subtract(const Duration(minutes: 14)),
          now: now,
          pollInterval: const Duration(minutes: 5),
        ),
        isFalse,
      );
    });
  });

  group('formatStaleDataMessage', () {
    test('renders the data time in UTC with a clear hint', () {
      expect(
        formatStaleDataMessage(DateTime.utc(2025, 1, 1, 10, 59)),
        'No new data since 2025-01-01 10:59 UTC — sensor may be offline',
      );
    });

    test('converts non-UTC input to UTC', () {
      final local = DateTime.utc(2025, 6, 5, 4, 3).toLocal();
      expect(
        formatStaleDataMessage(local),
        'No new data since 2025-06-05 04:03 UTC — sensor may be offline',
      );
    });
  });
}
