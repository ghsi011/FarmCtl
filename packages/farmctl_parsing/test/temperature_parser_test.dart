import 'package:farmctl_parsing/temperature_parser.dart';
import 'package:test/test.dart';

void main() {
  group('parseCelsiusTemperature', () {
    test('extracts Celsius value when present', () {
      expect(parseCelsiusTemperature('Temperature: 8.13°C'), equals(8.13));
    });

    test('handles decimals and negative numbers', () {
      expect(parseCelsiusTemperature('Reading:-10.5C'), equals(-10.5));
      expect(
        parseCelsiusTemperature('value 12.25 °c recorded'),
        equals(12.25),
      );
    });

    test('returns null when no match is found', () {
      expect(parseCelsiusTemperature('no reading available'), isNull);
    });
  });
}
