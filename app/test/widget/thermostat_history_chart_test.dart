import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/models/history_range.dart';
import 'package:farmctl/features/thermostats/models/temperature_sample.dart';
import 'package:farmctl/features/thermostats/widgets/thermostat_history_chart.dart';

List<TemperatureSample> _samples(
  int count, {
  Duration step = const Duration(minutes: 10),
}) {
  final base = DateTime.utc(2025, 1, 1, 12);
  return [
    for (var i = 0; i < count; i++)
      TemperatureSample(
        id: 's$i',
        thermostatId: 't1',
        valueC: 10.0 + i,
        observedAt: base.add(step * i),
        source: 'revision',
        sourceId: 'rev-$i',
      ),
  ];
}

Future<void> _pump(
  WidgetTester tester,
  List<TemperatureSample> samples,
  ThermostatHistoryRange range, {
  bool expand = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: ThermostatHistoryChart(
            samples: samples,
            range: range,
            expand: expand,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows an empty message when there is no history', (
    tester,
  ) async {
    await _pump(tester, const [], ThermostatHistoryRange.day);
    expect(
      find.text('No history available for this range yet.'),
      findsOneWidget,
    );
    expect(find.byType(LineChart), findsNothing);
  });

  testWidgets('renders a line chart with accessible summary', (tester) async {
    await _pump(tester, _samples(6), ThermostatHistoryRange.day);

    expect(find.byType(LineChart), findsOneWidget);
    final semantics = tester.getSemantics(find.byType(ThermostatHistoryChart));
    expect(semantics.label, contains('Temperature history'));
    expect(semantics.value, contains('degrees Celsius'));
  });

  testWidgets('handles a single sample (degenerate x-axis)', (tester) async {
    await _pump(tester, _samples(1), ThermostatHistoryRange.hour);
    expect(find.byType(LineChart), findsOneWidget);
  });

  testWidgets('handles a flat series (zero value span)', (tester) async {
    final base = DateTime.utc(2025, 1, 1, 12);
    final flat = [
      for (var i = 0; i < 4; i++)
        TemperatureSample(
          id: 'f$i',
          thermostatId: 't1',
          valueC: 18.0,
          observedAt: base.add(Duration(minutes: 10 * i)),
          source: 'revision',
        ),
    ];
    await _pump(tester, flat, ThermostatHistoryRange.day);
    expect(find.byType(LineChart), findsOneWidget);
  });

  testWidgets('renders for every range (axis formatters)', (tester) async {
    for (final range in ThermostatHistoryRange.values) {
      await _pump(tester, _samples(8, step: const Duration(hours: 6)), range);
      expect(find.byType(LineChart), findsOneWidget);
    }
  });

  testWidgets('expands to fill when requested', (tester) async {
    await _pump(tester, _samples(4), ThermostatHistoryRange.week, expand: true);
    expect(find.byType(LineChart), findsOneWidget);
  });

  testWidgets('handles a very wide time span (axis interval fallback)', (
    tester,
  ) async {
    // Months apart -> span exceeds the largest preset interval, exercising the
    // computed-interval fallback.
    await _pump(
      tester,
      _samples(6, step: const Duration(days: 30)),
      ThermostatHistoryRange.all,
    );
    expect(find.byType(LineChart), findsOneWidget);
  });
}
