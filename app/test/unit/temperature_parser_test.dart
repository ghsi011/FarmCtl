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

    test('fails closed on ambiguous numbers that drive alarm decisions', () {
      // Regression guards: these must never silently produce a wrong reading.
      expect(parseCelsiusTemperature('1,234.5C'), isNull);
      expect(parseCelsiusTemperature('.5C'), isNull);
      expect(parseCelsiusTemperature('sensor id abc123Cdef 7.7C'), equals(7.7));
    });
  });
}
