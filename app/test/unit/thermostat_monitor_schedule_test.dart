import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/core/background/thermostat_monitor.dart';

void main() {
  group('shouldSkipMonitorRun', () {
    final now = DateTime.utc(2025, 1, 1, 12);

    test('does not skip when there is no prior run', () {
      expect(shouldSkipMonitorRun(lastRunStartedAt: null, now: now), isFalse);
    });

    test('skips a run that started within the debounce window', () {
      expect(
        shouldSkipMonitorRun(
          lastRunStartedAt: now.subtract(const Duration(seconds: 3)),
          now: now,
        ),
        isTrue,
      );
    });

    test('does not skip once the debounce window has elapsed', () {
      expect(
        shouldSkipMonitorRun(
          lastRunStartedAt: now.subtract(const Duration(seconds: 45)),
          now: now,
        ),
        isFalse,
      );
    });

    test('does not skip when the prior timestamp is in the future', () {
      // Guards against clock skew producing a negative elapsed time.
      expect(
        shouldSkipMonitorRun(
          lastRunStartedAt: now.add(const Duration(seconds: 10)),
          now: now,
        ),
        isFalse,
      );
    });

    test('honours a custom debounce window', () {
      expect(
        shouldSkipMonitorRun(
          lastRunStartedAt: now.subtract(const Duration(seconds: 90)),
          now: now,
          debounce: const Duration(minutes: 2),
        ),
        isTrue,
      );
    });
  });

  group('snoozeDurationForAction', () {
    test('maps each snooze action id to its duration', () {
      expect(
        snoozeDurationForAction('alarm_snooze_5'),
        const Duration(minutes: 5),
      );
      expect(
        snoozeDurationForAction('alarm_snooze_10'),
        const Duration(minutes: 10),
      );
      expect(
        snoozeDurationForAction('alarm_snooze_30'),
        const Duration(minutes: 30),
      );
    });

    test('returns null for silence, unknown, or null actions', () {
      expect(snoozeDurationForAction('alarm_silence_until_ok'), isNull);
      expect(snoozeDurationForAction('something_else'), isNull);
      expect(snoozeDurationForAction(null), isNull);
    });
  });

  group('pollIntervalMillis', () {
    test('converts a normal poll interval to milliseconds', () {
      expect(
        pollIntervalMillis(const Duration(minutes: 1)),
        const Duration(minutes: 1).inMilliseconds,
      );
      expect(
        pollIntervalMillis(const Duration(minutes: 30)),
        const Duration(minutes: 30).inMilliseconds,
      );
    });

    test('clamps below the defensive floor up to the floor', () {
      expect(
        pollIntervalMillis(Duration.zero),
        const Duration(seconds: 30).inMilliseconds,
      );
      expect(
        pollIntervalMillis(const Duration(seconds: 5)),
        const Duration(seconds: 30).inMilliseconds,
      );
    });

    test('honours a custom floor', () {
      expect(
        pollIntervalMillis(
          const Duration(seconds: 5),
          minimum: const Duration(seconds: 10),
        ),
        const Duration(seconds: 10).inMilliseconds,
      );
    });
  });
}
