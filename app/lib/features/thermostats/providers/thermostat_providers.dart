import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/thermostat_client.dart';
import '../data/thermostat_database.dart';
import '../data/thermostat_repository.dart';
import '../data/thermostat_service.dart';
import '../models/history_range.dart';
import '../models/temperature_sample.dart';
import '../models/thermostat_state.dart';
import '../utils/thermostat_history_downsampler.dart';
import '../../settings/providers/settings_providers.dart';

final thermostatDatabaseProvider = Provider<ThermostatDatabase>((ref) {
  final database = ThermostatDatabase();
  ref.onDispose(database.close);
  return database;
});

final thermostatRepositoryProvider = Provider<ThermostatRepository>((ref) {
  final database = ref.watch(thermostatDatabaseProvider);
  return ThermostatRepository(database);
});

final _githubTokenProvider = StreamProvider<String?>((ref) {
  final database = ref.watch(thermostatDatabaseProvider);
  return database.watchAlertConfig().map((config) => config.githubToken);
});

final thermostatNetworkProvider = Provider<ThermostatNetworkDataSource>((ref) {
  final githubTokenAsync = ref.watch(_githubTokenProvider);
  final githubToken = githubTokenAsync.when(
    data: (token) => token,
    loading: () => null,
    error: (error, stack) => null,
  );
  return ThermostatHttpClient(githubToken: githubToken);
});

final thermostatServiceProvider = Provider<ThermostatService>((ref) {
  final repository = ref.watch(thermostatRepositoryProvider);
  final network = ref.watch(thermostatNetworkProvider);
  final alertRepo = ref.watch(alertConfigRepositoryProvider);
  return ThermostatService(
    repository: repository,
    network: network,
    tokenSupplier: () async {
      final config = await alertRepo.loadConfig();
      return config.githubToken;
    },
  );
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
    .family<void, ({String thermostatId, bool prioritizeLastHour})>((
      ref,
      args,
    ) async {
      // Debounce: wait briefly; if user navigates away quickly, provider disposes
      // and this work is canceled, avoiding redundant requests on quick tab flips.
      const debounce = Duration(milliseconds: 300);
      await Future<void>.delayed(debounce);
      if (!ref.mounted) return;

      // Throttle: avoid repeated heavy refreshes within a short window.
      // This is per-thermostat and survives rapid rebuilds while in view.
      // Note: In-memory only; resets on app restart which is fine.
      _RefreshThrottleRegistry registry = ref.read(
        _refreshThrottleRegistryProvider,
      );
      final now = DateTime.now().toUtc();
      final last = registry.lastRun[args.thermostatId];
      if (last != null && now.difference(last) < const Duration(seconds: 10)) {
        return;
      }
      registry.lastRun[args.thermostatId] = now;

      final service = ref.watch(thermostatServiceProvider);
      await service.refreshHistory(
        args.thermostatId,
        prioritizeLastHour: args.prioritizeLastHour,
      );
    });

enum OfflineStatus { online, degraded, offline, unknown }

final offlineStatusProvider = Provider<OfflineStatus>((ref) {
  final thermostatsAsync = ref.watch(thermostatsProvider);
  return thermostatsAsync.when(
    data: (thermostats) {
      if (thermostats.isEmpty) {
        return OfflineStatus.online;
      }

      final now = DateTime.now().toUtc();
      var recentNetworkFailures = 0;
      var recentSuccess = false;

      for (final summary in thermostats) {
        final state = summary.state;
        if (state == null) {
          continue;
        }

        final lastFetchedAt = state.lastFetchedAt;
        switch (state.status) {
          case ThermostatReadingStatus.ok:
          case ThermostatReadingStatus.outOfRange:
            if (lastFetchedAt != null &&
                now.difference(lastFetchedAt) <= const Duration(minutes: 15)) {
              recentSuccess = true;
            }
            break;
          case ThermostatReadingStatus.networkError:
            if (lastFetchedAt != null &&
                now.difference(lastFetchedAt) <= const Duration(minutes: 30)) {
              recentNetworkFailures += 1;
            }
            break;
          case ThermostatReadingStatus.httpError:
          case ThermostatReadingStatus.parseError:
          case ThermostatReadingStatus.unknown:
            break;
        }
      }

      if (recentNetworkFailures == 0) {
        return OfflineStatus.online;
      }

      return recentSuccess ? OfflineStatus.degraded : OfflineStatus.offline;
    },
    loading: () => OfflineStatus.unknown,
    error: (error, stackTrace) => OfflineStatus.unknown,
  );
});

class _RefreshThrottleRegistry {
  final Map<String, DateTime> lastRun = <String, DateTime>{};
}

final _refreshThrottleRegistryProvider = Provider<_RefreshThrottleRegistry>((
  ref,
) {
  return _RefreshThrottleRegistry();
});
