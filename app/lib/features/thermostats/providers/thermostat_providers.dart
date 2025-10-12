import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/thermostat_database.dart';
import '../data/thermostat_repository.dart';
import '../models/thermostat.dart';

final thermostatDatabaseProvider = Provider<ThermostatDatabase>((ref) {
  final database = ThermostatDatabase();
  ref.onDispose(database.close);
  return database;
});

final thermostatRepositoryProvider = Provider<ThermostatRepository>((ref) {
  final database = ref.watch(thermostatDatabaseProvider);
  return ThermostatRepository(database);
});

final thermostatsProvider = StreamProvider<List<Thermostat>>((ref) {
  final repository = ref.watch(thermostatRepositoryProvider);
  return repository.watchThermostats();
});
