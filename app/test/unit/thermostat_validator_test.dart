import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/models/thermostat.dart';

void main() {
  group('ThermostatValidator', () {
    test('accepts valid draft', () {
      final draft = ThermostatDraft(
        name: 'Greenhouse',
        rawUrl: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        minC: 2,
        maxC: 10,
      );

      final result = ThermostatValidator.validate(draft);

      expect(result.isValid, isTrue);
    });

    test('rejects invalid name', () {
      final draft = ThermostatDraft(
        name: '',
        rawUrl: 'https://example.com',
        minC: 2,
        maxC: 10,
      );

      final result = ThermostatValidator.validate(draft);

      expect(result.isValid, isFalse);
      expect(
        result.errors
            .firstWhere(
              (error) => error.field == ThermostatValidationField.name,
            )
            .message,
        contains('1 and 40'),
      );
    });

    test('rejects invalid gist id', () {
      final draft = ThermostatDraft(
        name: 'Greenhouse',
        rawUrl: 'not-a-gist-id',
        minC: 2,
        maxC: 10,
      );

      final result = ThermostatValidator.validate(draft);

      expect(result.isValid, isFalse);
      final msg = result.errors
          .firstWhere(
            (error) => error.field == ThermostatValidationField.rawUrl,
          )
          .message;
      expect(msg, contains('Gist ID'));
    });

    test('rejects out-of-bounds temperatures', () {
      final draft = ThermostatDraft(
        name: 'Greenhouse',
        rawUrl: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        minC: -100,
        maxC: 500,
      );

      final result = ThermostatValidator.validate(draft);

      expect(result.isValid, isFalse);
      final minError = result.errors.firstWhere(
        (error) => error.field == ThermostatValidationField.minC,
      );
      final maxError = result.errors.firstWhere(
        (error) => error.field == ThermostatValidationField.maxC,
      );
      expect(minError.message, contains('-80'));
      expect(maxError.message, contains('200'));
    });

    test('rejects inverted range', () {
      final draft = ThermostatDraft(
        name: 'Greenhouse',
        rawUrl: 'cccccccccccccccccccccccccccccccc',
        minC: 12,
        maxC: 10,
      );

      final result = ThermostatValidator.validate(draft);

      expect(result.isValid, isFalse);
      expect(
        result.errors
            .firstWhere(
              (error) => error.field == ThermostatValidationField.range,
            )
            .message,
        contains('less than'),
      );
    });
  });
}
