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
    required this.createdAt,
    required this.updatedAt,
  });

  final String thermostatId;
  final ThermostatReadingStatus status;
  final double? lastValueC;
  final DateTime? lastFetchedAt;
  final String? etag;
  final String? statusMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ThermostatState.fromEntry(ThermostatStateEntry entry) {
    return ThermostatState(
      thermostatId: entry.thermostatId,
      status: ThermostatReadingStatusX.fromName(entry.lastStatus),
      lastValueC: entry.lastValueC,
      lastFetchedAt: entry.lastFetchedAt,
      etag: entry.etag,
      statusMessage: entry.statusMessage,
      createdAt: entry.createdAt,
      updatedAt: entry.updatedAt,
    );
  }

  ThermostatState copyWith({
    ThermostatReadingStatus? status,
    double? lastValueC,
    DateTime? lastFetchedAt,
    String? etag,
    String? statusMessage,
    DateTime? updatedAt,
  }) {
    return ThermostatState(
      thermostatId: thermostatId,
      status: status ?? this.status,
      lastValueC: lastValueC ?? this.lastValueC,
      lastFetchedAt: lastFetchedAt ?? this.lastFetchedAt,
      etag: etag ?? this.etag,
      statusMessage: statusMessage ?? this.statusMessage,
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
