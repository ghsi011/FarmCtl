import '../models/thermostat.dart';
import '../models/thermostat_state.dart';

/// Minimum spacing between consecutive alarms for the same thermostat.
const Duration kAlarmRateLimit = Duration(minutes: 5);

/// Decides whether an out-of-range reading should raise a fresh alarm, given the
/// most recently persisted state.
///
/// Pure so the rule is unit-testable and can be evaluated inside a database
/// transaction for an atomic compare-and-set on `lastAlarmAt` (avoiding the
/// duplicate-alarm / lost-silence races from deciding off a stale snapshot).
bool shouldTriggerAlarm({
  required ThermostatState? previousState,
  required DateTime now,
  Duration rateLimit = kAlarmRateLimit,
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
  if (lastAlarmAt != null &&
      previousState.status == ThermostatReadingStatus.outOfRange) {
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
