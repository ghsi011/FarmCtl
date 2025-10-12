import 'package:drift/native.dart';
import 'package:farmctl/app.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('FarmCtl renders bottom navigation', (tester) async {
    final database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          thermostatDatabaseProvider.overrideWithValue(database),
          thermostatsProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: const FarmCtlApp(),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Thermostats'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });
}
