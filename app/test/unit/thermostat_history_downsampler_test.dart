import 'package:farmctl/features/thermostats/models/history_range.dart';
import 'package:farmctl/features/thermostats/models/temperature_sample.dart';
import 'package:farmctl/features/thermostats/utils/thermostat_history_downsampler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ThermostatHistoryDownsampler', () {
    test('returns sorted samples when count below target', () {
      final samples = [
        TemperatureSample(
          id: 'b',
          thermostatId: 't1',
          valueC: 18.5,
          observedAt: DateTime.utc(2025, 1, 1, 12, 5),
          source: 'revision',
          sourceId: 'rev-b',
        ),
        TemperatureSample(
          id: 'a',
          thermostatId: 't1',
          valueC: 18.0,
          observedAt: DateTime.utc(2025, 1, 1, 12, 0),
          source: 'revision',
          sourceId: 'rev-a',
        ),
        TemperatureSample(
          id: 'c',
          thermostatId: 't1',
          valueC: 19.0,
          observedAt: DateTime.utc(2025, 1, 1, 12, 10),
          source: 'revision',
          sourceId: 'rev-c',
        ),
      ];

      final result = ThermostatHistoryDownsampler.downsample(
        samples,
        ThermostatHistoryRange.day,
      );

      expect(result, hasLength(3));
      expect(result[0].id, 'a');
      expect(result[1].id, 'b');
      expect(result[2].id, 'c');
      expect(result[0].observedAt.isBefore(result[1].observedAt), isTrue);
      expect(result[1].observedAt.isBefore(result[2].observedAt), isTrue);
    });

    test('downsamples dense data to target buckets', () {
      final start = DateTime.utc(2025, 1, 1, 0, 0);
      final samples = List.generate(300, (index) {
        return TemperatureSample(
          id: 's$index',
          thermostatId: 't1',
          valueC: index.toDouble(),
          observedAt: start.add(Duration(seconds: index)),
          source: 'revision',
          sourceId: 'rev-$index',
        );
      });

      final result = ThermostatHistoryDownsampler.downsample(
        samples,
        ThermostatHistoryRange.hour,
      );

      expect(result.length, lessThan(samples.length));
      expect(result.length, lessThanOrEqualTo(240));

      expect(result.first.valueC, closeTo(0.5, 1e-9));
      expect(result.first.observedAt, start.add(const Duration(seconds: 1)));

      expect(result.last.valueC, closeTo(298.5, 1e-9));
      expect(result.last.observedAt, start.add(const Duration(seconds: 299)));

      for (var i = 1; i < result.length; i += 1) {
        expect(
          result[i].observedAt.isBefore(result[i - 1].observedAt),
          isFalse,
        );
      }
    });
  });
}
