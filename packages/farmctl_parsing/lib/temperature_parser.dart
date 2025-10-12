/// Utilities for parsing thermostat readings from plain-text sources.
///
/// Extracts the first Celsius value found in the provided string. Tolerates
/// optional degree symbol and whitespace, is case-insensitive for the unit.
double? parseCelsiusTemperature(String raw) {
  final match = RegExp(
    r'(-?\d+(?:\.\d+)?)\s*°?C',
    caseSensitive: false,
  ).firstMatch(raw);
  if (match == null) {
    return null;
  }

  return double.tryParse(match.group(1)!);
}
