import 'package:farmctl_parsing/temperature_parser.dart';
import 'package:test/test.dart';

void main() {
  group('parseFahrenheitTemperature', () {
    test('returns a double when the input contains a Fahrenheit value', () {
      final result = parseFahrenheitTemperature('Current temp: 68°F');
      expect(result, equals(68));
    });

    test('supports decimal and negative readings', () {
      expect(parseFahrenheitTemperature('Reading: -4.5 °f'), equals(-4.5));
      expect(
        parseFahrenheitTemperature('now 102.75F recorded'),
        equals(102.75),
      );
    });

    test('returns null when no Fahrenheit token is found', () {
      expect(parseFahrenheitTemperature('No data available'), isNull);
    });
  });
}
