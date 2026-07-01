import 'package:flutter/foundation.dart';

import '../data/thermostat_database.dart';
import 'thermostat.dart';

@immutable
class ThermostatState {
  const ThermostatState({
    required this.thermostatId,
    required this.status,
    this.lastValueC,
    this.lastFetchedAt,
    this.dataUpdatedAt,
    this.etag,
    this.statusMessage,
    this.lastAlarmAt,
    this.snoozedUntil,
    this.silenceUntilOk = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String thermostatId;
  final ThermostatReadingStatus status;
  final double? lastValueC;
  final DateTime? lastFetchedAt;

  /// When the gist content itself was last updated (the sensor's observation
  /// time), unlike [lastFetchedAt] which advances on every successful HTTP
  /// fetch even when the content is unchanged. Null for legacy rows or when
  /// the API omitted the timestamp.
  final DateTime? dataUpdatedAt;

  final String? etag;
  final String? statusMessage;
  final DateTime? lastAlarmAt;
  final DateTime? snoozedUntil;
  final bool silenceUntilOk;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ThermostatState.fromEntry(ThermostatStateEntry entry) {
    return ThermostatState(
      thermostatId: entry.thermostatId,
      status: ThermostatReadingStatusX.fromName(entry.lastStatus),
      lastValueC: entry.lastValueC,
      lastFetchedAt: entry.lastFetchedAt?.toUtc(),
      dataUpdatedAt: entry.dataUpdatedAt?.toUtc(),
      etag: entry.etag,
      statusMessage: entry.statusMessage,
      lastAlarmAt: entry.lastAlarmAt?.toUtc(),
      snoozedUntil: entry.snoozedUntil?.toUtc(),
      silenceUntilOk: entry.silenceUntilOk,
      createdAt: entry.createdAt.toUtc(),
      updatedAt: entry.updatedAt.toUtc(),
    );
  }

  ThermostatState copyWith({
    ThermostatReadingStatus? status,
    double? lastValueC,
    DateTime? lastFetchedAt,
    DateTime? dataUpdatedAt,
    String? etag,
    String? statusMessage,
    DateTime? lastAlarmAt,
    DateTime? snoozedUntil,
    bool? silenceUntilOk,
    DateTime? updatedAt,
  }) {
    return ThermostatState(
      thermostatId: thermostatId,
      status: status ?? this.status,
      lastValueC: lastValueC ?? this.lastValueC,
      lastFetchedAt: lastFetchedAt ?? this.lastFetchedAt,
      dataUpdatedAt: dataUpdatedAt ?? this.dataUpdatedAt,
      etag: etag ?? this.etag,
      statusMessage: statusMessage ?? this.statusMessage,
      lastAlarmAt: lastAlarmAt ?? this.lastAlarmAt,
      snoozedUntil: snoozedUntil ?? this.snoozedUntil,
      silenceUntilOk: silenceUntilOk ?? this.silenceUntilOk,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThermostatState &&
          other.thermostatId == thermostatId &&
          other.status == status &&
          other.lastValueC == lastValueC &&
          other.lastFetchedAt == lastFetchedAt &&
          other.dataUpdatedAt == dataUpdatedAt &&
          other.etag == etag &&
          other.statusMessage == statusMessage &&
          other.lastAlarmAt == lastAlarmAt &&
          other.snoozedUntil == snoozedUntil &&
          other.silenceUntilOk == silenceUntilOk &&
          other.createdAt == createdAt &&
          other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(
    thermostatId,
    status,
    lastValueC,
    lastFetchedAt,
    dataUpdatedAt,
    etag,
    statusMessage,
    lastAlarmAt,
    snoozedUntil,
    silenceUntilOk,
    createdAt,
    updatedAt,
  );
}

@immutable
class ThermostatSummary {
  const ThermostatSummary({required this.thermostat, this.state});

  final Thermostat thermostat;
  final ThermostatState? state;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThermostatSummary &&
          other.thermostat == thermostat &&
          other.state == state;

  @override
  int get hashCode => Object.hash(thermostat, state);
}

enum ThermostatReadingStatus {
  ok,
  outOfRange,

  /// The fetch succeeded but the gist content hasn't changed for longer than
  /// the staleness threshold — the sensor-side uploader is likely dead.
  stale,
  networkError,
  httpError,
  parseError,
  unknown,
}

extension ThermostatReadingStatusX on ThermostatReadingStatus {
  static ThermostatReadingStatus fromName(String? value) {
    if (value == null || value.isEmpty) {
      return ThermostatReadingStatus.unknown;
    }
    return ThermostatReadingStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => ThermostatReadingStatus.unknown,
    );
  }
}
