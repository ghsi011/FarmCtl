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

/// Drives a background→foreground cycle, traversing adjacent lifecycle states
/// as AppLifecycleListener requires (it asserts on non-adjacent transitions).
Future<void> _resume(WidgetTester tester) async {
  const sequence = [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ];
  for (final state in sequence) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
  await tester.pumpAndSettle();
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

  testWidgets('refreshes again when the app resumes', (tester) async {
    var calls = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          thermostatsProvider.overrideWith(
            (ref) => Stream.value([_summary('a')]),
          ),
          thermostatBatchRefreshProvider.overrideWithValue((thermostats) async {
            calls += 1;
          }),
        ],
        // Disable the throttle so the resume refresh isn't suppressed by the
        // cold-launch one in the same instant.
        child: const ForegroundRefresher(
          minInterval: Duration.zero,
          child: SizedBox(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    await _resume(tester);
    expect(calls, 2);
  });

  testWidgets('throttles refreshes within minInterval', (tester) async {
    var calls = 0;
    var now = DateTime.utc(2025, 1, 1, 12);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          thermostatsProvider.overrideWith(
            (ref) => Stream.value([_summary('a')]),
          ),
          nowProvider.overrideWithValue(() => now),
          thermostatBatchRefreshProvider.overrideWithValue((thermostats) async {
            calls += 1;
          }),
        ],
        // Default 15s throttle window.
        child: const ForegroundRefresher(child: SizedBox()),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    // Resume within the throttle window — suppressed.
    await _resume(tester);
    expect(calls, 1);

    // Advance past the throttle window — allowed.
    now = now.add(const Duration(seconds: 20));
    await _resume(tester);
    expect(calls, 2);
  });
}
