import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/thermostat_client.dart';
import '../data/thermostat_database.dart';
import '../data/thermostat_repository.dart';
import '../data/thermostat_service.dart';
import '../models/thermostat_state.dart';

final thermostatDatabaseProvider = Provider<ThermostatDatabase>((ref) {
  final database = ThermostatDatabase();
  ref.onDispose(database.close);
  return database;
});

final thermostatRepositoryProvider = Provider<ThermostatRepository>((ref) {
  final database = ref.watch(thermostatDatabaseProvider);
  return ThermostatRepository(database);
});

final thermostatNetworkProvider = Provider<ThermostatNetworkDataSource>((ref) {
  return ThermostatHttpClient();
});

final thermostatServiceProvider = Provider<ThermostatService>((ref) {
  final repository = ref.watch(thermostatRepositoryProvider);
  final network = ref.watch(thermostatNetworkProvider);
  return ThermostatService(repository: repository, network: network);
});

final thermostatsProvider = StreamProvider<List<ThermostatSummary>>((ref) {
  final repository = ref.watch(thermostatRepositoryProvider);
  return repository.watchThermostats();
});
