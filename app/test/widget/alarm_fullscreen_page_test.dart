import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';
import 'package:farmctl/features/thermostats/view/alarm_fullscreen_page.dart';

void main() {
  const thermostatId = 'thermostat-1';

  ThermostatSummary buildSummary() {
    final timestamp = DateTime.utc(2025, 1, 1, 12);
    return ThermostatSummary(
      thermostat: Thermostat(
        id: thermostatId,
        name: 'Greenhouse',
        rawUrl: 'a' * 32,
        minC: 0,
        maxC: 20,
        hysteresisEnabled: false,
        monitoringEnabled: true,
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
      state: ThermostatState(
        thermostatId: thermostatId,
        status: ThermostatReadingStatus.outOfRange,
        lastValueC: 25.2,
        lastFetchedAt: timestamp,
        statusMessage: 'Out of range',
        createdAt: timestamp,
        updatedAt: timestamp,
      ),
    );
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          thermostatSummaryProvider(
            thermostatId,
          ).overrideWith((ref) => Stream.value(buildSummary())),
        ],
        child: const MaterialApp(
          home: AlarmFullScreenPage(thermostatId: thermostatId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders the alarm content for an out-of-range thermostat', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('Greenhouse'), findsOneWidget);
    expect(find.text('25.20°C'), findsOneWidget);
    expect(find.text('Snooze 5 min'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);
  });

  testWidgets(
    'is guarded by PopScope(canPop: false) so back cancels the alarm',
    (tester) async {
      await pumpPage(tester);

      // Regression guard for H-2: a hardware/predictive back must be intercepted
      // so it routes through cancelAlarmNotification instead of a bare pop.
      expect(
        find.descendant(
          of: find.byType(AlarmFullScreenPage),
          matching: find.byWidgetPredicate(
            (widget) => widget is PopScope && widget.canPop == false,
          ),
        ),
        findsOneWidget,
      );
    },
  );

  Future<void> pumpStream(
    WidgetTester tester,
    Stream<ThermostatSummary?> stream,
  ) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          thermostatSummaryProvider(thermostatId).overrideWith((ref) => stream),
        ],
        child: const MaterialApp(
          home: AlarmFullScreenPage(thermostatId: thermostatId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows a missing-thermostat message when the summary is null', (
    tester,
  ) async {
    await pumpStream(tester, Stream<ThermostatSummary?>.value(null));
    expect(find.text('Thermostat not found.'), findsOneWidget);
  });

  testWidgets('shows an error message when the summary stream fails', (
    tester,
  ) async {
    await pumpStream(
      tester,
      Stream<ThermostatSummary?>.error(Exception('boom')),
    );
    expect(find.textContaining('Failed to load alarm details'), findsOneWidget);
  });

  testWidgets('surfaces snooze and silence status details', (tester) async {
    final base = buildSummary();
    final state = base.state!;
    final snoozed = ThermostatSummary(
      thermostat: base.thermostat,
      state: ThermostatState(
        thermostatId: state.thermostatId,
        status: state.status,
        lastValueC: state.lastValueC,
        lastFetchedAt: state.lastFetchedAt,
        statusMessage: state.statusMessage,
        snoozedUntil: DateTime.utc(2030, 1, 1, 12),
        silenceUntilOk: true,
        createdAt: state.createdAt,
        updatedAt: state.updatedAt,
      ),
    );

    await pumpStream(tester, Stream<ThermostatSummary?>.value(snoozed));

    expect(find.textContaining('Snoozed until'), findsOneWidget);
    expect(
      find.text('Silenced until reading returns to range.'),
      findsOneWidget,
    );
    // The "Silence until OK" action is disabled while already silenced.
    final silenceButton = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Silence until OK'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(silenceButton.onPressed, isNull);
  });
}
