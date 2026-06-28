import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/settings/models/alert_config.dart';
import 'package:farmctl/features/settings/providers/settings_providers.dart';
import 'package:farmctl/features/settings/view/settings_page.dart';

AlertConfig _config({
  Duration interval = const Duration(minutes: 5),
  bool exact = false,
  String? sound,
  DateTime? pauseUntil,
  String? token,
}) {
  return AlertConfig(
    pollInterval: interval,
    exactAlarmsEnabled: exact,
    soundUri: sound,
    vibrate: true,
    volumeBoost: false,
    pauseAllUntil: pauseUntil,
    githubToken: token,
  );
}

Future<void> _pumpData(WidgetTester tester, AlertConfig config) async {
  // Very tall surface so the whole lazy ListView builds (all sections render).
  tester.view.physicalSize = const Size(500, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        alertConfigProvider.overrideWith((ref) => Stream.value(config)),
      ],
      child: const MaterialApp(home: SettingsPage()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the monitoring, alarm and API sections', (tester) async {
    await _pumpData(tester, _config());

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Poll interval'), findsOneWidget);
    expect(find.text('Allow exact alarms'), findsOneWidget);
    expect(find.text('Pause monitoring'), findsOneWidget);
    expect(find.text('Resume monitoring'), findsOneWidget);
    expect(find.text('Alarm sound'), findsOneWidget);
    expect(find.text('Vibrate on alarm'), findsOneWidget);
    expect(find.text('Boost volume'), findsOneWidget);
    expect(find.text('Test alarm'), findsOneWidget);
    expect(find.text('API configuration'), findsOneWidget);

    // With no active pause window, Resume is disabled.
    final resume = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Resume monitoring'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(resume.onPressed, isNull);
  });

  testWidgets('reflects the poll interval and an enabled exact-alarm switch', (
    tester,
  ) async {
    await _pumpData(
      tester,
      _config(interval: const Duration(minutes: 12), exact: true),
    );

    expect(find.text('12 minutes'), findsOneWidget);
    final exactSwitch = tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('Allow exact alarms'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(exactSwitch.value, isTrue);
  });

  testWidgets('enables Resume only while a pause window is active', (
    tester,
  ) async {
    await _pumpData(
      tester,
      _config(pauseUntil: DateTime.now().toUtc().add(const Duration(hours: 1))),
    );

    final resume = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Resume monitoring'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(resume.onPressed, isNotNull);
  });

  testWidgets('shows a configured custom alarm sound', (tester) async {
    await _pumpData(tester, _config(sound: 'content://media/42'));
    expect(find.text('content://media/42'), findsOneWidget);
  });

  testWidgets('shows an error state when the config fails to load', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          alertConfigProvider.overrideWith(
            (ref) => Stream<AlertConfig>.error(Exception('boom')),
          ),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Failed to load settings'), findsOneWidget);
    expect(find.text('Poll interval'), findsNothing);
  });
}
