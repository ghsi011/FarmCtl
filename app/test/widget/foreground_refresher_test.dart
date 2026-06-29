import 'package:farmctl/core/lifecycle/foreground_refresher.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

ThermostatSummary _summary(String id) {
  final now = DateTime.utc(2025, 1, 1);
  return ThermostatSummary(
    thermostat: Thermostat(
      id: id,
      name: 'Thermostat $id',
      rawUrl: 'gist-$id',
      minC: 0,
      maxC: 30,
      hysteresisEnabled: false,
      monitoringEnabled: true,
      createdAt: now,
      updatedAt: now,
    ),
  );
}

void main() {
  testWidgets('refreshes once when the thermostat list first resolves', (
    tester,
  ) async {
    var calls = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          thermostatsProvider.overrideWith(
            (ref) => Stream.value([_summary('a'), _summary('b')]),
          ),
          thermostatBatchRefreshProvider.overrideWithValue((thermostats) async {
            calls += 1;
          }),
        ],
        child: const ForegroundRefresher(child: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, 1);
  });

  testWidgets('does not refresh when there are no thermostats', (tester) async {
    var calls = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          thermostatsProvider.overrideWith(
            (ref) => Stream.value(<ThermostatSummary>[]),
          ),
          thermostatBatchRefreshProvider.overrideWithValue((thermostats) async {
            calls += 1;
          }),
        ],
        child: const ForegroundRefresher(child: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();

    expect(calls, 0);
  });
}
