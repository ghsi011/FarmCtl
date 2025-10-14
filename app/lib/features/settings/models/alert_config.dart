import 'package:flutter/foundation.dart';

import '../../thermostats/data/thermostat_database.dart';

@immutable
class AlertConfig {
  const AlertConfig({
    required this.pollInterval,
    required this.exactAlarmsEnabled,
    required this.soundUri,
    required this.vibrate,
    required this.volumeBoost,
    required this.pauseAllUntil,
    required this.githubToken,
  });

  final Duration pollInterval;
  final bool exactAlarmsEnabled;
  final String? soundUri;
  final bool vibrate;
  final bool volumeBoost;
  final DateTime? pauseAllUntil;
  final String? githubToken;

  factory AlertConfig.fromEntry(AlertConfigEntry entry) {
    return AlertConfig(
      pollInterval: Duration(minutes: entry.pollIntervalMin),
      exactAlarmsEnabled: entry.exactAlarmsEnabled,
      soundUri: entry.soundUri,
      vibrate: entry.vibrate,
      volumeBoost: entry.volumeBoost,
      pauseAllUntil: entry.pauseAllUntil?.toUtc(),
      githubToken: entry.githubToken,
    );
  }

  bool isPaused(DateTime now) {
    final until = pauseAllUntil;
    if (until == null) {
      return false;
    }
    return now.isBefore(until);
  }

  Duration? remainingPause(DateTime now) {
    if (!isPaused(now)) {
      return null;
    }
    return pauseAllUntil!.difference(now);
  }

  AlertConfig copyWith({
    Duration? pollInterval,
    bool? exactAlarmsEnabled,
    String? soundUri,
    bool? vibrate,
    bool? volumeBoost,
    DateTime? pauseAllUntil,
    String? githubToken,
  }) {
    return AlertConfig(
      pollInterval: pollInterval ?? this.pollInterval,
      exactAlarmsEnabled: exactAlarmsEnabled ?? this.exactAlarmsEnabled,
      soundUri: soundUri ?? this.soundUri,
      vibrate: vibrate ?? this.vibrate,
      volumeBoost: volumeBoost ?? this.volumeBoost,
      pauseAllUntil: pauseAllUntil ?? this.pauseAllUntil,
      githubToken: githubToken ?? this.githubToken,
    );
  }
}
