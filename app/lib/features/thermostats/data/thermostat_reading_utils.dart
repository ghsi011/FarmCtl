import '../models/thermostat.dart';
import '../models/thermostat_state.dart';

/// Minimum spacing between consecutive alarms for the same thermostat.
const Duration kAlarmRateLimit = Duration(minutes: 5);

/// Floor for the stale-data threshold so very short poll intervals don't flag
/// a briefly quiet sensor as dead.
const Duration kMinStaleDataThreshold = Duration(minutes: 15);

/// Data age beyond which a sensor is considered silent (dead uploader):
/// max(3 × [pollInterval], [kMinStaleDataThreshold]).
Duration staleDataThreshold(Duration pollInterval) {
  final scaled = pollInterval * 3;
  return scaled > kMinStaleDataThreshold ? scaled : kMinStaleDataThreshold;
}

/// Whether a reading whose gist content was last updated at [dataUpdatedAt]
/// should be treated as stale at [now]. A null [dataUpdatedAt] (API omitted
/// the timestamp) is never stale — there is no data age to judge.
bool isThermostatDataStale({
  required DateTime? dataUpdatedAt,
  required DateTime now,
  required Duration pollInterval,
}) {
  if (dataUpdatedAt == null) {
    return false;
  }
  return now.difference(dataUpdatedAt) > staleDataThreshold(pollInterval);
}

/// Human message for a stale (silent-sensor) reading. Rendered in UTC so the
/// persisted message is unambiguous regardless of device timezone changes.
String formatStaleDataMessage(DateTime dataUpdatedAt) {
  final utc = dataUpdatedAt.toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  final timestamp =
      '${utc.year}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)} UTC';
  return 'No new data since $timestamp — sensor may be offline';
}

/// Decides whether an alarm-worthy reading (out-of-range or stale data) should
/// raise a fresh alarm, given the most recently persisted state. [alarmStatus]
/// is the status the caller is about to record; the rate limit only applies
/// while the persisted state already shows that same condition.
///
/// Pure so the rule is unit-testable and can be evaluated inside a database
/// transaction for an atomic compare-and-set on `lastAlarmAt` (avoiding the
/// duplicate-alarm / lost-silence races from deciding off a stale snapshot).
bool shouldTriggerAlarm({
  required ThermostatState? previousState,
  required DateTime now,
  Duration rateLimit = kAlarmRateLimit,
  ThermostatReadingStatus alarmStatus = ThermostatReadingStatus.outOfRange,
}) {
  if (previousState == null) {
    return true;
  }

  if (previousState.silenceUntilOk) {
    return false;
  }

  final snoozedUntil = previousState.snoozedUntil;
  if (snoozedUntil != null && now.isBefore(snoozedUntil)) {
    return false;
  }

  final lastAlarmAt = previousState.lastAlarmAt;
  if (lastAlarmAt != null && previousState.status == alarmStatus) {
    if (now.difference(lastAlarmAt) < rateLimit) {
      return false;
    }
  }

  return true;
}

bool isThermostatReadingOutOfRange({
  required Thermostat thermostat,
  required double currentValue,
  ThermostatState? previousState,
}) {
  final min = thermostat.minC;
  final max = thermostat.maxC;
  if (!thermostat.hysteresisEnabled) {
    return currentValue < min || currentValue > max;
  }

  final previouslyOut =
      previousState?.status == ThermostatReadingStatus.outOfRange;
  if (!previouslyOut) {
    return currentValue < min || currentValue > max;
  }

  final bufferMin = min + 1.0;
  final bufferMax = max - 1.0;
  if (bufferMin <= bufferMax) {
    return currentValue < bufferMin || currentValue > bufferMax;
  }

  // Range is narrower than hysteresis buffer; fall back to inclusive bounds.
  return currentValue < min || currentValue > max;
}

String formatOutOfRangeThermostatMessage(Thermostat thermostat, double valueC) {
  return 'Out of range: ${valueC.toStringAsFixed(2)}°C '
      '(${thermostat.minC.toStringAsFixed(2)}°C – '
      '${thermostat.maxC.toStringAsFixed(2)}°C)';
}
