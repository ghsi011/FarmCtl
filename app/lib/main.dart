import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/background/thermostat_monitor.dart';
import 'core/permissions/notification_permission.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await initializeBackgroundMonitoring();
  } catch (error, stackTrace) {
    debugPrint('Failed to initialize background monitoring: $error');
    debugPrint('$stackTrace');
  }
  runApp(const ProviderScope(child: FarmCtlApp()));

  // If the app was cold-launched by tapping an alarm notification, route to the
  // alarm screen once the router is ready.
  await handleNotificationLaunch();

  // Prompt for notification permission over the now-visible app (the activity
  // is attached post-runApp). Without POST_NOTIFICATIONS the ongoing monitoring
  // notification and — critically — every alarm notification are suppressed;
  // once granted, the ongoing notification reappears on the next monitor tick.
  await ensureNotificationPermission();
}
