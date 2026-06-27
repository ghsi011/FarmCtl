import 'package:flutter/foundation.dart';

@immutable
class TemperatureSample {
  const TemperatureSample({
    required this.id,
    required this.thermostatId,
    required this.valueC,
    required this.observedAt,
    required this.source,
    this.sourceId,
  });

  final String id;
  final String thermostatId;
  final double valueC;
  final DateTime observedAt;
  final String source;
  final String? sourceId;

  TemperatureSample copyWith({
    String? id,
    String? thermostatId,
    double? valueC,
    DateTime? observedAt,
    String? source,
    String? sourceId,
  }) {
    return TemperatureSample(
      id: id ?? this.id,
      thermostatId: thermostatId ?? this.thermostatId,
      valueC: valueC ?? this.valueC,
      observedAt: observedAt ?? this.observedAt,
      source: source ?? this.source,
      sourceId: sourceId ?? this.sourceId,
    );
  }

  factory TemperatureSample.revision({
    required String thermostatId,
    required String revisionId,
    required double valueC,
    required DateTime observedAt,
  }) {
    return TemperatureSample(
      id: '${thermostatId}_revision_$revisionId',
      thermostatId: thermostatId,
      valueC: valueC,
      observedAt: observedAt,
      source: 'revision',
      sourceId: revisionId,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TemperatureSample &&
          other.id == id &&
          other.thermostatId == thermostatId &&
          other.valueC == valueC &&
          other.observedAt == observedAt &&
          other.source == source &&
          other.sourceId == sourceId;

  @override
  int get hashCode =>
      Object.hash(id, thermostatId, valueC, observedAt, source, sourceId);
}
