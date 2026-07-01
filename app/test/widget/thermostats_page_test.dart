import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:farmctl/core/permissions/notification_permission.dart';
import 'package:farmctl/features/settings/models/alert_config.dart';
import 'package:farmctl/features/settings/providers/settings_providers.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';
import 'package:farmctl/features/thermostats/view/thermostats_page.dart';
import 'package:farmctl/features/thermostats/widgets/thermostat_card.dart';

const _defaultConfig = AlertConfig(
  pollInterval: Duration(minutes: 5),
  soundUri: null,
  vibrate: true,
  volumeBoost: false,
  pauseAllUntil: null,
  githubToken: null,
);

ThermostatSummary _summary(String id, String name) {
  final timestamp = DateTime.utc(2025, 1, 1, 12);
  return ThermostatSummary(
    thermostat: Thermostat(
      id: id,
      name: name,
      rawUrl: 'a' * 32,
      minC: 10,
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

Future<void> _pump(
  WidgetTester tester, {
  required Stream<List<ThermostatSummary>> thermostats,
  OfflineStatus offline = OfflineStatus.online,
  AlertConfig config = _defaultConfig,
  // Pinned permission state; pass null to let the real status provider run
  // against [permissionChecker] (exercises the resume-driven refresh).
  AlarmNotificationPermission? permission = AlarmNotificationPermission.granted,
  NotificationPermissionChecker? permissionChecker,
}) async {
  // Narrow, tall surface so the layout uses the single-column scrolling list
  // (the wide multi-column grid constrains card height and overflows in tests).
  tester.view.physicalSize = const Size(420, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        thermostatsProvider.overrideWith((ref) => thermostats),
        // Override so the provider's periodic re-eval timer isn't started.
        offlineStatusProvider.overrideWithValue(offline),
        // Plain stream avoids a Drift watch-stream pending timer for the pause
        // banner.
        alertConfigProvider.overrideWith((ref) => Stream.value(config)),
        if (permissionChecker != null)
          notificationPermissionCheckerProvider.overrideWithValue(
            permissionChecker,
          ),
        if (permission != null)
          notificationPermissionStatusProvider.overrideWith(
            (ref) async => permission,
          ),
      ],
      child: const MaterialApp(home: ThermostatsPage()),
    ),
  );
  await tester.pumpAndSettle();
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
  testWidgets('shows the empty state with an add affordance', (tester) async {
    await _pump(tester, thermostats: Stream.value(const <ThermostatSummary>[]));

    expect(find.text('No thermostats yet'), findsOneWidget);
    // Both the empty-state CTA and the FAB offer "Add thermostat".
    expect(find.text('Add thermostat'), findsWidgets);
    expect(find.byType(ThermostatCard), findsNothing);
  });

  testWidgets('renders a card per thermostat', (tester) async {
    await _pump(
      tester,
      thermostats: Stream.value([
        _summary('t1', 'Greenhouse'),
        _summary('t2', 'Barn'),
      ]),
    );

    expect(find.byType(ThermostatCard), findsNWidgets(2));
    expect(find.text('Greenhouse'), findsOneWidget);
    expect(find.text('Barn'), findsOneWidget);
  });

  testWidgets('shows an error state when the stream errors', (tester) async {
    await _pump(
      tester,
      thermostats: Stream<List<ThermostatSummary>>.error(
        Exception('database down'),
      ),
    );
    await tester.pump();

    expect(find.text('Failed to load thermostats'), findsOneWidget);
  });

  testWidgets('shows the offline banner when offline', (tester) async {
    await _pump(
      tester,
      thermostats: Stream.value([_summary('t1', 'Greenhouse')]),
      offline: OfflineStatus.offline,
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Offline mode'), findsOneWidget);
  });

  testWidgets('shows the degraded banner when connectivity is degraded', (
    tester,
  ) async {
    await _pump(
      tester,
      thermostats: Stream.value([_summary('t1', 'Greenhouse')]),
      offline: OfflineStatus.degraded,
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Connectivity issues'), findsOneWidget);
  });

  testWidgets('hides the banner when online', (tester) async {
    await _pump(
      tester,
      thermostats: Stream.value([_summary('t1', 'Greenhouse')]),
      offline: OfflineStatus.online,
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Offline mode'), findsNothing);
    expect(find.text('Connectivity issues'), findsNothing);
  });

  testWidgets('surfaces a pause banner with a Resume action while paused', (
    tester,
  ) async {
    await _pump(
      tester,
      thermostats: Stream.value([_summary('t1', 'Greenhouse')]),
      config: AlertConfig(
        pollInterval: const Duration(minutes: 5),
        soundUri: null,
        vibrate: true,
        volumeBoost: false,
        pauseAllUntil: DateTime.now().toUtc().add(const Duration(hours: 2)),
        githubToken: null,
      ),
    );

    expect(find.text('Monitoring paused'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Resume'), findsOneWidget);
  });

  testWidgets('hides the pause banner when not paused', (tester) async {
    await _pump(
      tester,
      thermostats: Stream.value([_summary('t1', 'Greenhouse')]),
    );

    expect(find.text('Monitoring paused'), findsNothing);
  });

  testWidgets('shows the alarms-blocked banner when notifications are denied', (
    tester,
  ) async {
    await _pump(
      tester,
      thermostats: Stream.value([_summary('t1', 'Greenhouse')]),
      permission: AlarmNotificationPermission.denied,
    );

    expect(
      find.text('Alarms are blocked — notifications are turned off'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, 'Open settings'), findsOneWidget);
  });

  testWidgets(
    'hides the alarms-blocked banner when notifications are granted',
    (tester) async {
      await _pump(
        tester,
        thermostats: Stream.value([_summary('t1', 'Greenhouse')]),
      );

      expect(
        find.text('Alarms are blocked — notifications are turned off'),
        findsNothing,
      );
      expect(find.text('Open settings'), findsNothing);
    },
  );

  testWidgets('Open settings on the blocked banner opens the OS settings', (
    tester,
  ) async {
    var opened = 0;
    final checker = NotificationPermissionChecker(
      isAndroid: true,
      readStatus: () async => PermissionStatus.permanentlyDenied,
      openSettings: () async {
        opened += 1;
        return true;
      },
    );

    await _pump(
      tester,
      thermostats: Stream.value([_summary('t1', 'Greenhouse')]),
      permission: AlarmNotificationPermission.denied,
      permissionChecker: checker,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Open settings'));
    await tester.pump();

    expect(opened, 1);
  });

  testWidgets(
    'clears the blocked banner when permission is granted while backgrounded',
    (tester) async {
      var osStatus = PermissionStatus.permanentlyDenied;
      final checker = NotificationPermissionChecker(
        isAndroid: true,
        readStatus: () async => osStatus,
        openSettings: () async => true,
      );

      // permission: null → the real status provider runs against the fake
      // checker, including its resume-driven re-read.
      await _pump(
        tester,
        thermostats: Stream.value([_summary('t1', 'Greenhouse')]),
        permission: null,
        permissionChecker: checker,
      );
      expect(
        find.text('Alarms are blocked — notifications are turned off'),
        findsOneWidget,
      );

      // User re-enables notifications in system settings and comes back.
      osStatus = PermissionStatus.granted;
      await _resume(tester);
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text('Alarms are blocked — notifications are turned off'),
        findsNothing,
      );
    },
  );
}
