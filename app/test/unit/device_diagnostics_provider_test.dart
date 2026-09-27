import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/data/thermostat_repository.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';

void main() {
  test(
    'unassociated thermostat yields null without requesting diagnostics',
    () async {
      final database = ThermostatDatabase.forTesting(NativeDatabase.memory());
      final repository = ThermostatRepository(database);
      final thermostat = await repository.create(
        ThermostatDraft(
          name: 'Legacy',
          rawUrl: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          minC: 0,
          maxC: 20,
        ),
      );
      final container = ProviderContainer(
        overrides: [thermostatDatabaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);
      addTearDown(database.close);

      expect(
        await container.read(deviceDiagnosticsProvider(thermostat.id).future),
        isNull,
      );
    },
  );
}
