import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';

import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/models/history_range.dart';
import 'package:farmctl/features/thermostats/models/temperature_sample.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';
import 'package:farmctl/features/thermostats/view/thermostat_history_fullscreen_page.dart';
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
  ThermostatHistoryRange range = ThermostatHistoryRange.day,
}) async {
  // Landscape surface so the in-app-bar range dropdown branch is exercised.
  tester.view.physicalSize = const Size(900, 480);
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
          range: range,
        )).overrideWith((ref) => Stream.value(_samples())),
        thermostatHistoryRefreshProvider((
          thermostatId: _id,
          prioritizeLastHour: true,
        )).overrideWith((ref) async {}),
      ],
      child: MaterialApp(
        home: ThermostatHistoryFullscreenPage(
          thermostatId: _id,
          initialRange: range,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'real fullscreen history rolls while open and is fresh after navigation',
    (tester) async {
      final db = ThermostatDatabase.forTesting(NativeDatabase.memory());
      final initialNow = DateTime.utc(2025, 1, 1, 12);
      var now = initialNow;
      await tester.runAsync(() async {
        await db.upsertThermostat(
          ThermostatEntriesCompanion.insert(
            id: _id,
            name: 'Greenhouse',
            rawUrl: 'a' * 32,
            minC: 10,
            maxC: 20,
          ),
        );
        await db.insertTemperatureReadings([
          TemperatureReadingsCompanion.insert(
            id: 'edge',
            thermostatId: _id,
            source: 'revision',
            valueC: 15,
            observedAt: initialNow.subtract(const Duration(minutes: 59)),
          ),
        ]);
      });
      final container = ProviderContainer(
        overrides: [
          thermostatDatabaseProvider.overrideWithValue(db),
          nowProvider.overrideWithValue(() => now),
          thermostatHistoryRefreshProvider((
            thermostatId: _id,
            prioritizeLastHour: true,
          )).overrideWith((ref) async {}),
        ],
      );
      final provider = thermostatHistoryProvider((
        thermostatId: _id,
        range: ThermostatHistoryRange.hour,
      ));
      final navigator = GlobalKey<NavigatorState>();
      Future<void> open() async {
        await tester.tap(find.text('Open history'));
        await tester.pumpAndSettle();
        await tester.runAsync(() => container.read(provider.future));
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              navigatorKey: navigator,
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ThermostatHistoryFullscreenPage(
                            thermostatId: _id,
                            initialRange: ThermostatHistoryRange.hour,
                          ),
                        ),
                      );
                    },
                    child: const Text('Open history'),
                  ),
                ),
              ),
            ),
          ),
        );
        await open();
        expect(
          tester
              .widget<ThermostatHistoryChart>(
                find.byType(ThermostatHistoryChart),
              )
              .samples
              .single
              .valueC,
          15,
        );
        now = initialNow.add(const Duration(minutes: 2));
        await tester.pump(const Duration(minutes: 2));
        await tester.pump();
        await tester.runAsync(() => container.read(provider.future));
        await tester.pumpAndSettle();
        expect(
          find.text('No history available for this range yet.'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Close full-screen chart'));
        await tester.pumpAndSettle();
        expect(find.text('Open history'), findsOneWidget);
        now = initialNow.add(const Duration(hours: 2));
        await tester.pump(const Duration(hours: 2));
        await open();
        expect(
          find.text('No history available for this range yet.'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<ThermostatHistoryChart>(
                find.byType(ThermostatHistoryChart),
              )
              .samples,
          isEmpty,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          container.dispose();
          await db.close();
        });
      }
    },
  );

  testWidgets('renders the chart with the named title and close button', (
    tester,
  ) async {
    await _pump(tester, summary: _summary());

    expect(find.text('Greenhouse history'), findsOneWidget);
    expect(find.byType(ThermostatHistoryChart), findsOneWidget);
    expect(find.byTooltip('Close full-screen chart'), findsOneWidget);
  });

  testWidgets('falls back to a generic title when the name is unknown', (
    tester,
  ) async {
    await _pump(tester, summary: null);

    expect(find.text('Thermostat history'), findsOneWidget);
    expect(find.byType(ThermostatHistoryChart), findsOneWidget);
  });

  testWidgets('exposes the range dropdown in landscape', (tester) async {
    await _pump(tester, summary: _summary());

    expect(
      find.byWidgetPredicate(
        (widget) => widget is DropdownButton<ThermostatHistoryRange>,
      ),
      findsOneWidget,
    );
  });
}
