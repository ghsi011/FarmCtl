import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/models/history_range.dart';
import 'package:farmctl/features/thermostats/models/temperature_sample.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';
import 'package:farmctl/features/thermostats/view/thermostat_detail_page.dart';
import 'package:farmctl/features/thermostats/widgets/thermostat_card.dart';
import 'package:farmctl/features/thermostats/widgets/thermostat_history_chart.dart';

const _id = 'thermostat-1';

ThermostatSummary _summary() {
  final timestamp = DateTime.utc(2025, 1, 1, 12);
  return ThermostatSummary(
    thermostat: Thermostat(
      id: _id,
      name: 'Greenhouse',
      rawUrl: 'a' * 32,
      minC: 10,
      maxC: 20,
      hysteresisEnabled: false,
      monitoringEnabled: true,
      createdAt: timestamp,
      updatedAt: timestamp,
    ),
    state: ThermostatState(
      thermostatId: _id,
      status: ThermostatReadingStatus.ok,
      lastValueC: 15.0,
      lastFetchedAt: timestamp,
      createdAt: timestamp,
      updatedAt: timestamp,
    ),
  );
}

List<TemperatureSample> _samples() {
  final base = DateTime.utc(2025, 1, 1, 12);
  return [
    for (var i = 0; i < 5; i++)
      TemperatureSample(
        id: 's$i',
        thermostatId: _id,
        valueC: 14.0 + i,
        observedAt: base.add(Duration(minutes: 10 * i)),
        source: 'revision',
        sourceId: 'rev-$i',
      ),
  ];
}

Future<void> _pump(
  WidgetTester tester, {
  required ThermostatSummary? summary,
  Stream<List<TemperatureSample>>? history,
}) async {
  tester.view.physicalSize = const Size(420, 2600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        thermostatSummaryProvider(
          _id,
        ).overrideWith((ref) => Stream.value(summary)),
        thermostatHistoryProvider((
          thermostatId: _id,
          range: ThermostatHistoryRange.day,
        )).overrideWith((ref) => history ?? Stream.value(_samples())),
        thermostatHistoryRefreshProvider((
          thermostatId: _id,
          prioritizeLastHour: true,
        )).overrideWith((ref) async {}),
      ],
      child: const MaterialApp(home: ThermostatDetailPage(thermostatId: _id)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the card, history section, chart and range selector', (
    tester,
  ) async {
    await _pump(tester, summary: _summary());

    // App-bar title and the card both show the name.
    expect(find.text('Greenhouse'), findsWidgets);
    expect(find.byType(ThermostatCard), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.byType(ThermostatHistoryChart), findsOneWidget);
    // The range selector exposes its labels.
    expect(find.text('24H'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
  });

  testWidgets('shows a not-found state for a missing thermostat', (
    tester,
  ) async {
    await _pump(tester, summary: null);

    expect(find.text('Thermostat not found'), findsOneWidget);
    expect(find.byType(ThermostatCard), findsNothing);
  });

  testWidgets('shows a history error when the history stream fails', (
    tester,
  ) async {
    await _pump(
      tester,
      summary: _summary(),
      history: Stream<List<TemperatureSample>>.error(Exception('boom')),
    );

    expect(find.text('Unable to load history'), findsOneWidget);
  });

  testWidgets('switches the range and refreshes history', (tester) async {
    tester.view.physicalSize = const Size(420, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var refreshCount = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Override the whole families so any selected range/refresh resolves.
          thermostatSummaryProvider.overrideWith(
            (ref, id) => Stream.value(_summary()),
          ),
          thermostatHistoryProvider.overrideWith(
            (ref, args) => Stream.value(_samples()),
          ),
          thermostatHistoryRefreshProvider.overrideWith((ref, args) async {
            refreshCount++;
          }),
        ],
        child: const MaterialApp(home: ThermostatDetailPage(thermostatId: _id)),
      ),
    );
    await tester.pumpAndSettle();
    expect(refreshCount, 1);

    // Switch from the default range to the 7-day range.
    await tester.tap(find.text('7D'));
    await tester.pumpAndSettle();
    expect(find.byType(ThermostatHistoryChart), findsOneWidget);

    // Trigger the app-bar refresh action; it re-runs the refresh provider.
    await tester.tap(find.byTooltip('Refresh history'));
    await tester.pumpAndSettle();
    expect(refreshCount, greaterThan(1));
  });
}
