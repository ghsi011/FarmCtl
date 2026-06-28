import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/data/thermostat_client.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/widgets/thermostat_form_dialog.dart';

Thermostat _dummy() {
  final timestamp = DateTime.utc(2025, 1, 1);
  return Thermostat(
    id: 'thermostat-1',
    name: 'Barn',
    rawUrl: 'a' * 32,
    minC: 0,
    maxC: 20,
    hysteresisEnabled: false,
    monitoringEnabled: true,
    createdAt: timestamp,
    updatedAt: timestamp,
  );
}

Future<void> _openDialog(
  WidgetTester tester, {
  required Future<Thermostat> Function(ThermostatDraft draft) onSubmit,
  Thermostat? initial,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showDialog<Thermostat>(
                context: context,
                builder: (_) =>
                    ThermostatFormDialog(onSubmit: onSubmit, initial: initial),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _fillValid(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).at(0), 'Barn');
  await tester.enterText(find.byType(TextFormField).at(1), 'a' * 32);
  await tester.enterText(find.byType(TextFormField).at(2), '0');
  await tester.enterText(find.byType(TextFormField).at(3), '20');
}

void main() {
  testWidgets('validates required name and gist id on empty submit', (
    tester,
  ) async {
    var called = false;
    await _openDialog(
      tester,
      onSubmit: (_) async {
        called = true;
        return _dummy();
      },
    );

    await tester.tap(find.text('Test & Save'));
    await tester.pump();

    expect(find.text('Enter a name.'), findsOneWidget);
    expect(find.text('Enter a Gist ID.'), findsOneWidget);
    expect(called, isFalse);
  });

  testWidgets('flags non-numeric min/max', (tester) async {
    await _openDialog(tester, onSubmit: (_) async => _dummy());
    await tester.enterText(find.byType(TextFormField).at(0), 'Barn');
    await tester.enterText(find.byType(TextFormField).at(1), 'a' * 32);
    await tester.enterText(find.byType(TextFormField).at(2), 'abc');
    await tester.enterText(find.byType(TextFormField).at(3), 'xyz');

    await tester.tap(find.text('Test & Save'));
    await tester.pump();

    expect(find.text('Enter a number.'), findsNWidgets(2));
  });

  testWidgets('flags an inverted range (min >= max)', (tester) async {
    await _openDialog(tester, onSubmit: (_) async => _dummy());
    await tester.enterText(find.byType(TextFormField).at(0), 'Barn');
    await tester.enterText(find.byType(TextFormField).at(1), 'a' * 32);
    await tester.enterText(find.byType(TextFormField).at(2), '20');
    await tester.enterText(find.byType(TextFormField).at(3), '10');

    await tester.tap(find.text('Test & Save'));
    await tester.pump();

    expect(find.text('Minimum must be less than maximum.'), findsOneWidget);
  });

  testWidgets('rejects an invalid gist id', (tester) async {
    await _openDialog(tester, onSubmit: (_) async => _dummy());
    await tester.enterText(find.byType(TextFormField).at(0), 'Barn');
    await tester.enterText(find.byType(TextFormField).at(1), 'not-a-gist-id');
    await tester.enterText(find.byType(TextFormField).at(2), '0');
    await tester.enterText(find.byType(TextFormField).at(3), '20');

    await tester.tap(find.text('Test & Save'));
    await tester.pump();

    expect(find.text('Enter a valid GitHub Gist ID.'), findsOneWidget);
  });

  testWidgets('submits a valid draft and closes', (tester) async {
    ThermostatDraft? captured;
    await _openDialog(
      tester,
      onSubmit: (draft) async {
        captured = draft;
        return _dummy();
      },
    );
    await _fillValid(tester);

    await tester.tap(find.text('Test & Save'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.name, 'Barn');
    expect(captured!.rawUrl, 'a' * 32);
    expect(captured!.minC, 0);
    expect(captured!.maxC, 20);
    // Dialog closed on success.
    expect(find.text('Test & Save'), findsNothing);
  });

  testWidgets('surfaces a fetch error from onSubmit and stays open', (
    tester,
  ) async {
    await _openDialog(
      tester,
      onSubmit: (_) async => throw const ThermostatFetchException(
        status: ThermostatReadingStatus.networkError,
        message: 'Could not reach the Gist API.',
      ),
    );
    await _fillValid(tester);

    await tester.tap(find.text('Test & Save'));
    await tester.pumpAndSettle();

    expect(find.text('Could not reach the Gist API.'), findsOneWidget);
    expect(find.text('Test & Save'), findsOneWidget); // still open
  });

  testWidgets('pre-fills the fields when editing', (tester) async {
    await _openDialog(
      tester,
      onSubmit: (_) async => _dummy(),
      initial: _dummy(),
    );

    expect(find.text('Edit thermostat'), findsOneWidget);
    expect(find.text('Barn'), findsOneWidget);
    expect(find.text('0.00'), findsOneWidget);
    expect(find.text('20.00'), findsOneWidget);
  });
}
