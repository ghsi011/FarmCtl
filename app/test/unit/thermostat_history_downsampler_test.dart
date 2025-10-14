import 'package:farmctl/features/thermostats/models/history_range.dart';
import 'package:farmctl/features/thermostats/models/temperature_sample.dart';
import 'package:farmctl/features/thermostats/utils/thermostat_history_downsampler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ThermostatHistoryDownsampler', () {
    test('aggregates into fixed 10-minute buckets for day range', () {
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

      // Two 10-minute buckets: [12:00–12:10) and [12:10–12:20)
      expect(result, hasLength(2));
      expect(result.first.valueC, closeTo(18.25, 1e-9));
      expect(result.first.observedAt, DateTime.utc(2025, 1, 1, 12, 5));
      expect(result.last.valueC, closeTo(19.0, 1e-9));
      // Representative time is bucket midpoint (12:15)
      expect(result.last.observedAt, DateTime.utc(2025, 1, 1, 12, 15));
    });

    test('downsamples to 5-minute buckets for hour range', () {
      final start = DateTime.utc(2025, 1, 1, 0, 0);
      // One-hour of per-second samples (3600)
      final samples = List.generate(3600, (index) {
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

      // 60 minutes / 5-minute buckets = 12 buckets
      expect(result.length, 12);

      // First bucket [0..299]
      expect(result.first.valueC, closeTo(149.5, 1e-9));
      expect(result.first.observedAt, start.add(const Duration(seconds: 150)));

      // Last bucket [3300..3599]
      expect(result.last.valueC, closeTo(3449.5, 1e-9));
      expect(result.last.observedAt, start.add(const Duration(seconds: 3450)));

      for (var i = 1; i < result.length; i += 1) {
        expect(
          result[i].observedAt.isBefore(result[i - 1].observedAt),
          isFalse,
        );
      }
    });
  });
}
