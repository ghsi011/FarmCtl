// no imports needed

import '../models/history_range.dart';
import '../models/temperature_sample.dart';

class ThermostatHistoryDownsampler {
  const ThermostatHistoryDownsampler._();

  static List<TemperatureSample> downsample(
    List<TemperatureSample> samples,
    ThermostatHistoryRange range,
  ) {
    if (samples.length <= 1) {
      return samples;
    }

    final sorted = [...samples]
      ..sort((a, b) => a.observedAt.compareTo(b.observedAt));

    final bucketSeconds = _bucketSecondsForRange(range);

    final first = sorted.first.observedAt;

    final buckets = <int, _SampleBucket>{};
    for (final sample in sorted) {
      final offsetSeconds = sample.observedAt.difference(first).inSeconds;
      final bucketIndex = offsetSeconds ~/ bucketSeconds;
      final bucketStart = first.add(
        Duration(seconds: bucketIndex * bucketSeconds),
      );
      final bucket = buckets.putIfAbsent(
        bucketIndex,
        () => _SampleBucket(
          thermostatId: sample.thermostatId,
          bucketStart: bucketStart,
          bucketSeconds: bucketSeconds,
        ),
      );
      bucket.add(sample);
    }

    final aggregated = buckets.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return aggregated
        .map((entry) => entry.value.toSample(range))
        .toList(growable: false);
  }

  static int _bucketSecondsForRange(ThermostatHistoryRange range) {
    switch (range) {
      case ThermostatHistoryRange.hour:
        return 5 * 60; // 5 minutes
      case ThermostatHistoryRange.day:
        return 10 * 60; // 10 minutes
      case ThermostatHistoryRange.week:
        return 60 * 60; // 60 minutes
      case ThermostatHistoryRange.month:
        return 120 * 60; // 120 minutes
      case ThermostatHistoryRange.year:
        return 120 * 60; // 120 minutes
      case ThermostatHistoryRange.all:
        return 120 * 60; // 120 minutes
    }
  }
}

class _SampleBucket {
  _SampleBucket({
    required this.thermostatId,
    required this.bucketStart,
    required this.bucketSeconds,
  });

  final String thermostatId;
  final DateTime bucketStart;
  final int bucketSeconds;

  double _sum = 0;
  int _count = 0;
  String? _firstSourceId;

  void add(TemperatureSample sample) {
    _sum += sample.valueC;
    _count += 1;
    _firstSourceId ??= sample.sourceId;
  }

  TemperatureSample toSample(ThermostatHistoryRange range) {
    if (_count == 0) {
      throw StateError('Cannot create aggregated sample from empty bucket.');
    }

    final average = _sum / _count;
    final representative = bucketStart.add(
      Duration(seconds: bucketSeconds ~/ 2),
    );

    final observedAt = representative.isUtc
        ? representative
        : representative.toUtc();

    return TemperatureSample(
      id: '${thermostatId}_bucket_${bucketStart.millisecondsSinceEpoch}_${range.name}',
      thermostatId: thermostatId,
      valueC: average,
      observedAt: observedAt,
      source: _count == 1 ? 'revision' : 'aggregated',
      sourceId: _count == 1
          ? _firstSourceId
          : 'bucket-${bucketStart.millisecondsSinceEpoch}',
    );
  }
}
