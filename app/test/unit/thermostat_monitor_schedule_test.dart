import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/core/background/thermostat_monitor.dart';
import 'package:farmctl/features/settings/models/alert_config.dart';

AlertConfig _config({
  Duration pollInterval = const Duration(minutes: 5),
  DateTime? pauseAllUntil,
}) {
  return AlertConfig(
    pollInterval: pollInterval,
    soundUri: null,
    vibrate: true,
    volumeBoost: false,
    pauseAllUntil: pauseAllUntil,
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

  group('effectiveServiceInterval', () {
    final now = DateTime.utc(2025, 1, 1, 12);

    test('uses the poll interval when not paused', () {
      expect(
        effectiveServiceInterval(
          _config(pollInterval: const Duration(minutes: 5)),
          now,
        ),
        const Duration(minutes: 5),
      );
    });

    test('sleeps until the pause ends when the pause is longer', () {
      final config = _config(
        pollInterval: const Duration(minutes: 5),
        pauseAllUntil: now.add(const Duration(hours: 8)),
      );
      expect(effectiveServiceInterval(config, now), const Duration(hours: 8));
    });

    test('keeps the poll interval when the remaining pause is shorter', () {
      final config = _config(
        pollInterval: const Duration(minutes: 5),
        pauseAllUntil: now.add(const Duration(minutes: 2)),
      );
      expect(effectiveServiceInterval(config, now), const Duration(minutes: 5));
    });

    test('keeps the poll interval when the remaining pause equals it', () {
      // Boundary: the impl uses a strict `>`, so an exactly-equal remaining
      // pause must NOT stretch (which would delay the post-pause wake a cycle).
      final config = _config(
        pollInterval: const Duration(minutes: 5),
        pauseAllUntil: now.add(const Duration(minutes: 5)),
      );
      expect(effectiveServiceInterval(config, now), const Duration(minutes: 5));
    });

    test('keeps the poll interval once the pause has elapsed', () {
      final config = _config(
        pollInterval: const Duration(minutes: 5),
        pauseAllUntil: now.subtract(const Duration(minutes: 1)),
      );
      expect(effectiveServiceInterval(config, now), const Duration(minutes: 5));
    });
  });

  group('nextMonitorHealth', () {
    test('a success from a clean state does nothing', () {
      final r = nextMonitorHealth(
        failures: 0,
        degraded: false,
        runSucceeded: true,
      );
      expect(r.failures, 0);
      expect(r.degraded, isFalse);
      expect(r.action, MonitorNotificationAction.none);
    });

    test('a single failure does not yet degrade (threshold 2)', () {
      final r = nextMonitorHealth(
        failures: 0,
        degraded: false,
        runSucceeded: false,
      );
      expect(r.failures, 1);
      expect(r.degraded, isFalse);
      expect(r.action, MonitorNotificationAction.none);
    });

    test('the second consecutive failure flips to degraded exactly once', () {
      final r = nextMonitorHealth(
        failures: 1,
        degraded: false,
        runSucceeded: false,
      );
      expect(r.failures, 2);
      expect(r.degraded, isTrue);
      expect(r.action, MonitorNotificationAction.showDegraded);
    });

    test('further failures while degraded emit no repeat notification', () {
      final r = nextMonitorHealth(
        failures: 2,
        degraded: true,
        runSucceeded: false,
      );
      expect(r.failures, 3);
      expect(r.degraded, isTrue);
      expect(r.action, MonitorNotificationAction.none);
    });

    test('recovery from degraded restores the healthy notification once', () {
      final r = nextMonitorHealth(
        failures: 3,
        degraded: true,
        runSucceeded: true,
      );
      expect(r.failures, 0);
      expect(r.degraded, isFalse);
      expect(r.action, MonitorNotificationAction.showHealthy);
    });

    test('honours a custom threshold', () {
      final r = nextMonitorHealth(
        failures: 0,
        degraded: false,
        runSucceeded: false,
        threshold: 1,
      );
      expect(r.action, MonitorNotificationAction.showDegraded);
    });
  });
}
