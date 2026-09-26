import 'package:flutter/foundation.dart';

@immutable
class DeviceDiagnosticsSnapshot {
  const DeviceDiagnosticsSnapshot({
    required this.deviceRef,
    required this.firmwareRunning,
    required this.sensorState,
    required this.consecutiveFailures,
    required this.heartbeatSeq,
    required this.gistUpdatedAt,
    required this.fetchedAt,
    this.lastSampleRef,
    this.reportedAt,
    this.events = const [],
    this.droppedEvents = 0,
  });

  final String deviceRef;
  final String firmwareRunning;
  final String sensorState;
  final int consecutiveFailures;
  final int heartbeatSeq;
  final DateTime? gistUpdatedAt;
  final DateTime fetchedAt;
  final String? lastSampleRef;
  final DateTime? reportedAt;
  final List<DeviceDiagnosticsEvent> events;
  final int droppedEvents;
}

@immutable
class DeviceDiagnosticsEvent {
  const DeviceDiagnosticsEvent({
    required this.id,
    required this.code,
    required this.count,
    this.occurredAt,
    this.uptimeSeconds,
  });

  final String id;
  final String code;
  final int count;
  final DateTime? occurredAt;
  final int? uptimeSeconds;
}
