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
      etag: etag ?? this.etag,
      statusMessage: statusMessage ?? this.statusMessage,
      lastAlarmAt: lastAlarmAt ?? this.lastAlarmAt,
      snoozedUntil: snoozedUntil ?? this.snoozedUntil,
      silenceUntilOk: silenceUntilOk ?? this.silenceUntilOk,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

@immutable
class ThermostatSummary {
  const ThermostatSummary({required this.thermostat, this.state});

  final Thermostat thermostat;
  final ThermostatState? state;
}

enum ThermostatReadingStatus {
  ok,
  outOfRange,
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
