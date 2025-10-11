import 'package:farmctl_parsing/temperature_parser.dart';
import 'package:test/test.dart';

void main() {
  group('parseFahrenheitTemperature', () {
    test('extracts Fahrenheit value when present', () {
      expect(parseFahrenheitTemperature('Temperature: 68°F'), equals(68));
    });

    test('handles decimals and negative numbers', () {
      expect(parseFahrenheitTemperature('Reading:-10.5F'), equals(-10.5));
      expect(
        parseFahrenheitTemperature('value 101.25 °f recorded'),
        equals(101.25),
      );
    });

    test('returns null when no match is found', () {
      expect(parseFahrenheitTemperature('no reading available'), isNull);
    });
  });
}
