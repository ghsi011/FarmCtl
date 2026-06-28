import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/models/thermostat_status_presentation.dart';

void main() {
  final now = DateTime.utc(2025, 1, 1, 12);

  ThermostatState state(ThermostatReadingStatus status, {double? value}) {
    return ThermostatState(
      thermostatId: 't1',
      status: status,
      lastValueC: value,
      lastFetchedAt: now.subtract(const Duration(minutes: 5)),
      createdAt: now,
      updatedAt: now,
    );
  }

  ThermostatStatusPresentation present(ThermostatReadingStatus status) =>
      ThermostatStatusPresentation.fromState(
        state(status, value: 12),
        now: now,
      );

  test('awaiting state is neutral, not an alarm', () {
    final p = ThermostatStatusPresentation.fromState(null, now: now);
    expect(p.severity, ThermostatStatusSeverity.neutral);
    expect(p.label, 'Awaiting');
    expect(p.icon, Icons.hourglass_empty);
    expect(p.isDanger, isFalse);
    expect(p.isProblem, isFalse);
  });

  test('ok reading is in range and not a problem', () {
    final p = present(ThermostatReadingStatus.ok);
    expect(p.severity, ThermostatStatusSeverity.ok);
    expect(p.label, 'In range');
    expect(p.icon, Icons.check_circle);
    expect(p.isDanger, isFalse);
    expect(p.isProblem, isFalse);
  });

  test('out of range is the only danger state', () {
    final p = present(ThermostatReadingStatus.outOfRange);
    expect(p.severity, ThermostatStatusSeverity.danger);
    expect(p.label, 'Out of range');
    expect(p.icon, Icons.warning_amber_rounded);
    expect(p.isDanger, isTrue);
  });

  test('network error is offline, not danger', () {
    final p = present(ThermostatReadingStatus.networkError);
    expect(p.severity, ThermostatStatusSeverity.offline);
    expect(p.label, 'Offline');
    expect(p.icon, Icons.cloud_off);
    expect(
      p.isDanger,
      isFalse,
      reason: 'a wifi blip is not a temperature alarm',
    );
    expect(p.isProblem, isTrue);
  });

  test('http/parse/unknown are warnings with distinct labels', () {
    expect(present(ThermostatReadingStatus.httpError).label, 'Server error');
    expect(present(ThermostatReadingStatus.parseError).label, 'Bad data');
    expect(present(ThermostatReadingStatus.unknown).label, 'Unknown');
    for (final s in const [
      ThermostatReadingStatus.httpError,
      ThermostatReadingStatus.parseError,
      ThermostatReadingStatus.unknown,
    ]) {
      expect(present(s).severity, ThermostatStatusSeverity.warning);
      expect(present(s).isDanger, isFalse);
    }
  });

  test('color distinguishes danger from offline', () {
    const scheme = ColorScheme.light();
    expect(
      present(ThermostatReadingStatus.outOfRange).color(scheme),
      scheme.error,
    );
    expect(
      present(ThermostatReadingStatus.networkError).color(scheme),
      scheme.onSurfaceVariant,
    );
    expect(present(ThermostatReadingStatus.ok).color(scheme), scheme.primary);
  });
}
