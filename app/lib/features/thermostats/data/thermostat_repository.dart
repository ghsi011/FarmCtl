import 'package:drift/drift.dart' as drift;
import 'package:uuid/uuid.dart';

import '../models/temperature_sample.dart';
import '../models/thermostat.dart';
import '../models/thermostat_state.dart';
import 'thermostat_database.dart';
import 'thermostat_reading_utils.dart';

final _uuid = const Uuid();
const Duration _defaultRetentionMaxAge = Duration(days: 548);
const int _defaultRetentionMaxEntries = 5000;

class ThermostatRepository {
  ThermostatRepository(this._database);

  final ThermostatDatabase _database;

  Stream<List<ThermostatSummary>> watchThermostats() {
    return _database.watchThermostatsWithState().map(
      (rows) => rows
          .map(
            (row) => ThermostatSummary(
              thermostat: Thermostat.fromEntry(row.thermostat),
              state: row.state != null
                  ? ThermostatState.fromEntry(row.state!)
                  : null,
            ),
          )
          .toList(),
    );
  }

  Future<List<ThermostatSummary>> fetchThermostats() async {
    final rows = await _database.listThermostatsWithState();
    return rows
        .map(
          (row) => ThermostatSummary(
            thermostat: Thermostat.fromEntry(row.thermostat),
            state: row.state != null
                ? ThermostatState.fromEntry(row.state!)
                : null,
          ),
        )
        .toList();
  }

  Stream<ThermostatSummary?> watchThermostat(String id) {
    return _database.watchThermostatWithState(id).map((row) {
      if (row == null) {
        return null;
      }
      return ThermostatSummary(
        thermostat: Thermostat.fromEntry(row.thermostat),
        state: row.state != null ? ThermostatState.fromEntry(row.state!) : null,
      );
    });
  }

  Future<Thermostat> create(ThermostatDraft draft) async {
    final validation = ThermostatValidator.validate(draft);
    if (!validation.isValid) {
      throw ThermostatValidationException(validation);
    }

    final id = _uuid.v4();
    final now = DateTime.now().toUtc();
    final companion = ThermostatEntriesCompanion(
      id: drift.Value(id),
      name: drift.Value(draft.name.trim()),
      rawUrl: drift.Value(draft.rawUrl.trim()),
      minC: drift.Value(draft.minC),
      maxC: drift.Value(draft.maxC),
      createdAt: drift.Value(now),
      updatedAt: drift.Value(now),
    );

    await _database.upsertThermostat(companion);
    final row = await _database.getThermostat(id);
    if (row == null) {
      throw StateError('Failed to load created thermostat');
    }
    return Thermostat.fromEntry(row);
  }

  Future<Thermostat> update(Thermostat existing, ThermostatDraft draft) async {
    final validation = ThermostatValidator.validate(draft);
    if (!validation.isValid) {
      throw ThermostatValidationException(validation);
    }

    final now = DateTime.now().toUtc();
    final companion = ThermostatEntriesCompanion(
      id: drift.Value(existing.id),
      name: drift.Value(draft.name.trim()),
      rawUrl: drift.Value(draft.rawUrl.trim()),
      minC: drift.Value(draft.minC),
      maxC: drift.Value(draft.maxC),
      hysteresisEnabled: drift.Value(existing.hysteresisEnabled),
      monitoringEnabled: drift.Value(existing.monitoringEnabled),
      createdAt: drift.Value(existing.createdAt),
      updatedAt: drift.Value(now),
    );

    await _database.upsertThermostat(companion);
    final row = await _database.getThermostat(existing.id);
    if (row == null) {
      throw StateError('Failed to load updated thermostat');
    }
    return Thermostat.fromEntry(row);
  }

  Future<void> delete(String id) async {
    await _database.transaction(() async {
      await _database.deleteTemperatureReadingsByThermostat(id);
      await _database.deleteThermostatStateById(id);
      await _database.deleteThermostatById(id);
    });
  }

  Future<ThermostatState?> loadState(String id) async {
    final entry = await _database.getThermostatState(id);
    if (entry == null) {
      return null;
    }
    return ThermostatState.fromEntry(entry);
  }

  Future<void> saveState({
    required String thermostatId,
    required ThermostatReadingStatus status,
    double? valueC,
    DateTime? fetchedAt,
    String? etag,
    String? message,
    DateTime? lastAlarmAt,
    bool setLastAlarmAt = false,
    DateTime? snoozedUntil,
    bool setSnoozedUntil = false,
    bool? silenceUntilOk,
    bool setSilenceUntilOk = false,
  }) async {
    final now = DateTime.now().toUtc();
    await _database.upsertThermostatState(
      ThermostatStateEntriesCompanion(
        thermostatId: drift.Value(thermostatId),
        lastStatus: drift.Value(status.name),
        lastValueC: valueC != null
            ? drift.Value(valueC)
            : const drift.Value.absent(),
        lastFetchedAt: fetchedAt != null
            ? drift.Value(fetchedAt)
            : const drift.Value.absent(),
        etag: etag != null ? drift.Value(etag) : const drift.Value.absent(),
        statusMessage: message != null
            ? drift.Value(message)
            : const drift.Value.absent(),
        lastAlarmAt: setLastAlarmAt
            ? (lastAlarmAt != null
                  ? drift.Value(lastAlarmAt)
                  : const drift.Value(null))
            : const drift.Value.absent(),
        snoozedUntil: setSnoozedUntil
            ? (snoozedUntil != null
                  ? drift.Value(snoozedUntil)
                  : const drift.Value(null))
            : const drift.Value.absent(),
        silenceUntilOk: setSilenceUntilOk && silenceUntilOk != null
            ? drift.Value(silenceUntilOk)
            : const drift.Value.absent(),
        createdAt: const drift.Value.absent(),
        updatedAt: drift.Value(now),
      ),
    );
  }

  /// Atomically records an out-of-range reading and decides whether to raise a
  /// fresh alarm.
  ///
  /// The decision and the `lastAlarmAt` write happen inside a single
  /// transaction that re-reads the current state row, so a concurrent snooze /
  /// silence / alarm write from another isolate cannot be lost and two
  /// overlapping monitor runs cannot both fire (compare-and-set: only the run
  /// that observes an eligible state advances `lastAlarmAt`). Returns whether
  /// the caller should dispatch the alarm notification.
  Future<bool> recordOutOfRangeAndShouldAlarm({
    required String thermostatId,
    required double valueC,
    required DateTime fetchedAt,
    String? etag,
    required String message,
    required DateTime now,
    Duration rateLimit = kAlarmRateLimit,
  }) async {
    return _database.transaction(() async {
      final entry = await _database.getThermostatState(thermostatId);
      final previous = entry != null ? ThermostatState.fromEntry(entry) : null;

      final fire = shouldTriggerAlarm(
        previousState: previous,
        now: now,
        rateLimit: rateLimit,
      );
      final clearSnooze = fire && previous?.snoozedUntil != null;

      await _database.upsertThermostatState(
        ThermostatStateEntriesCompanion(
          thermostatId: drift.Value(thermostatId),
          lastStatus: drift.Value(ThermostatReadingStatus.outOfRange.name),
          lastValueC: drift.Value(valueC),
          lastFetchedAt: drift.Value(fetchedAt),
          etag: etag != null ? drift.Value(etag) : const drift.Value.absent(),
          statusMessage: drift.Value(message),
          lastAlarmAt: fire ? drift.Value(now) : const drift.Value.absent(),
          snoozedUntil: clearSnooze
              ? const drift.Value(null)
              : const drift.Value.absent(),
          createdAt: const drift.Value.absent(),
          updatedAt: drift.Value(DateTime.now().toUtc()),
        ),
      );

      return fire;
    });
  }

  Future<void> updateSnoozedUntil(String thermostatId, DateTime? until) async {
    final now = DateTime.now().toUtc();
    await _database.upsertThermostatState(
      ThermostatStateEntriesCompanion(
        thermostatId: drift.Value(thermostatId),
        snoozedUntil: until != null
            ? drift.Value(until)
            : const drift.Value(null),
        updatedAt: drift.Value(now),
      ),
    );
  }

  Future<void> updateSilenceUntilOk(String thermostatId, bool value) async {
    final now = DateTime.now().toUtc();
    await _database.upsertThermostatState(
      ThermostatStateEntriesCompanion(
        thermostatId: drift.Value(thermostatId),
        silenceUntilOk: drift.Value(value),
        updatedAt: drift.Value(now),
      ),
    );
  }

  Future<Thermostat?> findById(String id) async {
    final entry = await _database.getThermostat(id);
    return entry != null ? Thermostat.fromEntry(entry) : null;
  }

  Stream<List<TemperatureSample>> watchHistory(
    String thermostatId, {
    DateTime? since,
  }) {
    return _database
        .watchTemperatureReadings(thermostatId, since: since)
        .map(
          (rows) => rows
              .map(
                (row) => TemperatureSample(
                  id: row.id,
                  thermostatId: row.thermostatId,
                  valueC: row.valueC,
                  // Normalise to UTC; Drift stores datetimes in unix mode which
                  // reads back in the local zone.
                  observedAt: row.observedAt.toUtc(),
                  source: row.source,
                  sourceId: row.sourceId,
                ),
              )
              .toList(),
        );
  }

  Future<void> replaceHistory({
    required String thermostatId,
    required Iterable<TemperatureSample> samples,
  }) async {
    final now = DateTime.now().toUtc();
    final rows = samples
        .map(
          (sample) => TemperatureReadingsCompanion(
            id: drift.Value(sample.id),
            thermostatId: drift.Value(sample.thermostatId),
            source: drift.Value(sample.source),
            valueC: drift.Value(sample.valueC),
            observedAt: drift.Value(sample.observedAt),
            sourceId: sample.sourceId != null
                ? drift.Value(sample.sourceId)
                : const drift.Value.absent(),
            createdAt: drift.Value(now),
            updatedAt: drift.Value(now),
          ),
        )
        .toList();

    await _database.transaction(() async {
      if (rows.isNotEmpty) {
        await _database.insertTemperatureReadings(rows);
      }
    });
  }

  Future<void> upsertHistory({
    required String thermostatId,
    required Iterable<TemperatureSample> samples,
  }) async {
    final now = DateTime.now().toUtc();
    final rows = samples
        .map(
          (sample) => TemperatureReadingsCompanion(
            id: drift.Value(sample.id),
            thermostatId: drift.Value(sample.thermostatId),
            source: drift.Value(sample.source),
            valueC: drift.Value(sample.valueC),
            observedAt: drift.Value(sample.observedAt),
            sourceId: sample.sourceId != null
                ? drift.Value(sample.sourceId)
                : const drift.Value.absent(),
            createdAt: drift.Value(now),
            updatedAt: drift.Value(now),
          ),
        )
        .toList();

    if (rows.isEmpty) {
      return;
    }

    await _database.insertTemperatureReadings(rows);
  }

  Future<DateTime?> getNewestReadingTime(String thermostatId) {
    return _database.getNewestReadingTime(thermostatId);
  }

  Future<DateTime?> getOldestReadingTime(String thermostatId) {
    return _database.getOldestReadingTime(thermostatId);
  }

  Future<Set<String>> listKnownRevisionIds(String thermostatId) {
    return _database.listKnownRevisionIds(thermostatId);
  }

  Future<void> pruneRetention({
    Duration maxAge = _defaultRetentionMaxAge,
    int maxEntriesPerThermostat = _defaultRetentionMaxEntries,
    String? thermostatId,
    DateTime? now,
  }) async {
    final referenceTime = (now ?? DateTime.now()).toUtc();

    // Run the age-based and per-thermostat caps in one transaction so a failure
    // partway through cannot leave readings half-pruned.
    await _database.transaction(() async {
      if (maxAge > Duration.zero) {
        final cutoff = referenceTime.subtract(maxAge);
        await _database.pruneTemperatureReadingsBefore(cutoff);
      }

      final ids = thermostatId != null
          ? <String>[thermostatId]
          : (await _database.listThermostats())
                .map((entry) => entry.id)
                .toList();

      for (final id in ids) {
        await _database.pruneTemperatureReadingsExceedingLimit(
          id,
          maxEntriesPerThermostat,
        );
      }
    });
  }
}
