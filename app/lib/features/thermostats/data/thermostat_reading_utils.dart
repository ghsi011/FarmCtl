import '../models/thermostat.dart';
import '../models/thermostat_state.dart';

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
