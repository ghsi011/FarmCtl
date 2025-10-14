import 'dart:io' show Platform;
import '../models/temperature_sample.dart';
import '../models/thermostat.dart';
import '../models/thermostat_state.dart';
import 'thermostat_client.dart';
import 'thermostat_reading_utils.dart';
import 'thermostat_repository.dart';

class ThermostatService {
  ThermostatService({
    required ThermostatRepository repository,
    required ThermostatNetworkDataSource network,
    Future<String?> Function()? tokenSupplier,
  }) : _repository = repository,
       _network = network,
       _tokenSupplier = tokenSupplier;

  final ThermostatRepository _repository;
  final ThermostatNetworkDataSource _network;
  final Future<String?> Function()? _tokenSupplier;

  Future<Thermostat> createAndTest(
    ThermostatDraft draft, {
    String? tokenOverride,
  }) async {
    final validation = ThermostatValidator.validate(draft);
    if (!validation.isValid) {
      throw ThermostatValidationException(validation);
    }

    final network = tokenOverride != null && tokenOverride.isNotEmpty
        ? ThermostatHttpClient(
            githubToken: tokenOverride,
            allowAnonFallback: false,
          )
        : _network;
    final result = await network.fetchCurrent(draft.rawUrl.trim());
    final saved = await _repository.create(draft);
    await _repository.saveState(
      thermostatId: saved.id,
      status: ThermostatReadingStatus.ok,
      valueC: result.valueC,
      fetchedAt: result.fetchedAt,
      etag: result.etag,
      message: 'Fetched ${result.valueC.toStringAsFixed(2)}°C',
    );
    return saved;
  }

  Future<Thermostat> updateAndTest(
    Thermostat existing,
    ThermostatDraft draft, {
    String? tokenOverride,
  }) async {
    final validation = ThermostatValidator.validate(draft);
    if (!validation.isValid) {
      throw ThermostatValidationException(validation);
    }

    final network = tokenOverride != null && tokenOverride.isNotEmpty
        ? ThermostatHttpClient(
            githubToken: tokenOverride,
            allowAnonFallback: false,
          )
        : _network;
    final result = await network.fetchCurrent(draft.rawUrl.trim());
    final updated = await _repository.update(existing, draft);
    await _repository.saveState(
      thermostatId: updated.id,
      status: ThermostatReadingStatus.ok,
      valueC: result.valueC,
      fetchedAt: result.fetchedAt,
      etag: result.etag,
      message: 'Fetched ${result.valueC.toStringAsFixed(2)}°C',
    );
    return updated;
  }

  Future<ThermostatRefreshResult> refresh(Thermostat thermostat) async {
    final previousState = await _repository.loadState(thermostat.id);
    try {
      final client = await _resolveNetworkWithToken();
      final result = await client.fetchCurrent(thermostat.rawUrl.trim());
      final value = result.valueC;
      final fetchedAt = result.fetchedAt;
      final outOfRange = isThermostatReadingOutOfRange(
        thermostat: thermostat,
        currentValue: value,
        previousState: previousState,
      );
      if (outOfRange) {
        final message = formatOutOfRangeThermostatMessage(thermostat, value);
        await _repository.saveState(
          thermostatId: thermostat.id,
          status: ThermostatReadingStatus.outOfRange,
          valueC: value,
          fetchedAt: fetchedAt,
          etag: result.etag,
          message: message,
        );
        return ThermostatRefreshResult(
          status: ThermostatReadingStatus.outOfRange,
          message: message,
          valueC: value,
          fetchedAt: fetchedAt,
        );
      }

      final message = 'Fetched ${value.toStringAsFixed(2)}°C';
      final shouldClearSnooze = previousState?.snoozedUntil != null;
      final hadSilence = previousState?.silenceUntilOk == true;
      await _repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.ok,
        valueC: value,
        fetchedAt: fetchedAt,
        etag: result.etag,
        message: message,
        setSnoozedUntil: shouldClearSnooze,
        snoozedUntil: null,
        setSilenceUntilOk: hadSilence,
        silenceUntilOk: false,
      );
      return ThermostatRefreshResult(
        status: ThermostatReadingStatus.ok,
        message: message,
        valueC: value,
        fetchedAt: fetchedAt,
      );
    } on ThermostatFetchException catch (error) {
      final now = DateTime.now().toUtc();
      await _repository.saveState(
        thermostatId: thermostat.id,
        status: error.status,
        valueC: previousState?.lastValueC,
        fetchedAt: now,
        etag: previousState?.etag,
        message: error.message,
      );
      return ThermostatRefreshResult(
        status: error.status,
        message: error.message,
        valueC: previousState?.lastValueC,
        fetchedAt: now,
      );
    } catch (error) {
      final now = DateTime.now().toUtc();
      final message = 'Unexpected error: $error';
      await _repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.unknown,
        valueC: previousState?.lastValueC,
        fetchedAt: now,
        etag: previousState?.etag,
        message: message,
      );
      return ThermostatRefreshResult(
        status: ThermostatReadingStatus.unknown,
        message: message,
        valueC: previousState?.lastValueC,
        fetchedAt: now,
      );
    }
  }

  Future<void> refreshHistory(
    String thermostatId, {
    bool prioritizeLastHour = false,
  }) async {
    final thermostat = await _repository.findById(thermostatId);
    if (thermostat == null) {
      throw StateError('Thermostat not found for id $thermostatId');
    }

    final gistId = thermostat.rawUrl.trim();
    final now = DateTime.now().toUtc();
    final twentyFourHoursAgo = now.subtract(const Duration(hours: 24));
    final sevenDaysAgo = now.subtract(const Duration(days: 7));
    final oneYearAgo = now.subtract(const Duration(days: 365));

    final newestLocal = await _repository.getNewestReadingTime(thermostatId);
    final oldestLocal = await _repository.getOldestReadingTime(thermostatId);
    final knownRevisionIds = await _repository.listKnownRevisionIds(
      thermostatId,
    );

    bool hasToken;
    if (_network is ThermostatHttpClient) {
      hasToken = (_network).hasGithubToken;
    } else {
      hasToken =
          (Platform.environment['FARMCTL_GITHUB_TOKEN'] ??
              Platform.environment['GITHUB_TOKEN']) !=
          null;
    }
    // Increase budget when token present; be more aggressive for the last 24h
    final perRunBudget = hasToken ? 400 : 20;
    final interRequestDelay = hasToken
        ? Duration.zero
        : const Duration(milliseconds: 300);

    // Stage selection buckets
    final focusInterval = const Duration(minutes: 5); // last 1h: 1 per 5m
    final stage1Interval = const Duration(minutes: 60); // last 24h: 1 per 60m
    final stage2Interval = const Duration(minutes: 300); // last 7d: 1 per 300m

    // Page through commits, newest first
    var page = 1;
    const perPage = 100;
    final selected = <GistCommit>[];
    final pickedByBucket = <String, bool>{};
    while (selected.length < perRunBudget) {
      final client = await _resolveNetworkWithToken();
      final commits = await client.listCommits(
        gistId,
        page: page,
        perPage: perPage,
      );
      if (commits.isEmpty) {
        break;
      }

      for (final commit in commits) {
        if (selected.length >= perRunBudget) break;
        final rev = commit.revisionId;
        final t = commit.observedAt;
        if (knownRevisionIds.contains(rev)) {
          // Already cached
          continue;
        }

        // Always include commits newer than newest local reading
        final isNewerThanLocal = newestLocal == null || t.isAfter(newestLocal);
        // Backfill older than oldest local reading
        final isOlderThanLocal = oldestLocal == null || t.isBefore(oldestLocal);

        bool accept = false;
        if (isNewerThanLocal) {
          // For latest window, keep density by time buckets. If requested,
          // prioritize 5-minute resolution in the last hour.
          final interval =
              (prioritizeLastHour &&
                  t.isAfter(now.subtract(const Duration(hours: 1))))
              ? focusInterval
              : stage1Interval;
          final bucketKey = _timeBucketKey(t, interval);
          if (!pickedByBucket.containsKey(bucketKey)) {
            pickedByBucket[bucketKey] = true;
            accept = true;
          }
        } else if (isOlderThanLocal) {
          // Stage 0: ensure ~1/5m in last hour when prioritized
          if (prioritizeLastHour &&
              t.isAfter(now.subtract(const Duration(hours: 1)))) {
            final bucketKey = _timeBucketKey(t, focusInterval);
            if (!pickedByBucket.containsKey(bucketKey)) {
              pickedByBucket[bucketKey] = true;
              accept = true;
            }
          }
          // Stage 1: ensure ~1/60m in last 24h
          else if (t.isAfter(twentyFourHoursAgo)) {
            final bucketKey = _timeBucketKey(t, stage1Interval);
            if (!pickedByBucket.containsKey(bucketKey)) {
              pickedByBucket[bucketKey] = true;
              accept = true;
            }
          }
          // Stage 2: ensure ~1/300m up to 7d
          else if (t.isAfter(sevenDaysAgo)) {
            final bucketKey = _timeBucketKey(t, stage2Interval);
            if (!pickedByBucket.containsKey(bucketKey)) {
              pickedByBucket[bucketKey] = true;
              accept = true;
            }
          }
          // Stage 3+: beyond 7d, sample lightly to build long tail
          else if (t.isAfter(oneYearAgo)) {
            final stride = 60; // ~1 in 60
            accept = ((rev.hashCode & 0x7fffffff) % stride) == 0;
          } else {
            final stride = 600; // very sparse for >1y
            accept = ((rev.hashCode & 0x7fffffff) % stride) == 0;
          }
        }

        if (accept) {
          selected.add(commit);
        }
      }

      if (commits.length < perPage) {
        break; // no more pages
      }
      page += 1;
    }

    final samples = <TemperatureSample>[];
    for (final commit in selected) {
      if (!hasToken && interRequestDelay > Duration.zero) {
        await Future<void>.delayed(interRequestDelay);
      }
      final client = await _resolveNetworkWithToken();
      final value = await client.fetchRevisionValue(gistId, commit.revisionId);
      if (value == null) continue;
      samples.add(
        TemperatureSample.revision(
          thermostatId: thermostatId,
          revisionId: commit.revisionId,
          valueC: value,
          observedAt: commit.observedAt,
        ),
      );
      if (samples.length >= perRunBudget) break;
    }

    await _repository.upsertHistory(
      thermostatId: thermostatId,
      samples: samples,
    );
  }

  String _timeBucketKey(DateTime t, Duration interval) {
    final seconds = t.toUtc().millisecondsSinceEpoch ~/ 1000;
    final bucket = seconds ~/ interval.inSeconds;
    return '${interval.inSeconds}_$bucket';
  }

  Future<ThermostatNetworkDataSource> _resolveNetworkWithToken() async {
    if (_network is ThermostatHttpClient && (_network).hasGithubToken) {
      return _network;
    }
    final token = await _tokenSupplier?.call();
    if (token != null && token.isNotEmpty) {
      return ThermostatHttpClient(githubToken: token);
    }
    return _network;
  }
}

class ThermostatRefreshResult {
  const ThermostatRefreshResult({
    required this.status,
    required this.message,
    this.valueC,
    required this.fetchedAt,
  });

  final ThermostatReadingStatus status;
  final String message;
  final double? valueC;
  final DateTime fetchedAt;

  bool get isSuccess =>
      status == ThermostatReadingStatus.ok ||
      status == ThermostatReadingStatus.outOfRange;
}
