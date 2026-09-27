import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';

import 'package:farmctl/features/settings/models/alert_config.dart';
import 'package:farmctl/features/settings/providers/settings_providers.dart';
import 'package:farmctl/features/thermostats/models/history_range.dart';
import 'package:farmctl/features/thermostats/models/device_diagnostics.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/data/thermostat_repository.dart';
import 'package:farmctl/features/thermostats/data/device_diagnostics_client.dart';
import 'package:farmctl/features/thermostats/models/temperature_sample.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';
import 'package:farmctl/features/thermostats/view/thermostat_detail_page.dart';
import 'package:farmctl/features/thermostats/widgets/thermostat_card.dart';
import 'package:farmctl/features/thermostats/widgets/thermostat_history_chart.dart';

const _id = 'thermostat-1';

const AlertConfig _defaultConfig = AlertConfig(
  pollInterval: Duration(minutes: 5),
  soundUri: null,
  vibrate: true,
  volumeBoost: false,
  pauseAllUntil: null,
  githubToken: null,
);

ThermostatSummary _summary() {
  final timestamp = DateTime.utc(2025, 1, 1, 12);
  return ThermostatSummary(
    thermostat: Thermostat(
      id: _id,
      name: 'Greenhouse',
      rawUrl: 'a' * 32,
      diagnosticsGistId: 'b' * 32,
      deviceRef: 'greenhouse-sensor-1',
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

ThermostatSummary _legacySummary() {
  final summary = _summary();
  return ThermostatSummary(
    thermostat: Thermostat(
      id: summary.thermostat.id,
      name: summary.thermostat.name,
      rawUrl: summary.thermostat.rawUrl,
      minC: summary.thermostat.minC,
      maxC: summary.thermostat.maxC,
      hysteresisEnabled: summary.thermostat.hysteresisEnabled,
      monitoringEnabled: summary.thermostat.monitoringEnabled,
      createdAt: summary.thermostat.createdAt,
      updatedAt: summary.thermostat.updatedAt,
    ),
    state: summary.state,
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
  Future<DeviceDiagnosticsSnapshot?> Function()? diagnostics,
  DateTime Function()? clock,
  ThermostatRepository? repository,
  Object? diagnosticsError,
  AlertConfig config = _defaultConfig,
  List<DeviceEvent> events = const [],
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
        deviceEventsProvider(
          'greenhouse-sensor-1',
        ).overrideWith((ref) => Stream.value(events)),
        if (repository != null)
          thermostatRepositoryProvider.overrideWith((ref) => repository),
        thermostatHistoryProvider((
          thermostatId: _id,
          range: ThermostatHistoryRange.day,
        )).overrideWith((ref) => history ?? Stream.value(_samples())),
        thermostatHistoryRefreshProvider((
          thermostatId: _id,
          prioritizeLastHour: true,
        )).overrideWith((ref) async {}),
        if (diagnosticsError != null)
          deviceDiagnosticsProvider(_id).overrideWithValue(
            AsyncValue<DeviceDiagnosticsSnapshot?>.error(
              diagnosticsError,
              StackTrace.current,
            ),
          )
        else
          deviceDiagnosticsProvider(_id).overrideWith(
            (ref) async => diagnostics == null ? null : diagnostics(),
          ),
        nowProvider.overrideWith(
          (ref) => clock ?? () => DateTime.utc(2025, 1, 1, 12),
        ),
        // The card reads the poll interval for its stale-data threshold; keep
        // it off the real database-backed provider chain in tests.
        alertConfigProvider.overrideWith((ref) => Stream.value(config)),
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
    expect(find.textContaining('No stored events yet'), findsOneWidget);
    expect(find.byType(ThermostatHistoryChart), findsOneWidget);
    // The range selector exposes its labels.
    expect(find.text('24H'), findsOneWidget);
    expect(find.text('All'), findsOneWidget);
  });

  testWidgets('shows the legacy diagnostics state without affecting history', (
    tester,
  ) async {
    await _pump(tester, summary: _legacySummary());

    expect(find.text('Device diagnostics'), findsOneWidget);
    expect(find.text('Diagnostics not configured'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('15.0°C'), findsOneWidget);
    expect(find.text('Link device report'), findsOneWidget);
    expect(
      find.textContaining('Link a device report to collect activity'),
      findsOneWidget,
    );
  });

  testWidgets(
    'shows local events and repeated count without changing temperature history',
    (tester) async {
      final before = _samples();
      final event = DeviceEvent(
        deviceRef: 'greenhouse-sensor-1',
        eventId: 'event-1',
        thermostatId: _id,
        code: 'sensor_failed',
        count: 3,
        occurredAt: DateTime.utc(2025, 1, 1, 11, 30),
        uptimeSeconds: 120,
        gistUpdatedAt: null,
        fetchedAt: DateTime.utc(2025, 1, 1, 12),
      );
      await _pump(tester, summary: _summary(), events: [event]);
      expect(find.text('Recent device activity'), findsOneWidget);
      expect(find.text('Temperature sensor could not be read'), findsOneWidget);
      expect(find.text('Repeated 3 times'), findsOneWidget);
      expect(find.textContaining('Occurred 2025-01-01 at'), findsOneWidget);
      expect(
        _samples().map((sample) => sample.valueC),
        before.map((sample) => sample.valueC),
      );
    },
  );

  testWidgets('does not invent an occurrence time for an undated event', (
    tester,
  ) async {
    final event = DeviceEvent(
      deviceRef: 'greenhouse-sensor-1',
      eventId: 'event-2',
      thermostatId: _id,
      code: 'sensor_recovered',
      count: 1,
      occurredAt: null,
      uptimeSeconds: null,
      gistUpdatedAt: DateTime.utc(2025, 1, 1, 11),
      fetchedAt: DateTime.utc(2025, 1, 1, 12),
    );
    await _pump(tester, summary: _summary(), events: [event]);
    expect(find.text('Temperature sensor recovered'), findsOneWidget);
    expect(find.text('Occurrence time not recorded'), findsOneWidget);
    expect(find.textContaining('2025-'), findsNothing);
  });

  testWidgets('shows device-reported status, firmware and publish age', (
    tester,
  ) async {
    await _pump(
      tester,
      summary: _summary(),
      diagnostics: () async => DeviceDiagnosticsSnapshot(
        deviceRef: 'greenhouse-sensor-1',
        firmwareRunning: '1.0.0',
        sensorState: 'fault',
        consecutiveFailures: 3,
        heartbeatSeq: 41,
        gistUpdatedAt: DateTime.utc(2025, 1, 1, 11, 55),
        fetchedAt: DateTime.utc(2025, 1, 1, 12),
      ),
    );

    expect(find.textContaining('Sensor report: fault.'), findsOneWidget);
    expect(find.text('1.0.0'), findsOneWidget);
    expect(find.text('Running'), findsNothing);
    expect(find.text('3'), findsOneWidget);
    expect(find.textContaining('5 mins ago'), findsOneWidget);
    expect(find.text('15.0°C'), findsOneWidget);
  });

  testWidgets(
    'keeps sensor status separate when publish freshness is unknown',
    (tester) async {
      await _pump(
        tester,
        summary: _summary(),
        diagnostics: () async => DeviceDiagnosticsSnapshot(
          deviceRef: 'greenhouse-sensor-1',
          firmwareRunning: '1.0.0',
          sensorState: 'healthy',
          consecutiveFailures: 0,
          heartbeatSeq: 42,
          gistUpdatedAt: null,
          fetchedAt: DateTime.utc(2025, 1, 1, 12),
        ),
      );
      expect(find.text('Publish freshness unknown'), findsOneWidget);
      expect(find.textContaining('Sensor report: healthy.'), findsOneWidget);
      expect(find.textContaining('fetched'), findsNothing);
    },
  );

  testWidgets('saves the diagnostics association from the link dialog', (
    tester,
  ) async {
    final database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database
        .into(database.thermostatEntries)
        .insert(
          ThermostatEntriesCompanion(
            id: const drift.Value(_id),
            name: const drift.Value('Greenhouse'),
            rawUrl: drift.Value('a' * 32),
            minC: const drift.Value(10),
            maxC: const drift.Value(20),
            createdAt: drift.Value(DateTime.utc(2025, 1, 1)),
            updatedAt: drift.Value(DateTime.utc(2025, 1, 1)),
          ),
        );
    final repository = ThermostatRepository(database);
    await _pump(tester, summary: _legacySummary(), repository: repository);

    await tester.tap(find.text('Link device report'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'c' * 32);
    await tester.enterText(find.byType(TextFormField).at(1), 'sensor-west-2');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final persisted = await repository.findById(_id);
    expect(persisted?.diagnosticsGistId, 'c' * 32);
    expect(persisted?.deviceRef, 'sensor-west-2');
  });

  testWidgets('refetches diagnostics after changing the associated Gist', (
    tester,
  ) async {
    final database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database
        .into(database.thermostatEntries)
        .insert(
          ThermostatEntriesCompanion(
            id: const drift.Value(_id),
            name: const drift.Value('Greenhouse'),
            rawUrl: drift.Value('a' * 32),
            diagnosticsGistId: drift.Value('b' * 32),
            deviceRef: const drift.Value('greenhouse-sensor-1'),
            minC: const drift.Value(10),
            maxC: const drift.Value(20),
            createdAt: drift.Value(DateTime.utc(2025, 1, 1)),
            updatedAt: drift.Value(DateTime.utc(2025, 1, 1)),
          ),
        );
    final repository = ThermostatRepository(database);
    var fetchCount = 0;
    await _pump(
      tester,
      summary: _summary(),
      repository: repository,
      diagnostics: () async {
        fetchCount++;
        return DeviceDiagnosticsSnapshot(
          deviceRef: 'greenhouse-sensor-1',
          firmwareRunning: '1.0.0',
          sensorState: fetchCount == 1 ? 'fault' : 'ok',
          consecutiveFailures: 0,
          heartbeatSeq: fetchCount,
          gistUpdatedAt: DateTime.utc(2025, 1, 1, 12),
          fetchedAt: DateTime.utc(2025, 1, 1, 12),
        );
      },
    );
    expect(fetchCount, 1);
    expect(find.textContaining('Sensor report: fault.'), findsOneWidget);

    await tester.tap(find.text('Edit device link'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'c' * 32);
    await tester.enterText(find.byType(TextFormField).at(1), 'sensor-west-2');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect((await repository.findById(_id))?.diagnosticsGistId, 'c' * 32);
    expect(fetchCount, 2);
    expect(find.textContaining('Sensor report: ok.'), findsOneWidget);
  });

  testWidgets('uses safe typed copy for a device reference mismatch', (
    tester,
  ) async {
    await _pump(
      tester,
      summary: _summary(),
      diagnosticsError: const DeviceDiagnosticsException(
        'do not show this response detail',
        kind: DeviceDiagnosticsErrorKind.deviceReferenceMismatch,
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Device reference mismatch'), findsOneWidget);
    expect(find.textContaining('do not show'), findsNothing);
  });

  testWidgets('uses safe typed copy for unsupported schema', (tester) async {
    await _pump(
      tester,
      summary: _summary(),
      diagnosticsError: const DeviceDiagnosticsException(
        'do not show this response detail',
        kind: DeviceDiagnosticsErrorKind.unsupportedSchema,
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Report format not supported'), findsOneWidget);
    expect(find.textContaining('do not show'), findsNothing);
  });

  testWidgets('publish age becomes stale while the detail page stays open', (
    tester,
  ) async {
    var now = DateTime.utc(2025, 1, 1, 12);
    await _pump(
      tester,
      summary: _summary(),
      clock: () => now,
      diagnostics: () async => DeviceDiagnosticsSnapshot(
        deviceRef: 'greenhouse-sensor-1',
        firmwareRunning: '1.0.0',
        sensorState: 'healthy',
        consecutiveFailures: 0,
        heartbeatSeq: 42,
        gistUpdatedAt: DateTime.utc(2025, 1, 1, 11, 45),
        fetchedAt: now,
      ),
    );
    expect(find.text('Report is out of date'), findsNothing);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('Report is out of date'), findsOneWidget);
  });

  testWidgets('uses three configured polling intervals for diagnostics age', (
    tester,
  ) async {
    var now = DateTime.utc(2025, 1, 1, 12);
    await _pump(
      tester,
      summary: _summary(),
      clock: () => now,
      config: _defaultConfig.copyWith(
        pollInterval: const Duration(minutes: 10),
      ),
      diagnostics: () async => DeviceDiagnosticsSnapshot(
        deviceRef: 'greenhouse-sensor-1',
        firmwareRunning: '1.0.0',
        sensorState: 'healthy',
        consecutiveFailures: 0,
        heartbeatSeq: 42,
        gistUpdatedAt: DateTime.utc(2025, 1, 1, 11, 40),
        fetchedAt: now,
      ),
    );
    expect(find.text('Report is out of date'), findsNothing);
    now = now.add(const Duration(minutes: 11));
    await tester.pump(const Duration(minutes: 11));
    expect(find.text('Report is out of date'), findsOneWidget);
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
          deviceDiagnosticsProvider(_id).overrideWith((ref) async => null),
          deviceEventsProvider.overrideWith(
            (ref, deviceRef) => Stream.value(const []),
          ),
          nowProvider.overrideWith(
            (ref) =>
                () => DateTime.utc(2025, 1, 1, 12),
          ),
          alertConfigProvider.overrideWith(
            (ref) => Stream.value(_defaultConfig),
          ),
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
