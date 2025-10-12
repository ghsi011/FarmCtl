import 'package:farmctl_parsing/temperature_parser.dart';
import 'package:test/test.dart';

void main() {
  group('parseCelsiusTemperature', () {
    test('returns a double when the input contains a Celsius value', () {
      final result = parseCelsiusTemperature('Current temp: 8.0°C');
      expect(result, equals(8.0));
    });

    test('supports decimal and negative readings', () {
      expect(parseCelsiusTemperature('Reading: -4.5 °c'), equals(-4.5));
      expect(parseCelsiusTemperature('now 12.75C recorded'), equals(12.75));
    });

    test('returns null when no Celsius token is found', () {
      expect(parseCelsiusTemperature('No data available'), isNull);
    });
  });
}
