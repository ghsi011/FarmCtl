import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/settings/models/alert_config.dart';
import 'package:farmctl/features/settings/providers/settings_providers.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/widgets/thermostat_card.dart';

const AlertConfig _defaultConfig = AlertConfig(
  pollInterval: Duration(minutes: 5),
  soundUri: null,
  vibrate: true,
  volumeBoost: false,
  pauseAllUntil: null,
  githubToken: null,
);

ThermostatSummary _summary({
  ThermostatReadingStatus? status,
  double? value,
  String? message,
  DateTime? fetchedAt,
  DateTime? dataUpdatedAt,
}) {
  final timestamp = DateTime.utc(2025, 1, 1, 12);
  return ThermostatSummary(
    thermostat: Thermostat(
      id: 'thermostat-1',
      name: 'Greenhouse',
      rawUrl: 'a' * 32,
      minC: 10,
      maxC: 20,
      hysteresisEnabled: false,
      monitoringEnabled: true,
      createdAt: timestamp,
      updatedAt: timestamp,
    ),
    state: status == null
        ? null
        : ThermostatState(
            thermostatId: 'thermostat-1',
            status: status,
            lastValueC: value,
            lastFetchedAt: fetchedAt,
            dataUpdatedAt: dataUpdatedAt,
            statusMessage: message,
            createdAt: timestamp,
            updatedAt: timestamp,
          ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  ThermostatSummary summary, {
  VoidCallback? onTap,
  VoidCallback? onEdit,
  VoidCallback? onDelete,
  VoidCallback? onRefresh,
  AlertConfig config = _defaultConfig,
}) {
  return tester.pumpWidget(
    ProviderScope(
      // Keyed by config: a ProviderScope's overrides are fixed for its
      // element's lifetime, so re-pumping with a different config must create
      // a fresh scope rather than silently keeping the old override.
      key: ValueKey(config),
      overrides: [
        // Plain value stream so the card's stale-threshold lookup never touches
        // the real database-backed provider chain.
        alertConfigProvider.overrideWith((ref) => Stream.value(config)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ThermostatCard(
              summary: summary,
              onTap: onTap,
              onEdit: onEdit,
              onDelete: onDelete,
              onRefresh: onRefresh,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final recent = DateTime.now().toUtc().subtract(const Duration(minutes: 5));

  testWidgets('renders an OK reading with temperature and range', (
    tester,
  ) async {
    await _pump(
      tester,
      _summary(
        status: ThermostatReadingStatus.ok,
        value: 15.0,
        fetchedAt: recent,
      ),
    );

    expect(find.text('Greenhouse'), findsOneWidget);
    expect(find.text('15.0°C'), findsOneWidget);
    expect(find.text('Current temperature'), findsOneWidget);
    expect(find.text('10.0°C – 20.0°C'), findsOneWidget); // target-range chip
    expect(find.text('Target range'), findsOneWidget);
    expect(find.text('Identifier'), findsOneWidget);
    // OK -> non-error icon.
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.warning_rounded), findsNothing);
  });

  testWidgets('renders a placeholder before the first reading', (tester) async {
    await _pump(tester, _summary()); // no state

    expect(find.text('--°C'), findsOneWidget);
    expect(find.text('Awaiting first reading'), findsOneWidget);
    expect(find.textContaining('No successful readings'), findsOneWidget);
    // Neutral, non-alarm status glyph while awaiting data.
    expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('shows the alert treatment when out of range', (tester) async {
    await _pump(
      tester,
      _summary(
        status: ThermostatReadingStatus.outOfRange,
        value: 25.0,
        message: 'Out of range: 25.00°C (10.00°C – 20.00°C)',
        fetchedAt: recent,
      ),
    );

    // Out-of-range is the loud danger state with its own filled warning glyph.
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.textContaining('Out of range'), findsWidgets);
  });

  testWidgets('each status renders a distinct, non-ok glyph', (tester) async {
    const expectedIcon = <ThermostatReadingStatus, IconData>{
      ThermostatReadingStatus.networkError: Icons.cloud_off,
      ThermostatReadingStatus.httpError: Icons.error_outline,
      ThermostatReadingStatus.parseError: Icons.error_outline,
      ThermostatReadingStatus.unknown: Icons.help_outline,
    };
    for (final entry in expectedIcon.entries) {
      await _pump(
        tester,
        _summary(status: entry.key, value: 12.0, fetchedAt: recent),
      );
      expect(
        find.byIcon(entry.value),
        findsOneWidget,
        reason: '${entry.key} should show ${entry.value}',
      );
      // A connectivity/server problem must NOT look like a healthy reading.
      expect(find.byIcon(Icons.check_circle), findsNothing);
    }
  });

  testWidgets('flags stale data even when the fetch time is fresh', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    // The gist keeps being fetched successfully (fresh lastFetchedAt) but its
    // content hasn't changed for 2 hours: the badge must key on data age.
    await _pump(
      tester,
      _summary(
        status: ThermostatReadingStatus.stale,
        value: 15.0,
        fetchedAt: now.subtract(const Duration(minutes: 1)),
        dataUpdatedAt: now.subtract(const Duration(hours: 2)),
      ),
    );
    await tester.pump();

    expect(find.text('Last update (stale)'), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
    // The shown age is the data age, not the fresh fetch age.
    expect(find.text('2 hours ago'), findsOneWidget);
    // Stale gets its own non-ok status glyph.
    expect(find.byIcon(Icons.sensors_off), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('does not flag fresh data as stale', (tester) async {
    final now = DateTime.now().toUtc();
    await _pump(
      tester,
      _summary(
        status: ThermostatReadingStatus.ok,
        value: 15.0,
        fetchedAt: now.subtract(const Duration(minutes: 1)),
        dataUpdatedAt: now.subtract(const Duration(minutes: 5)),
      ),
    );
    await tester.pump();

    expect(find.text('Last update'), findsOneWidget);
    expect(find.text('Last update (stale)'), findsNothing);
  });

  testWidgets('stale threshold scales with the configured poll interval', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    // 20 minutes of data age: stale at the default 5-min poll interval
    // (threshold 15 min) but fresh at a 30-min interval (threshold 90 min).
    final summary = _summary(
      status: ThermostatReadingStatus.ok,
      value: 15.0,
      fetchedAt: now.subtract(const Duration(minutes: 1)),
      dataUpdatedAt: now.subtract(const Duration(minutes: 20)),
    );

    await _pump(tester, summary);
    await tester.pump();
    expect(find.text('Last update (stale)'), findsOneWidget);

    await _pump(
      tester,
      summary,
      config: _defaultConfig.copyWith(
        pollInterval: const Duration(minutes: 30),
      ),
    );
    await tester.pump();
    expect(find.text('Last update (stale)'), findsNothing);
    expect(find.text('Last update'), findsOneWidget);
  });

  testWidgets('legacy rows without a data timestamp fall back to fetch age', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    await _pump(
      tester,
      _summary(
        status: ThermostatReadingStatus.ok,
        value: 15.0,
        fetchedAt: now.subtract(const Duration(hours: 1)),
      ),
    );
    await tester.pump();

    expect(find.text('Last update (stale)'), findsOneWidget);
  });

  testWidgets('exposes an accessible semantics label and value', (
    tester,
  ) async {
    await _pump(
      tester,
      _summary(
        status: ThermostatReadingStatus.ok,
        value: 15.0,
        fetchedAt: recent,
      ),
      onTap: () {},
    );

    final semantics = tester.getSemantics(find.byType(ThermostatCard));
    expect(semantics.label, contains('Thermostat Greenhouse'));
    expect(semantics.value, contains('degrees Celsius'));
  });

  testWidgets('invokes the action callbacks', (tester) async {
    var tapped = 0;
    var edited = 0;
    var deleted = 0;
    var refreshed = 0;

    await _pump(
      tester,
      _summary(
        status: ThermostatReadingStatus.ok,
        value: 15.0,
        fetchedAt: recent,
      ),
      onTap: () => tapped++,
      onEdit: () => edited++,
      onDelete: () => deleted++,
      onRefresh: () => refreshed++,
    );

    await tester.tap(find.text('Greenhouse'));
    expect(tapped, 1);

    await tester.tap(find.byTooltip('Refresh thermostat'));
    expect(refreshed, 1);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit details'));
    await tester.pumpAndSettle();
    expect(edited, 1);

    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete thermostat'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
  });
}
