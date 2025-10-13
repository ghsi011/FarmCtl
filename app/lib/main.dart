import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/background/thermostat_monitor.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await initializeBackgroundMonitoring();
  } catch (error, stackTrace) {
    debugPrint('Failed to initialize background monitoring: $error');
    debugPrint('$stackTrace');
  }
  runApp(const ProviderScope(child: FarmCtlApp()));
}
