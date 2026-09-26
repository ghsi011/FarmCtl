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
    this.firmwareRetainedGood,
    this.firmwareRunningConfigSchema,
    this.firmwareRetainedConfigSchema,
    this.configurationStatus,
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
  final String? firmwareRetainedGood;
  final int? firmwareRunningConfigSchema;
  final int? firmwareRetainedConfigSchema;
  final DeviceDiagnosticsConfigurationStatus? configurationStatus;

  /// Indicates the snapshot has the metadata needed to support schema-1
  /// configuration. Callers must still verify a fresh device association.
  bool get supportsFleetSchema1 =>
      firmwareRunningConfigSchema == 1 &&
      firmwareRetainedConfigSchema == 1 &&
      firmwareRetainedGood != null;

  /// The device reports this exact change as applied, but only when the caller
  /// has independently established that this snapshot is fresh.
  bool isApplied(String changeId, {required bool isFresh}) =>
      isFresh && configurationStatus?.appliedId == changeId;
}

@immutable
class DeviceDiagnosticsConfigurationStatus {
  const DeviceDiagnosticsConfigurationStatus({
    this.appliedId,
    this.lastAttempt,
  });

  final String? appliedId;
  final DeviceDiagnosticsConfigurationAttempt? lastAttempt;
}

@immutable
class DeviceDiagnosticsConfigurationAttempt {
  const DeviceDiagnosticsConfigurationAttempt({
    required this.fleetRevision,
    required this.changeId,
    required this.state,
    this.reason,
  });

  final String fleetRevision;
  final String changeId;
  final String state;
  final String? reason;
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
