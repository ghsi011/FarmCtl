import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/settings/data/alert_config_repository.dart';
import 'package:farmctl/features/settings/data/secure_token_store.dart';
import 'package:farmctl/features/settings/providers/settings_providers.dart';
import 'package:farmctl/features/thermostats/data/thermostat_client.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';
import 'package:farmctl/features/thermostats/view/thermostats_page.dart';
import 'package:farmctl/features/thermostats/widgets/thermostat_card.dart';

/// Avoids the real flutter_secure_storage platform channel, which never
/// resolves under `flutter test` and would hang the save flow.
class _NoopTokenStore implements SecureTokenStore {
  @override
  Future<String?> readToken() async => null;

  @override
  Future<void> writeToken(String? token) async {}
}

class _FakeNetwork implements ThermostatNetworkDataSource {
  @override
  Future<ThermostatFetchSuccess> fetchCurrent(String url) async {
    return ThermostatFetchSuccess(
      valueC: 15,
      fetchedAt: DateTime.utc(2025, 1, 1, 12),
      etag: 'e',
    );
  }

  @override
  Future<List<ThermostatHistorySample>> fetchHistory(String gistId) async =>
      const [];

  @override
  Future<List<GistCommit>> listCommits(
    String gistId, {
    int page = 1,
    int perPage = 100,
  }) async => const [];

  @override
  Future<double?> fetchRevisionValue(String gistId, String revisionId) async =>
      null;

  @override
  Future<String> testToken() async => 'OK';
}

ThermostatSummary _summary(String id, String name) {
  final timestamp = DateTime.utc(2025, 1, 1, 12);
  return ThermostatSummary(
    thermostat: Thermostat(
      id: id,
      name: name,
      rawUrl: 'a' * 32,
      minC: 0,
      maxC: 20,
      hysteresisEnabled: false,
      monitoringEnabled: true,
      createdAt: timestamp,
      updatedAt: timestamp,
    ),
    state: ThermostatState(
      thermostatId: id,
      status: ThermostatReadingStatus.ok,
      lastValueC: 15.0,
      lastFetchedAt: timestamp,
      createdAt: timestamp,
      updatedAt: timestamp,
    ),
  );
}

/// Pumps the page with a *static* thermostats stream (so the UI settles
/// deterministically) while the repository/service run against a real
/// in-memory database — letting us assert the side effects of the handlers.
Future<ThermostatDatabase> _pumpPage(
  WidgetTester tester, {
  required List<ThermostatSummary> rendered,
}) async {
  final db = ThermostatDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);

  tester.view.physicalSize = const Size(420, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        thermostatDatabaseProvider.overrideWithValue(db),
        thermostatNetworkProvider.overrideWithValue(_FakeNetwork()),
        alertConfigRepositoryProvider.overrideWith(
          (ref) => AlertConfigRepository(
            ref.watch(thermostatDatabaseProvider),
            tokenStore: _NoopTokenStore(),
          ),
        ),
        thermostatsProvider.overrideWith((ref) => Stream.value(rendered)),
        offlineStatusProvider.overrideWithValue(OfflineStatus.online),
      ],
      child: const MaterialApp(home: ThermostatsPage()),
    ),
  );
  await tester.pumpAndSettle();
  return db;
}

void main() {
  testWidgets('adds a thermostat via the form dialog', (tester) async {
    final db = await _pumpPage(tester, rendered: const []);
    expect(find.byType(ThermostatCard), findsNothing);

    await tester.tap(find.text('Add thermostat'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'Greenhouse');
    await tester.enterText(find.byType(TextFormField).at(1), 'a' * 32);
    await tester.enterText(find.byType(TextFormField).at(2), '0');
    await tester.enterText(find.byType(TextFormField).at(3), '20');
    await tester.tap(find.text('Test & Save'));
    await tester.pumpAndSettle();

    expect(find.text('Thermostat added.'), findsOneWidget);
    expect(await db.listThermostats(), hasLength(1));
  });

  testWidgets('deletes a thermostat after confirmation', (tester) async {
    final db = await _pumpPage(
      tester,
      rendered: [_summary('t1', 'Greenhouse')],
    );
    await db.upsertThermostat(
      ThermostatEntriesCompanion.insert(
        id: 't1',
        name: 'Greenhouse',
        rawUrl: 'a' * 32,
        minC: 0.0,
        maxC: 20.0,
      ),
    );
    expect(find.byType(ThermostatCard), findsOneWidget);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete thermostat'));
    await tester.pumpAndSettle();

    expect(find.text('Delete "Greenhouse"?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Thermostat deleted.'), findsOneWidget);
    expect(await db.getThermostat('t1'), isNull);
  });

  testWidgets('edits a thermostat via the form dialog', (tester) async {
    final db = await _pumpPage(
      tester,
      rendered: [_summary('t1', 'Greenhouse')],
    );
    await db.upsertThermostat(
      ThermostatEntriesCompanion.insert(
        id: 't1',
        name: 'Greenhouse',
        rawUrl: 'a' * 32,
        minC: 0.0,
        maxC: 20.0,
      ),
    );

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit details'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'Polytunnel');
    await tester.tap(find.text('Test & Save'));
    await tester.pumpAndSettle();

    expect(find.text('Thermostat updated.'), findsOneWidget);
    expect((await db.getThermostat('t1'))?.name, 'Polytunnel');
  });

  testWidgets('refreshes a thermostat and reports the reading', (tester) async {
    final db = await _pumpPage(
      tester,
      rendered: [_summary('t1', 'Greenhouse')],
    );
    await db.upsertThermostat(
      ThermostatEntriesCompanion.insert(
        id: 't1',
        name: 'Greenhouse',
        rawUrl: 'a' * 32,
        minC: 0.0,
        maxC: 20.0,
      ),
    );

    await tester.tap(find.byTooltip('Refresh thermostat'));
    await tester.pumpAndSettle();

    // Fake reading (15°C) is in range, so the snackbar reports the value.
    expect(find.textContaining('Greenhouse:'), findsOneWidget);
  });

  testWidgets('cancelling the delete dialog keeps the thermostat', (
    tester,
  ) async {
    final db = await _pumpPage(
      tester,
      rendered: [_summary('t1', 'Greenhouse')],
    );
    await db.upsertThermostat(
      ThermostatEntriesCompanion.insert(
        id: 't1',
        name: 'Greenhouse',
        rawUrl: 'a' * 32,
        minC: 0.0,
        maxC: 20.0,
      ),
    );

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete thermostat'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(await db.getThermostat('t1'), isNotNull);
  });
}
