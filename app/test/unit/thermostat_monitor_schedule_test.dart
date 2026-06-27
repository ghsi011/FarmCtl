import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/core/background/thermostat_monitor.dart';
import 'package:farmctl/features/settings/models/alert_config.dart';

AlertConfig _config({
  Duration interval = const Duration(minutes: 5),
  DateTime? pauseUntil,
}) {
  return AlertConfig(
    pollInterval: interval,
    exactAlarmsEnabled: false,
    soundUri: null,
    vibrate: true,
    volumeBoost: false,
    pauseAllUntil: pauseUntil,
    githubToken: null,
  );
}

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

  group('nextMonitorRunUtc', () {
    final now = DateTime.utc(2025, 1, 1, 12);

    test('schedules the next run exactly one poll interval ahead', () {
      expect(
        nextMonitorRunUtc(_config(interval: const Duration(minutes: 1)), now),
        now.add(const Duration(minutes: 1)),
      );
      expect(
        nextMonitorRunUtc(_config(interval: const Duration(minutes: 5)), now),
        now.add(const Duration(minutes: 5)),
      );
      expect(
        nextMonitorRunUtc(_config(interval: const Duration(minutes: 30)), now),
        now.add(const Duration(minutes: 30)),
      );
    });

    test('returns null for a non-positive interval (monitoring off)', () {
      expect(nextMonitorRunUtc(_config(interval: Duration.zero), now), isNull);
    });

    test('defers the next run to the end of an active pause', () {
      final pauseUntil = now.add(const Duration(hours: 1));
      expect(
        nextMonitorRunUtc(
          _config(interval: const Duration(minutes: 5), pauseUntil: pauseUntil),
          now,
        ),
        pauseUntil,
      );
    });

    test('ignores a pause that ends before the next interval', () {
      final pauseUntil = now.add(const Duration(minutes: 2));
      expect(
        nextMonitorRunUtc(
          _config(interval: const Duration(minutes: 5), pauseUntil: pauseUntil),
          now,
        ),
        now.add(const Duration(minutes: 5)),
      );
    });
  });

  group('effectiveMonitorFrequency', () {
    test('clamps sub-15-minute intervals up to the platform floor', () {
      // WorkManager cannot run more often than every 15 minutes; the precise
      // sub-15-minute cadence is driven by the AlarmManager one-shot instead.
      expect(
        effectiveMonitorFrequency(const Duration(minutes: 1)),
        const Duration(minutes: 15),
      );
      expect(
        effectiveMonitorFrequency(const Duration(minutes: 5)),
        const Duration(minutes: 15),
      );
      expect(
        effectiveMonitorFrequency(const Duration(minutes: 15)),
        const Duration(minutes: 15),
      );
    });

    test('honours intervals at or above the floor', () {
      expect(
        effectiveMonitorFrequency(const Duration(minutes: 20)),
        const Duration(minutes: 20),
      );
      expect(
        effectiveMonitorFrequency(const Duration(minutes: 30)),
        const Duration(minutes: 30),
      );
    });
  });
}
