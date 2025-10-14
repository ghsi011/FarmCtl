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
  }) : _repository = repository,
       _network = network;

  final ThermostatRepository _repository;
  final ThermostatNetworkDataSource _network;

  Future<Thermostat> createAndTest(ThermostatDraft draft) async {
    final validation = ThermostatValidator.validate(draft);
    if (!validation.isValid) {
      throw ThermostatValidationException(validation);
    }

    final result = await _network.fetchCurrent(draft.rawUrl.trim());
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
    ThermostatDraft draft,
  ) async {
    final validation = ThermostatValidator.validate(draft);
    if (!validation.isValid) {
      throw ThermostatValidationException(validation);
    }

    final result = await _network.fetchCurrent(draft.rawUrl.trim());
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
      final result = await _network.fetchCurrent(thermostat.rawUrl.trim());
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

  Future<void> refreshHistory(String thermostatId) async {
    final thermostat = await _repository.findById(thermostatId);
    if (thermostat == null) {
      throw StateError('Thermostat not found for id $thermostatId');
    }

    final gistId = thermostat.rawUrl.trim();
    final now = DateTime.now().toUtc();
    final sevenDaysAgo = now.subtract(const Duration(days: 7));
    final oneYearAgo = now.subtract(const Duration(days: 365));

    final newestLocal = await _repository.getNewestReadingTime(thermostatId);
    final oldestLocal = await _repository.getOldestReadingTime(thermostatId);
    final knownRevisionIds = await _repository.listKnownRevisionIds(
      thermostatId,
    );

    final hasToken =
        (Platform.environment['FARMCTL_GITHUB_TOKEN'] ??
            Platform.environment['GITHUB_TOKEN']) !=
        null;
    final perRunBudget = hasToken ? 200 : 15;
    final interRequestDelay = hasToken
        ? Duration.zero
        : const Duration(milliseconds: 350);

    // Page through commits, newest first
    var page = 1;
    const perPage = 100;
    final selected = <GistCommit>[];
    while (selected.length < perRunBudget) {
      final commits = await _network.listCommits(
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

        // Sampling based on age
        final int stride;
        if (t.isAfter(sevenDaysAgo)) {
          stride = 10; // ~1 in 10 within last 7 days
        } else if (t.isAfter(oneYearAgo)) {
          stride = 60; // ~1 in 60 up to a year
        } else {
          stride = 600; // older than a year
        }

        // Use a simple hash gate for sampling without state
        final hashGate = (rev.hashCode & 0x7fffffff) % stride == 0;

        // Always include commits newer than the newest local reading
        final isNewerThanLocal = newestLocal == null || t.isAfter(newestLocal);
        // Backfill older than oldest local reading with sampling
        final isOlderThanLocal = oldestLocal == null || t.isBefore(oldestLocal);

        if (isNewerThanLocal || (isOlderThanLocal && hashGate)) {
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
      final value = await _network.fetchRevisionValue(
        gistId,
        commit.revisionId,
      );
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
