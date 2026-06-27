import 'package:farmctl_parsing/temperature_parser.dart';
import 'package:test/test.dart';

void main() {
  group('parseCelsiusTemperature — valid readings', () {
    test('extracts Celsius value with degree symbol', () {
      expect(parseCelsiusTemperature('Temperature: 8.13°C'), equals(8.13));
    });

    test('handles decimals and negative numbers', () {
      expect(parseCelsiusTemperature('Reading:-10.5C'), equals(-10.5));
      expect(parseCelsiusTemperature('value 12.25 °c recorded'), equals(12.25));
    });

    test('handles integers and a space before the degree symbol', () {
      expect(parseCelsiusTemperature('23°C'), equals(23.0));
      expect(parseCelsiusTemperature('Now 23 °C'), equals(23.0));
    });

    test('accepts a signed value after an equals sign', () {
      expect(parseCelsiusTemperature('temp=-3.5C'), equals(-3.5));
    });

    test('returns the first valid Celsius token when several are present', () {
      expect(parseCelsiusTemperature('A 5C then 9C'), equals(5.0));
    });

    test('skips identifier noise and finds the real labelled reading', () {
      // The leading "123" inside "abc123Cdef" must NOT be parsed as 123°C;
      // the genuine "7.7C" token at the end is the correct extraction.
      expect(parseCelsiusTemperature('ID: abc123Cdef 7.7C'), equals(7.7));
    });
  });

  group('parseCelsiusTemperature — fails closed on ambiguous input', () {
    test('returns null when no Celsius token is found', () {
      expect(parseCelsiusTemperature('no reading available'), isNull);
    });

    test('does not parse a thousands-separated number (avoids truncation)', () {
      // Previously parsed as 234.5 by grabbing the fragment after the comma.
      expect(parseCelsiusTemperature('1,234.5C'), isNull);
    });

    test(
      'does not parse a leading-dot value (avoids dropping the integer)',
      () {
        // Previously parsed as 5.0 instead of 0.5.
        expect(parseCelsiusTemperature('.5C'), isNull);
      },
    );

    test('does not match a stray lowercase c inside an identifier', () {
      // Previously parsed "v3c" as 3.0.
      expect(parseCelsiusTemperature('{"temp": 7.7, "id": "v3c"}'), isNull);
    });

    test('does not match a value glued to a trailing identifier', () {
      expect(parseCelsiusTemperature('7.7Cdef'), isNull);
      expect(parseCelsiusTemperature('25C3'), isNull);
    });

    test('does not match other units (Fahrenheit / Kelvin)', () {
      expect(parseCelsiusTemperature('Reading: 70F'), isNull);
      expect(parseCelsiusTemperature('300K'), isNull);
    });
  });
}
