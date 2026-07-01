import 'package:flutter/material.dart';

import '../../../core/format/relative_time.dart';
import 'thermostat_state.dart';

/// Severity buckets that drive distinct, non-color-only visuals so an
/// out-of-range temperature (a real alarm) is never confused with a transient
/// connectivity problem.
enum ThermostatStatusSeverity {
  /// Neutral / awaiting first reading — no judgement yet.
  neutral,

  /// Reading is good and within the configured range.
  ok,

  /// Something needs attention but the temperature itself isn't the problem
  /// (server/parse/unknown errors).
  warning,

  /// We couldn't reach the sensor; the shown value is last-known-good.
  offline,

  /// The temperature is out of the safe range — the headline alarm condition.
  danger,
}

/// A self-describing presentation for a thermostat's current status: a short
/// label word, a distinct icon, a severity, and a longer detail sentence.
/// Each severity maps to its own icon + color so status survives grayscale and
/// color-blind viewing.
class ThermostatStatusPresentation {
  const ThermostatStatusPresentation({
    required this.label,
    required this.detail,
    required this.icon,
    required this.severity,
  });

  /// Short status word for a pill/badge, e.g. "In range", "Out of range".
  final String label;

  /// Longer human sentence with context (value, last-checked time).
  final String detail;

  final IconData icon;
  final ThermostatStatusSeverity severity;

  /// True when the *temperature itself* is the problem (drives the loud red
  /// hero styling). Connectivity issues are deliberately excluded.
  bool get isDanger => severity == ThermostatStatusSeverity.danger;

  /// True for any non-ok, non-neutral state (drives the warning/alert glyph).
  bool get isProblem =>
      severity == ThermostatStatusSeverity.danger ||
      severity == ThermostatStatusSeverity.warning ||
      severity == ThermostatStatusSeverity.offline;

  /// Foreground color for this severity, sourced from the theme so dark mode
  /// stays correct.
  Color color(ColorScheme scheme) {
    switch (severity) {
      case ThermostatStatusSeverity.neutral:
        return scheme.onSurfaceVariant;
      case ThermostatStatusSeverity.ok:
        return scheme.primary;
      case ThermostatStatusSeverity.warning:
        return scheme.tertiary;
      case ThermostatStatusSeverity.offline:
        return scheme.onSurfaceVariant;
      case ThermostatStatusSeverity.danger:
        return scheme.error;
    }
  }

  static ThermostatStatusPresentation fromState(
    ThermostatState? state, {
    DateTime? now,
  }) {
    if (state == null || state.lastFetchedAt == null) {
      return const ThermostatStatusPresentation(
        label: 'Awaiting',
        detail: 'No successful readings yet.',
        icon: Icons.hourglass_empty,
        severity: ThermostatStatusSeverity.neutral,
      );
    }

    final fetchedAt = state.lastFetchedAt!;
    final value = state.lastValueC;
    final message = state.statusMessage;
    final reference = now ?? DateTime.now().toUtc();
    final relative = formatRelativeDuration(reference.difference(fetchedAt));

    switch (state.status) {
      case ThermostatReadingStatus.ok:
        final base = value != null
            ? '${value.toStringAsFixed(2)}°C • Updated $relative'
            : 'Updated $relative';
        final detail = message != null && message.isNotEmpty
            ? '$message • Updated $relative'
            : base;
        return ThermostatStatusPresentation(
          label: 'In range',
          detail: detail,
          icon: Icons.check_circle,
          severity: ThermostatStatusSeverity.ok,
        );
      case ThermostatReadingStatus.outOfRange:
        final base = (message != null && message.isNotEmpty)
            ? message
            : 'Temperature outside configured range';
        final detail = value != null
            ? '$base (${value.toStringAsFixed(2)}°C) • Updated $relative'
            : '$base • Updated $relative';
        return ThermostatStatusPresentation(
          label: 'Out of range',
          detail: detail,
          icon: Icons.warning_amber_rounded,
          severity: ThermostatStatusSeverity.danger,
        );
      case ThermostatReadingStatus.stale:
        // Data age (when the sensor last pushed), not fetch age — the fetches
        // keep succeeding while the sensor is silent, so `Updated $relative`
        // would misleadingly stay fresh.
        final dataUpdatedAt = state.dataUpdatedAt;
        final dataRelative = dataUpdatedAt != null
            ? formatRelativeDuration(reference.difference(dataUpdatedAt))
            : relative;
        final base = (message != null && message.isNotEmpty)
            ? message
            : 'No new data from the sensor';
        final detail = value != null
            ? '$base • Last value ${value.toStringAsFixed(2)}°C • '
                  'Data $dataRelative'
            : '$base • Data $dataRelative';
        return ThermostatStatusPresentation(
          label: 'Stale data',
          detail: detail,
          icon: Icons.sensors_off,
          severity: ThermostatStatusSeverity.warning,
        );
      case ThermostatReadingStatus.networkError:
        final base = (message != null && message.isNotEmpty)
            ? message
            : 'Last attempt failed: network error';
        return ThermostatStatusPresentation(
          label: 'Offline',
          detail: '$base • Checked $relative',
          icon: Icons.cloud_off,
          severity: ThermostatStatusSeverity.offline,
        );
      case ThermostatReadingStatus.httpError:
        final base = (message != null && message.isNotEmpty)
            ? message
            : 'Last attempt failed: server error';
        return ThermostatStatusPresentation(
          label: 'Server error',
          detail: '$base • Checked $relative',
          icon: Icons.error_outline,
          severity: ThermostatStatusSeverity.warning,
        );
      case ThermostatReadingStatus.parseError:
        final base = (message != null && message.isNotEmpty)
            ? message
            : 'Last attempt failed: invalid payload';
        return ThermostatStatusPresentation(
          label: 'Bad data',
          detail: '$base • Checked $relative',
          icon: Icons.error_outline,
          severity: ThermostatStatusSeverity.warning,
        );
      case ThermostatReadingStatus.unknown:
        final detail = (message != null && message.isNotEmpty)
            ? '$message • Checked $relative'
            : 'Last seen $relative';
        return ThermostatStatusPresentation(
          label: 'Unknown',
          detail: detail,
          icon: Icons.help_outline,
          severity: ThermostatStatusSeverity.warning,
        );
    }
  }
}
