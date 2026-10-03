import 'package:flutter/foundation.dart';
import '../../../core/background/thermostat_monitor.dart'
    show cancelAlarmNotification;
import '../models/temperature_sample.dart';
import '../models/thermostat.dart';
import '../models/thermostat_state.dart';
import 'thermostat_client.dart';
import 'thermostat_reading_utils.dart';
import 'thermostat_repository.dart';

/// Poll cadence assumed for staleness when no supplier is wired or the config
/// is transiently unreadable; yields the 15-minute threshold floor.
const Duration _defaultPollIntervalForStaleness = Duration(minutes: 5);

class ThermostatService {
  ThermostatService({
    required ThermostatRepository repository,
    required ThermostatNetworkDataSource network,
    Future<String?> Function()? tokenSupplier,
    Future<Duration?> Function()? pollIntervalSupplier,
    DateTime Function()? clock,
  }) : _repository = repository,
       _network = network,
       _tokenSupplier = tokenSupplier,
       _pollIntervalSupplier = pollIntervalSupplier,
       _clock = clock ?? _defaultClock;

  final ThermostatRepository _repository;
  final ThermostatNetworkDataSource _network;
  final Future<String?> Function()? _tokenSupplier;
  final Future<Duration?> Function()? _pollIntervalSupplier;
  final DateTime Function() _clock;
  final _historyRuns = <String, Future<void>>{};
  final _historyCursors = <String, _HistoryCursor>{};

  static DateTime _defaultClock() => DateTime.now().toUtc();

  /// Resolves the configured poll interval for the stale-data threshold,
  /// falling back to a sane default so a transient config failure can't turn
  /// a refresh into an error.
  Future<Duration> _resolvePollInterval() async {
    try {
      return await _pollIntervalSupplier?.call() ??
          _defaultPollIntervalForStaleness;
    } catch (_) {
      return _defaultPollIntervalForStaleness;
    }
  }

  Future<Thermostat> createAndTest(
    ThermostatDraft draft, {
    String? tokenOverride,
  }) async {
    final validation = ThermostatValidator.validate(draft);
    if (!validation.isValid) {
      throw ThermostatValidationException(validation);
    }

    final overrideClient = tokenOverride != null && tokenOverride.isNotEmpty
        ? ThermostatHttpClient(
            githubToken: tokenOverride,
            allowAnonFallback: false,
          )
        : null;
    final network = overrideClient ?? _network;
    try {
      final result = await network.fetchCurrent(draft.rawUrl.trim());
      final saved = await _repository.create(draft);
      await _saveTestedState(saved, result);
      return saved;
    } finally {
      overrideClient?.close();
    }
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

    final overrideClient = tokenOverride != null && tokenOverride.isNotEmpty
        ? ThermostatHttpClient(
            githubToken: tokenOverride,
            allowAnonFallback: false,
          )
        : null;
    final network = overrideClient ?? _network;
    try {
      final result = await network.fetchCurrent(draft.rawUrl.trim());
      final updated = await _repository.update(existing, draft);
      await _saveTestedState(updated, result);
      return updated;
    } finally {
      overrideClient?.close();
    }
  }

  /// Persists the result of a test fetch, evaluating the value against the
  /// thermostat's (possibly just-changed) range so an active out-of-range
  /// condition is not cleared to "ok" just because the user edited the
  /// thermostat. Mirrors [refresh].
  Future<void> _saveTestedState(
    Thermostat thermostat,
    ThermostatFetchSuccess result,
  ) async {
    final value = result.valueC;
    final previousState = await _repository.loadState(thermostat.id);
    final outOfRange = isThermostatReadingOutOfRange(
      thermostat: thermostat,
      currentValue: value,
      previousState: previousState,
    );

    if (outOfRange) {
      await _repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.outOfRange,
        valueC: value,
        fetchedAt: result.fetchedAt,
        dataUpdatedAt: result.dataUpdatedAt,
        setDataUpdatedAt: true,
        etag: result.etag,
        message: formatOutOfRangeThermostatMessage(thermostat, value),
      );
      return;
    }

    // Mirror refresh(): a reachable gist whose content stopped updating is
    // stale, not OK. Record the status only — do NOT clear snooze/silence or
    // cancel the alarm notification, since alarm arbitration for a possibly
    // dead sensor belongs to the background monitor.
    final pollInterval = await _resolvePollInterval();
    if (isThermostatDataStale(
      dataUpdatedAt: result.dataUpdatedAt,
      now: _clock(),
      pollInterval: pollInterval,
    )) {
      final dataUpdatedAt = result.dataUpdatedAt!;
      await _repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.stale,
        valueC: value,
        fetchedAt: result.fetchedAt,
        dataUpdatedAt: dataUpdatedAt,
        setDataUpdatedAt: true,
        etag: result.etag,
        message: formatStaleDataMessage(dataUpdatedAt),
      );
      return;
    }

    // OK reading: clear any snooze/silence, exactly as refresh() does — otherwise
    // editing a snoozed/silenced thermostat to an in-range value would leave the
    // suppression in place and mute the next genuine out-of-range alarm.
    await _repository.saveState(
      thermostatId: thermostat.id,
      status: ThermostatReadingStatus.ok,
      valueC: value,
      fetchedAt: result.fetchedAt,
      dataUpdatedAt: result.dataUpdatedAt,
      setDataUpdatedAt: true,
      etag: result.etag,
      message: 'Fetched ${value.toStringAsFixed(2)}°C',
      setSnoozedUntil: previousState?.snoozedUntil != null,
      snoozedUntil: null,
      setSilenceUntilOk: previousState?.silenceUntilOk == true,
      silenceUntilOk: false,
    );
    // Editing a thermostat to an in-range value should also drop any alarm
    // notification left over from a prior out-of-range condition.
    await cancelAlarmNotification(thermostat.id);
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
          dataUpdatedAt: result.dataUpdatedAt,
          setDataUpdatedAt: true,
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

      // Mirror the background monitor's dead-sensor detection: a reachable
      // gist whose content stopped updating is stale, not OK. The foreground
      // path only records the status (so the card shows it immediately) — it
      // deliberately does NOT touch lastAlarmAt or dispatch a notification,
      // leaving alarm arbitration to the monitor exactly as out-of-range does.
      final pollInterval = await _resolvePollInterval();
      if (isThermostatDataStale(
        dataUpdatedAt: result.dataUpdatedAt,
        now: _clock(),
        pollInterval: pollInterval,
      )) {
        final dataUpdatedAt = result.dataUpdatedAt!;
        final message = formatStaleDataMessage(dataUpdatedAt);
        await _repository.saveState(
          thermostatId: thermostat.id,
          status: ThermostatReadingStatus.stale,
          valueC: value,
          fetchedAt: fetchedAt,
          dataUpdatedAt: dataUpdatedAt,
          setDataUpdatedAt: true,
          etag: result.etag,
          message: message,
        );
        return ThermostatRefreshResult(
          status: ThermostatReadingStatus.stale,
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
        dataUpdatedAt: result.dataUpdatedAt,
        setDataUpdatedAt: true,
        etag: result.etag,
        message: message,
        setSnoozedUntil: shouldClearSnooze,
        snoozedUntil: null,
        setSilenceUntilOk: hadSilence,
        silenceUntilOk: false,
      );
      // Mirror the background monitor's OK path: an in-range reading clears any
      // alarm notification still showing for this thermostat. Without this, a
      // foreground refresh (e.g. on app open after recovery) would mark the card
      // OK while leaving the ongoing alarm up until the next background tick.
      await cancelAlarmNotification(thermostat.id);
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
    final previous = _historyRuns[thermostatId];
    final run = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // A failed run must not poison the serialization queue.
        }
      }
      await _refreshHistory(thermostatId, prioritizeLastHour);
    }();
    _historyRuns[thermostatId] = run;
    try {
      await run;
    } finally {
      if (identical(_historyRuns[thermostatId], run)) {
        _historyRuns.remove(thermostatId);
      }
    }
  }

  Future<void> _refreshHistory(
    String thermostatId,
    bool prioritizeLastHour,
  ) async {
    final thermostat = await _repository.findById(thermostatId);
    if (thermostat == null) {
      _historyCursors.remove(thermostatId);
      throw StateError('Thermostat not found for id $thermostatId');
    }

    final gistId = thermostat.rawUrl.trim();
    final now = _clock().toUtc();
    final twentyFourHoursAgo = now.subtract(const Duration(hours: 24));
    final sevenDaysAgo = now.subtract(const Duration(days: 7));
    final oneYearAgo = now.subtract(const Duration(days: 365));

    final newestLocal = await _repository.getNewestReadingTime(thermostatId);
    final oldestLocal = await _repository.getOldestReadingTime(thermostatId);
    final knownRevisionIds = await _repository.listKnownRevisionIds(
      thermostatId,
    );

    final client = await _resolveNetworkWithToken();
    final hasToken = client is ThermostatHttpClient && client.hasGithubToken;
    // Increase budget when token present; be more aggressive for the last 24h
    final perRunBudget = hasToken ? 400 : 20;
    final interRequestDelay = hasToken
        ? Duration.zero
        : const Duration(milliseconds: 300);

    // Stage selection buckets
    final focusInterval = const Duration(minutes: 5); // last 1h: 1 per 5m
    final stage1Interval = const Duration(minutes: 60); // last 24h: 1 per 60m
    final stage2Interval = const Duration(minutes: 300); // last 7d: 1 per 300m

    final previousCursor = _historyCursors.remove(thermostatId);
    final cursor = previousCursor != null && previousCursor.source == gistId
        ? previousCursor
        : _HistoryCursor(gistId);
    _historyCursors[thermostatId] = cursor;
    while (_historyCursors.length > 64) {
      _historyCursors.remove(_historyCursors.keys.first);
    }
    const perPage = 100;
    final pickedByBucket = <String, bool>{};
    final pages = <int, List<GistCommit>>{};
    var listAttempts = 0;
    var revisionAttempts = 0;
    // Head, sweep, and deep each receive reserved work. Cached pages are shared,
    // but every actual list attempt (including a failure) consumes this cap.
    Future<List<GistCommit>?> loadPage(int page, int ceiling) async {
      if (pages.containsKey(page)) return pages[page];
      if (listAttempts >= ceiling) return null;
      listAttempts++;
      final commits = await client.listCommits(
        gistId,
        page: page,
        perPage: perPage,
      );
      pages[page] = commits;
      return commits;
    }

    Future<bool> acknowledge(
      GistCommit commit,
      int ceiling,
      bool recent,
    ) async {
      final rev = commit.revisionId;
      final t = commit.observedAt;
      if (knownRevisionIds.contains(rev)) {
        return true;
      }

      // Always include commits newer than newest local reading
      final isNewerThanLocal = newestLocal == null || t.isAfter(newestLocal);
      // Backfill older than oldest local reading
      final isOlderThanLocal = oldestLocal == null || t.isBefore(oldestLocal);

      bool accept = false;
      String? selectedBucket;
      if (isNewerThanLocal ||
          (recent &&
              (cursor.sweepFloor == null || t.isAfter(cursor.sweepFloor!)))) {
        // For latest window, keep density by time buckets. If requested,
        // prioritize 5-minute resolution in the last hour.
        final interval =
            (prioritizeLastHour &&
                t.isAfter(now.subtract(const Duration(hours: 1))))
            ? focusInterval
            : stage1Interval;
        final bucketKey = _timeBucketKey(t, interval);
        if (!pickedByBucket.containsKey(bucketKey)) {
          selectedBucket = bucketKey;
          accept = true;
        }
      } else if (isOlderThanLocal) {
        // Stage 0: ensure ~1/5m in last hour when prioritized
        if (prioritizeLastHour &&
            t.isAfter(now.subtract(const Duration(hours: 1)))) {
          final bucketKey = _timeBucketKey(t, focusInterval);
          if (!pickedByBucket.containsKey(bucketKey)) {
            selectedBucket = bucketKey;
            accept = true;
          }
        }
        // Stage 1: ensure ~1/60m in last 24h
        else if (t.isAfter(twentyFourHoursAgo)) {
          final bucketKey = _timeBucketKey(t, stage1Interval);
          if (!pickedByBucket.containsKey(bucketKey)) {
            selectedBucket = bucketKey;
            accept = true;
          }
        }
        // Stage 2: ensure ~1/300m up to 7d
        else if (t.isAfter(sevenDaysAgo)) {
          final bucketKey = _timeBucketKey(t, stage2Interval);
          if (!pickedByBucket.containsKey(bucketKey)) {
            selectedBucket = bucketKey;
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
        if (revisionAttempts >= ceiling) {
          return false;
        }
        revisionAttempts++;
        if (interRequestDelay > Duration.zero) {
          await Future<void>.delayed(interRequestDelay);
        }
        final value = await client.fetchRevisionValue(gistId, rev);
        if (value == null) {
          // An immutable revision without a usable temperature is a safe
          // skip, not a transport/store failure. Count the attempt, but do
          // not cache a sample or consume its sampling bucket.
          return true;
        }
        await _repository.upsertHistory(
          thermostatId: thermostatId,
          samples: [
            TemperatureSample.revision(
              thermostatId: thermostatId,
              revisionId: rev,
              valueC: value,
              observedAt: t,
            ),
          ],
        );
        knownRevisionIds.add(rev);
        if (selectedBucket != null) pickedByBucket[selectedBucket] = true;
      }
      return true;
    }

    Future<bool> scan(
      _HistoryLane lane,
      int listCeiling,
      int revisionCeiling, {
      String? target,
      bool recent = false,
    }) async {
      var page = lane.searchPage ?? lane.pageHint;
      var searching = lane.anchor != null;
      while (true) {
        final commits = await loadPage(page, listCeiling);
        if (commits == null) return false;
        var start = 0;
        if (searching) {
          final index = commits.indexWhere((c) => c.revisionId == lane.anchor);
          if (index < 0) {
            if (commits.length < perPage) {
              // Rewritten/deleted anchor: replay from the head, never jump an
              // unverified offset. Missing targets complete only at the end.
              lane.reset();
              return false;
            }
            lane.searchPage = ++page;
            continue;
          }
          searching = false;
          lane.searchPage = null;
          start = index + 1;
        }
        for (final commit in commits.skip(start)) {
          if (commit.revisionId == target) return true;
          if (!await acknowledge(commit, revisionCeiling, recent)) return false;
          // Only persisted, cached, or sampling-rejected positions are safe.
          lane.anchor = commit.revisionId;
          lane.pageHint = page;
        }
        if (commits.length < perPage) return true;
        page++;
      }
    }

    final head = await loadPage(1, 1);
    if (head == null || head.isEmpty) {
      cursor.reset();
      return;
    }
    final headId = head.first.revisionId;
    if (cursor.sweepHead == null && cursor.highWater != headId) {
      cursor.sweepHead = headId;
      cursor.sweepHeadTime = head.first.observedAt;
      cursor.sweepTarget = cursor.highWater;
      cursor.sweepFloor = cursor.highWaterTime ?? newestLocal;
      cursor.sweep.reset();
    }
    for (final commit in head) {
      if (!await acknowledge(commit, perRunBudget ~/ 5, false)) break;
    }
    // The captured sweep is not reset by new prepends. The next sweep covers
    // everything between the next head and this captured head.
    if (cursor.sweepHead != null &&
        await scan(
          cursor.sweep,
          4,
          perRunBudget ~/ 2,
          target: cursor.sweepTarget,
          recent: true,
        )) {
      cursor.highWater = cursor.sweepHead;
      cursor.highWaterTime = cursor.sweepHeadTime;
      cursor.sweepHead = null;
      cursor.sweep.reset();
    }
    if (cursor.deepEndHead != headId) {
      if (cursor.deepEndHead != null) {
        cursor.deep.reset();
        cursor.deepEndHead = null;
      }
      if (await scan(cursor.deep, 8, perRunBudget)) {
        cursor.deepEndHead = headId;
        cursor.deep.reset();
      }
    }

    try {
      await _repository.pruneRetention(thermostatId: thermostatId);
    } catch (error, stackTrace) {
      debugPrint('Retention pruning failed for $thermostatId: $error');
      debugPrint('$stackTrace');
    }
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

/// Constant-size continuation, scoped to one service instance and source.
class _HistoryLane {
  String? anchor;
  int pageHint = 1;
  int? searchPage;

  void reset() {
    anchor = null;
    pageHint = 1;
    searchPage = null;
  }
}

class _HistoryCursor {
  _HistoryCursor(this.source);

  final String source;
  final sweep = _HistoryLane();
  final deep = _HistoryLane();
  String? highWater;
  String? sweepHead;
  String? sweepTarget;
  String? deepEndHead;
  DateTime? highWaterTime;
  DateTime? sweepHeadTime;
  DateTime? sweepFloor;

  void reset() {
    sweep.reset();
    deep.reset();
    highWater = null;
    sweepHead = null;
    sweepTarget = null;
    deepEndHead = null;
    highWaterTime = null;
    sweepHeadTime = null;
    sweepFloor = null;
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
      status == ThermostatReadingStatus.outOfRange ||
      // The fetch itself succeeded; the data is just old.
      status == ThermostatReadingStatus.stale;
}
