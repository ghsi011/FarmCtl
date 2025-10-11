/// Utilities for parsing thermostat readings from plain-text sources.
///
/// These helpers will evolve alongside the FarmCtl networking stack. For now
/// the parser extracts the first Fahrenheit value it finds in the provided
/// string.
double? parseFahrenheitTemperature(String raw) {
  final match = RegExp(
    r'(-?\d+(?:\.\d+)?)\s*°?F',
    caseSensitive: false,
  ).firstMatch(raw);
  if (match == null) {
    return null;
  }

  return double.tryParse(match.group(1)!);
}
