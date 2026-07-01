import 'package:drift/native.dart';
import 'package:farmctl/app.dart';
import 'package:farmctl/features/settings/models/alert_config.dart';
import 'package:farmctl/features/settings/providers/settings_providers.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _defaultConfig = AlertConfig(
  pollInterval: Duration(minutes: 5),
  soundUri: null,
  vibrate: true,
  volumeBoost: false,
  pauseAllUntil: null,
  githubToken: null,
);

Widget buildApp(ThermostatDatabase database) {
  return ProviderScope(
    overrides: [
      thermostatDatabaseProvider.overrideWithValue(database),
      thermostatsProvider.overrideWith((ref) => const Stream.empty()),
      // Plain stream avoids a Drift watch-stream subscription (and its pending
      // dispose timer) for the new pause banner on the thermostats page.
      alertConfigProvider.overrideWith((ref) => Stream.value(_defaultConfig)),
    ],
    child: const FarmCtlApp(),
  );
}

void main() {
  testWidgets('FarmCtl renders bottom navigation', (tester) async {
    final database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    await tester.pumpWidget(buildApp(database));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Thermostats'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });

  testWidgets('provides light and dark themes following the system', (
    tester,
  ) async {
    final database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    await tester.pumpWidget(buildApp(database));
    await tester.pump();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.system);
    expect(app.theme?.brightness, Brightness.light);
    expect(app.darkTheme, isNotNull);
    expect(app.darkTheme?.brightness, Brightness.dark);
  });
}
