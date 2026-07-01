import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:farmctl/core/permissions/notification_permission.dart';
import 'package:farmctl/features/settings/models/alert_config.dart';
import 'package:farmctl/features/settings/providers/settings_providers.dart';
import 'package:farmctl/features/settings/view/settings_page.dart';

AlertConfig _config({
  Duration interval = const Duration(minutes: 5),
  String? sound,
  DateTime? pauseUntil,
  String? token,
  DateTime? lastMonitorRunAt,
}) {
  return AlertConfig(
    pollInterval: interval,
    soundUri: sound,
    vibrate: true,
    volumeBoost: false,
    pauseAllUntil: pauseUntil,
    githubToken: token,
    lastMonitorRunAt: lastMonitorRunAt,
  );
}

Future<void> _pumpData(
  WidgetTester tester,
  AlertConfig config, {
  AlarmNotificationPermission permission = AlarmNotificationPermission.granted,
  NotificationPermissionChecker? permissionChecker,
}) async {
  // Very tall surface so the whole lazy ListView builds (all sections render).
  tester.view.physicalSize = const Size(500, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        alertConfigProvider.overrideWith((ref) => Stream.value(config)),
        if (permissionChecker != null)
          notificationPermissionCheckerProvider.overrideWithValue(
            permissionChecker,
          ),
        notificationPermissionStatusProvider.overrideWith(
          (ref) async => permission,
        ),
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
    expect(find.text('Pause monitoring'), findsOneWidget);
    expect(find.text('Resume monitoring'), findsOneWidget);
    expect(find.text('Alarm sound'), findsOneWidget);
    expect(find.text('Vibrate on alarm'), findsOneWidget);
    // The old no-op "Boost volume" switch must stay removed: it persisted a
    // flag nothing read at alarm time.
    expect(find.text('Boost volume'), findsNothing);
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

  testWidgets('reflects the configured poll interval', (tester) async {
    await _pumpData(tester, _config(interval: const Duration(minutes: 12)));

    expect(find.text('12 minutes'), findsOneWidget);
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

  testWidgets('shows the allowed notification tile when granted', (
    tester,
  ) async {
    await _pumpData(tester, _config());

    expect(find.text('Notifications allowed'), findsOneWidget);
    expect(find.text('Notifications are turned off'), findsNothing);
    expect(find.text('Open settings'), findsNothing);
  });

  testWidgets(
    'shows the blocked notification tile with an Open settings action when '
    'denied',
    (tester) async {
      var opened = 0;
      final checker = NotificationPermissionChecker(
        isAndroid: true,
        readStatus: () async => PermissionStatus.permanentlyDenied,
        openSettings: () async {
          opened += 1;
          return true;
        },
      );

      await _pumpData(
        tester,
        _config(),
        permission: AlarmNotificationPermission.denied,
        permissionChecker: checker,
      );

      expect(find.text('Notifications are turned off'), findsOneWidget);
      expect(
        find.text('Alarms are blocked until notifications are allowed.'),
        findsOneWidget,
      );
      expect(find.text('Notifications allowed'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, 'Open settings'));
      await tester.pump();
      expect(opened, 1);
    },
  );

  testWidgets('shows a recent last check as relative time', (tester) async {
    final lastRun = DateTime.now().toUtc().subtract(const Duration(minutes: 2));
    await _pumpData(tester, _config(lastMonitorRunAt: lastRun));

    expect(find.text('Last check'), findsOneWidget);
    expect(find.text('2 mins ago'), findsOneWidget);
    // Recent (within 2x the 5-minute poll interval) → not stale-styled.
    expect(find.byIcon(Icons.warning_amber), findsNothing);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
  });

  testWidgets('stale-styles the last check when older than 2x the interval', (
    tester,
  ) async {
    final lastRun = DateTime.now().toUtc().subtract(
      const Duration(minutes: 30),
    );
    await _pumpData(
      tester,
      _config(interval: const Duration(minutes: 5), lastMonitorRunAt: lastRun),
    );

    expect(find.text('Last check'), findsOneWidget);
    expect(find.text('30 mins ago'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber), findsOneWidget);
    expect(
      find.text('Overdue — checks may be delayed or blocked.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'suppresses the overdue warning during an intentional monitoring pause',
    (tester) async {
      final lastRun = DateTime.now().toUtc().subtract(
        const Duration(minutes: 30),
      );
      await _pumpData(
        tester,
        _config(
          interval: const Duration(minutes: 5),
          lastMonitorRunAt: lastRun,
          pauseUntil: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
      );

      expect(find.text('Last check'), findsOneWidget);
      expect(find.text('30 mins ago'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber), findsNothing);
      expect(
        find.text('Overdue — checks may be delayed or blocked.'),
        findsNothing,
      );
    },
  );

  testWidgets('shows Never when the monitor has not run yet', (tester) async {
    await _pumpData(tester, _config());

    expect(find.text('Last check'), findsOneWidget);
    expect(find.text('Never'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber), findsNothing);
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
