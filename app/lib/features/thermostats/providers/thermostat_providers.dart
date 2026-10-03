import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:dio/dio.dart';

import '../data/thermostat_client.dart';
import '../data/device_diagnostics_client.dart';
import '../data/thermostat_database.dart';
import '../data/thermostat_repository.dart';
import '../data/thermostat_service.dart';
import '../models/history_range.dart';
import '../models/device_diagnostics.dart';
import '../models/temperature_sample.dart';
import '../models/thermostat.dart';
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

final deviceDiagnosticsProvider = FutureProvider.autoDispose
    .family<DeviceDiagnosticsSnapshot?, String>((ref, thermostatId) async {
      final cancelToken = CancelToken();
      ref.onDispose(() => cancelToken.cancel('Diagnostics view disposed.'));
      final repository = ref.watch(thermostatRepositoryProvider);
      final alertRepository = ref.watch(alertConfigRepositoryProvider);
      final thermostat = await repository.findById(thermostatId);
      final gistId = thermostat?.diagnosticsGistId;
      final deviceRef = thermostat?.deviceRef;
      if (gistId == null ||
          gistId.isEmpty ||
          deviceRef == null ||
          deviceRef.isEmpty) {
        return null;
      }
      final config = await alertRepository.loadConfig();
      final client = GitHubDeviceDiagnosticsClient(
        githubToken: config.githubToken,
      );
      final snapshot = await client.fetch(
        gistId: gistId,
        deviceRef: deviceRef,
        cancelToken: cancelToken,
      );
      await repository.ingestDeviceEvents(
        thermostatId: thermostatId,
        snapshot: snapshot,
      );
      return snapshot;
    });

final _githubTokenProvider = StreamProvider<String?>((ref) {
  // Resolve via the repository so the token comes from secure storage rather
  // than the (now legacy) plaintext database column.
  final repository = ref.watch(alertConfigRepositoryProvider);
  return repository.watchConfig().map((config) => config.githubToken);
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
    pollIntervalSupplier: () async {
      final config = await alertRepo.loadConfig();
      return config.pollInterval;
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

final deviceEventsProvider = StreamProvider.family<List<DeviceEvent>, String>((
  ref,
  deviceRef,
) {
  final repository = ref.watch(thermostatRepositoryProvider);
  return repository.watchDeviceEvents(deviceRef, limit: 20);
});

/// The history time-range currently selected for a thermostat. Shared so the
/// detail page and the full-screen chart stay in sync in both directions.
final selectedHistoryRangeProvider =
    StateProvider.family<ThermostatHistoryRange, String>(
      (ref, thermostatId) => ThermostatHistoryRange.day,
    );

/// Limited history windows advance at most one minute after a sample expires.
/// Auto-disposal stops ticking when the last limited-range view closes; All
/// never subscribes to this clock or causes time-driven database queries.
final _historyRefreshTickProvider = StreamProvider.autoDispose<int>((ref) {
  return Stream<int>.periodic(const Duration(minutes: 1), (count) => count);
});

final thermostatHistoryProvider = StreamProvider.autoDispose
    .family<
      List<TemperatureSample>,
      ({String thermostatId, ThermostatHistoryRange range})
    >((ref, args) {
      final repository = ref.watch(thermostatRepositoryProvider);
      final window = args.range.window;
      DateTime Function()? clock;
      if (window != null) {
        ref.watch(_historyRefreshTickProvider);
        clock = ref.watch(nowProvider);
      }
      final since = clock?.call().toUtc().subtract(window!);
      return repository.watchHistory(args.thermostatId, since: since).map((
        samples,
      ) {
        // Also advance the cutoff on writes between ticks, rather than retaining
        // the query's initial cutoff in the in-memory filter.
        final cutoff = clock?.call().toUtc().subtract(window!);
        final filtered = cutoff == null
            ? samples
            : samples
                  .where((sample) => !sample.observedAt.isBefore(cutoff))
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
      final now = ref.read(nowProvider)();
      final last = registry.lastRun[args.thermostatId];
      if (last != null && now.difference(last) < const Duration(seconds: 10)) {
        return;
      }

      final service = ref.watch(thermostatServiceProvider);
      await service.refreshHistory(
        args.thermostatId,
        prioritizeLastHour: args.prioritizeLastHour,
      );
      // Stamp only after a successful refresh so a failed/cancelled one does not
      // throttle the user's immediate retry for the next 10s.
      registry.lastRun[args.thermostatId] = now;
    });

/// Signature for refreshing a single thermostat's current reading.
typedef ThermostatRefreshAction = Future<void> Function(Thermostat thermostat);

/// Re-fetches the current reading for every [thermostats] entry, swallowing
/// per-thermostat failures so one unreachable sensor doesn't abort the batch
/// (each card surfaces its own error status). Shared by pull-to-refresh and the
/// automatic foreground refresh so the two paths stay in lock-step.
Future<void> refreshAllThermostats(
  List<ThermostatSummary> thermostats,
  ThermostatRefreshAction refresh,
) async {
  for (final summary in thermostats) {
    try {
      await refresh(summary.thermostat);
    } catch (_) {
      // Surfaced per-card; keep going so one bad sensor can't abort the sweep.
    }
  }
}

/// Sweeps the current reading for the supplied thermostats via the live
/// [ThermostatService]. Exposed as a provider so foreground callers (the
/// on-resume refresher) get a single overridable seam in tests.
final thermostatBatchRefreshProvider =
    Provider<Future<void> Function(List<ThermostatSummary>)>((ref) {
      final service = ref.watch(thermostatServiceProvider);
      return (thermostats) => refreshAllThermostats(
        thermostats,
        (thermostat) => service.refresh(thermostat),
      );
    });

enum OfflineStatus { online, degraded, offline, unknown }

/// Current UTC time as an injectable function so time-dependent providers stay
/// testable. Override in tests to pin "now" to a fixed instant.
final nowProvider = Provider<DateTime Function()>(
  (ref) =>
      () => DateTime.now().toUtc(),
);

/// Ticks periodically so [offlineStatusProvider] re-evaluates its wall-clock
/// thresholds even when no thermostat rows change (otherwise a device that went
/// offline could keep reporting "online" until the next DB write).
final _offlineRefreshTickProvider = StreamProvider<int>((ref) {
  return Stream<int>.periodic(const Duration(minutes: 1), (count) => count);
});

final offlineStatusProvider = Provider<OfflineStatus>((ref) {
  // Re-run on each tick so stale time thresholds are recomputed.
  ref.watch(_offlineRefreshTickProvider);
  final thermostatsAsync = ref.watch(thermostatsProvider);
  return thermostatsAsync.when(
    data: (thermostats) {
      if (thermostats.isEmpty) {
        return OfflineStatus.online;
      }

      final now = ref.watch(nowProvider)();
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
          // Stale data still means the fetch itself succeeded — the network
          // path is healthy, only the sensor-side uploader is silent.
          case ThermostatReadingStatus.stale:
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
