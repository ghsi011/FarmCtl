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
}
