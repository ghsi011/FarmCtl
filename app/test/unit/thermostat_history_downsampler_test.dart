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
      // Representative time is the mean of the contained samples (12:00, 12:05),
      // not the bucket centre.
      expect(result.first.observedAt, DateTime.utc(2025, 1, 1, 12, 2, 30));
      expect(result.last.valueC, closeTo(19.0, 1e-9));
      // Single-sample bucket maps to that sample's own time (12:10), not 12:15.
      expect(result.last.observedAt, DateTime.utc(2025, 1, 1, 12, 10));
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

      // First bucket [0..299] — representative is the mean of the contained
      // observedAt values (seconds 0..299 -> 149.5s), not the bucket centre.
      expect(result.first.valueC, closeTo(149.5, 1e-9));
      expect(
        result.first.observedAt,
        start.add(const Duration(milliseconds: 149500)),
      );

      // Last bucket [3300..3599] -> mean 3449.5s
      expect(result.last.valueC, closeTo(3449.5, 1e-9));
      expect(
        result.last.observedAt,
        start.add(const Duration(milliseconds: 3449500)),
      );

      for (var i = 1; i < result.length; i += 1) {
        expect(
          result[i].observedAt.isBefore(result[i - 1].observedAt),
          isFalse,
        );
      }
    });

    test('trailing partial bucket is not shifted into the future', () {
      // A dense first bucket, then a single recent sample alone in the trailing
      // bucket. The trailing point must be plotted at its real time, never later.
      final base = DateTime.utc(2025, 1, 1, 0, 0);
      final samples = <TemperatureSample>[
        for (var i = 0; i < 3; i++)
          TemperatureSample(
            id: 'a$i',
            thermostatId: 't1',
            valueC: 10.0 + i,
            observedAt: base.add(Duration(minutes: i * 20)), // 0, 20, 40 min
            source: 'revision',
            sourceId: 'rev-a$i',
          ),
        // Lands ~5 min into the next 60-min (week) bucket.
        TemperatureSample(
          id: 'recent',
          thermostatId: 't1',
          valueC: 21.0,
          observedAt: base.add(const Duration(minutes: 65)),
          source: 'revision',
          sourceId: 'rev-recent',
        ),
      ];

      final result = ThermostatHistoryDownsampler.downsample(
        samples,
        ThermostatHistoryRange.week,
      );

      final last = result.last;
      expect(last.valueC, closeTo(21.0, 1e-9));
      // Plotted at the sample's own time, not the bucket midpoint (~90 min).
      expect(last.observedAt, base.add(const Duration(minutes: 65)));
      expect(last.observedAt.isAfter(samples.last.observedAt), isFalse);
    });
  });
}
