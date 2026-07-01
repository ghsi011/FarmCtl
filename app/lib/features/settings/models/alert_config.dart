import 'package:flutter/foundation.dart';

import '../../thermostats/data/thermostat_database.dart';

@immutable
class AlertConfig {
  const AlertConfig({
    required this.pollInterval,
    required this.soundUri,
    required this.vibrate,
    required this.volumeBoost,
    required this.pauseAllUntil,
    required this.githubToken,
    this.lastMonitorRunAt,
  });

  final Duration pollInterval;
  final String? soundUri;
  final bool vibrate;
  final bool volumeBoost;
  final DateTime? pauseAllUntil;
  final String? githubToken;

  /// When the background monitor last started a run. Used to debounce the
  /// overlapping foreground-service + WorkManager-watchdog triggers into a
  /// single run.
  final DateTime? lastMonitorRunAt;

  factory AlertConfig.fromEntry(AlertConfigEntry entry) {
    return AlertConfig(
      pollInterval: Duration(minutes: entry.pollIntervalMin),
      soundUri: entry.soundUri,
      vibrate: entry.vibrate,
      volumeBoost: entry.volumeBoost,
      pauseAllUntil: entry.pauseAllUntil?.toUtc(),
      githubToken: entry.githubToken,
      lastMonitorRunAt: entry.lastMonitorRunAt?.toUtc(),
    );
  }

  /// Returns a copy with [githubToken] set to exactly [token] (including null).
  /// Used to overlay the token resolved from secure storage onto the config
  /// loaded from the database; `copyWith` cannot set a nullable field to null.
  AlertConfig withToken(String? token) {
    return AlertConfig(
      pollInterval: pollInterval,
      soundUri: soundUri,
      vibrate: vibrate,
      volumeBoost: volumeBoost,
      pauseAllUntil: pauseAllUntil,
      githubToken: token,
      lastMonitorRunAt: lastMonitorRunAt,
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
    String? soundUri,
    bool? vibrate,
    bool? volumeBoost,
    DateTime? pauseAllUntil,
    String? githubToken,
    DateTime? lastMonitorRunAt,
  }) {
    return AlertConfig(
      pollInterval: pollInterval ?? this.pollInterval,
      soundUri: soundUri ?? this.soundUri,
      vibrate: vibrate ?? this.vibrate,
      volumeBoost: volumeBoost ?? this.volumeBoost,
      pauseAllUntil: pauseAllUntil ?? this.pauseAllUntil,
      githubToken: githubToken ?? this.githubToken,
      lastMonitorRunAt: lastMonitorRunAt ?? this.lastMonitorRunAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlertConfig &&
          other.pollInterval == pollInterval &&
          other.soundUri == soundUri &&
          other.vibrate == vibrate &&
          other.volumeBoost == volumeBoost &&
          other.pauseAllUntil == pauseAllUntil &&
          other.githubToken == githubToken &&
          other.lastMonitorRunAt == lastMonitorRunAt;

  @override
  int get hashCode => Object.hash(
    pollInterval,
    soundUri,
    vibrate,
    volumeBoost,
    pauseAllUntil,
    githubToken,
    lastMonitorRunAt,
  );
}
