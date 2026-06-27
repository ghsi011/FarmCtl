/// Utilities for parsing thermostat readings from plain-text sources.
///
/// Extracts the first Celsius value found in the provided string. Tolerates an
/// optional degree symbol and whitespace, and is case-insensitive for the unit.
///
/// The matcher is deliberately boundary-anchored and **fails closed** (returns
/// `null`) on ambiguous input. Because the parsed value drives every alarm
/// decision, a reading we cannot extract confidently is reported as "no value"
/// (surfaced as a parse error upstream) rather than a silently wrong number.
///
/// Specifically, the number (including any leading `-`) must not be preceded by
/// a word character, `.`, `,` or `-` (so digits embedded in identifiers like
/// `abc123Cdef`, thousands separators like `1,234.5C`, leading-dot values like
/// `.5C`, and a hyphen glued to a word like `Outside-5C` do not produce a
/// truncated or sign-flipped reading), and the `C`/`c` unit must not be followed
/// by another letter or digit (so `7.7Cdef` or a stray lowercase `c` inside a
/// token such as `"v3c"` is not mistaken for a unit). Whitespace is tolerated
/// around the degree glyph (`21.5 °C`, `21.5° C`).
double? parseCelsiusTemperature(String raw) {
  final match = RegExp(
    r'(?<![\w.,-])(-?\d+(?:\.\d+)?)\s*°?\s*[Cc](?![A-Za-z0-9])',
  ).firstMatch(raw);
  if (match == null) {
    return null;
  }

  return double.tryParse(match.group(1)!);
}
