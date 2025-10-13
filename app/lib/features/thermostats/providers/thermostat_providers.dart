import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/thermostat_client.dart';
import '../data/thermostat_database.dart';
import '../data/thermostat_repository.dart';
import '../data/thermostat_service.dart';
import '../models/history_range.dart';
import '../models/temperature_sample.dart';
import '../models/thermostat_state.dart';
import '../utils/thermostat_history_downsampler.dart';

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

final thermostatSummaryProvider =
    StreamProvider.family<ThermostatSummary?, String>((ref, thermostatId) {
      final repository = ref.watch(thermostatRepositoryProvider);
      return repository.watchThermostat(thermostatId);
    });

final thermostatHistoryProvider =
    StreamProvider.family<
      List<TemperatureSample>,
      ({String thermostatId, ThermostatHistoryRange range})
    >((ref, args) {
      final repository = ref.watch(thermostatRepositoryProvider);
      final window = args.range.window;
      final since = window != null
          ? DateTime.now().toUtc().subtract(window)
          : null;
      return repository.watchHistory(args.thermostatId, since: since).map((
        samples,
      ) {
        final filtered = since == null
            ? samples
            : samples
                  .where((sample) => !sample.observedAt.isBefore(since))
                  .toList();
        return ThermostatHistoryDownsampler.downsample(filtered, args.range);
      });
    });

final thermostatHistoryRefreshProvider = FutureProvider.autoDispose
    .family<void, String>((ref, thermostatId) async {
      final service = ref.watch(thermostatServiceProvider);
      await service.refreshHistory(thermostatId);
    });
