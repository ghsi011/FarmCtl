import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'thermostat_database.g.dart';

// Drift table definitions are declarative schema consumed by the code generator.
// At runtime Drift uses the generated `$...Table` classes, so these column
// getters are never executed — exclude them from coverage like generated code.
// coverage:ignore-start
class ThermostatEntries extends Table {
  TextColumn get id => text()();

  TextColumn get name => text().withLength(min: 1, max: 40)();

  TextColumn get rawUrl => text()();

  TextColumn get diagnosticsGistId => text().nullable()();

  TextColumn get deviceRef => text().nullable()();

  RealColumn get minC => real()();

  RealColumn get maxC => real()();

  BoolColumn get hysteresisEnabled =>
      boolean().withDefault(const Constant(false))();

  BoolColumn get monitoringEnabled =>
      boolean().withDefault(const Constant(true))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column>? get primaryKey => {id};
}

class ThermostatStateEntries extends Table {
  TextColumn get thermostatId => text()();

  RealColumn get lastValueC => real().nullable()();

  TextColumn get lastStatus => text().nullable()();

  DateTimeColumn get lastFetchedAt => dateTime().nullable()();

  /// When the gist content itself was last updated (the sensor's observation
  /// time), as opposed to [lastFetchedAt] which is when the app fetched it.
  DateTimeColumn get dataUpdatedAt => dateTime().nullable()();

  TextColumn get etag => text().nullable()();

  TextColumn get statusMessage => text().nullable()();

  DateTimeColumn get lastAlarmAt => dateTime().nullable()();

  DateTimeColumn get snoozedUntil => dateTime().nullable()();

  BoolColumn get silenceUntilOk =>
      boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column>? get primaryKey => {thermostatId};
}

class AlertConfigEntries extends Table {
  IntColumn get id => integer().autoIncrement()();

  IntColumn get pollIntervalMin => integer().withDefault(const Constant(5))();

  TextColumn get soundUri => text().nullable()();

  BoolColumn get vibrate => boolean().withDefault(const Constant(true))();

  BoolColumn get volumeBoost => boolean().withDefault(const Constant(false))();

  DateTimeColumn get pauseAllUntil => dateTime().nullable()();

  TextColumn get githubToken => text().nullable()();

  DateTimeColumn get lastMonitorRunAt => dateTime().nullable()();
}

@TableIndex(
  name: 'temperature_readings_thermostat_observed_idx',
  columns: {#thermostatId, #observedAt},
)
class TemperatureReadings extends Table {
  TextColumn get id => text()();

  TextColumn get thermostatId =>
      text().references(ThermostatEntries, #id, onDelete: KeyAction.cascade)();

  TextColumn get source => text()();

  RealColumn get valueC => real()();

  DateTimeColumn get observedAt => dateTime()();

  TextColumn get sourceId => text().nullable()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column>? get primaryKey => {id};
}

@TableIndex(
  name: 'device_events_device_fetched_idx',
  columns: {#deviceRef, #fetchedAt},
)
class DeviceEvents extends Table {
  TextColumn get deviceRef => text()();
  TextColumn get eventId => text()();
  TextColumn get thermostatId =>
      text().references(ThermostatEntries, #id, onDelete: KeyAction.cascade)();
  TextColumn get code => text()();
  IntColumn get count => integer()();
  DateTimeColumn get occurredAt => dateTime().nullable()();
  IntColumn get uptimeSeconds => integer().nullable()();
  DateTimeColumn get gistUpdatedAt => dateTime().nullable()();
  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column>? get primaryKey => {deviceRef, eventId};
}
// coverage:ignore-end

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File(p.join(directory.path, 'thermostats.sqlite'));
    return NativeDatabase.createInBackground(
      file,
      setup: (db) {
        // The foreground app and the background monitor isolate each open their
        // own connection to this file. WAL lets a reader and a writer coexist,
        // and a busy timeout makes a contended write wait for the other
        // connection to commit instead of immediately raising SQLITE_BUSY.
        db.execute('PRAGMA journal_mode = WAL;');
        db.execute('PRAGMA busy_timeout = 5000;');
      },
    );
  });
}

typedef ThermostatWithStateRow = ({
  ThermostatEntry thermostat,
  ThermostatStateEntry? state,
});

@DriftDatabase(
  tables: [
    ThermostatEntries,
    AlertConfigEntries,
    ThermostatStateEntries,
    TemperatureReadings,
    DeviceEvents,
  ],
)
class ThermostatDatabase extends _$ThermostatDatabase {
  ThermostatDatabase() : super(_openConnection());

  ThermostatDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 12;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 2) {
        // createTable builds the table with its *current* columns, so the
        // per-column upgrades below (v3/v4) must be skipped for installs coming
        // from v1 to avoid duplicate-column errors.
        await m.createTable(thermostatStateEntries);
      } else {
        if (from < 3) {
          await m.addColumn(
            thermostatStateEntries,
            thermostatStateEntries.statusMessage,
          );
        }
        if (from < 4) {
          await m.addColumn(
            thermostatStateEntries,
            thermostatStateEntries.lastAlarmAt,
          );
          await m.addColumn(
            thermostatStateEntries,
            thermostatStateEntries.snoozedUntil,
          );
          await m.addColumn(
            thermostatStateEntries,
            thermostatStateEntries.silenceUntilOk,
          );
        }
        if (from < 10) {
          // Data-age tracking for dead-sensor detection. Inside the `else` so
          // v1 installs — whose state table was just created with its current
          // columns above — don't hit a duplicate-column error.
          await m.addColumn(
            thermostatStateEntries,
            thermostatStateEntries.dataUpdatedAt,
          );
        }
      }
      if (from < 5) {
        await m.createTable(temperatureReadings);
      }
      if (from < 6) {
        await m.addColumn(alertConfigEntries, alertConfigEntries.githubToken);
      }
      if (from < 7) {
        await m.addColumn(
          alertConfigEntries,
          alertConfigEntries.lastMonitorRunAt,
        );
      }
      if (from < 8) {
        // A pre-fix concurrent-insert race could leave duplicate alert_config
        // rows. The LOWEST-id row is the live/canonical one (reads use
        // id ASC LIMIT 1, writes upsert id = 1); any higher-id duplicate is a
        // frozen leftover. Keep the live row's settings, forward-fill any
        // still-plaintext token from a duplicate (so it can be migrated to
        // secure storage), then drop the rest and pin to id = 1.
        await customStatement('''
          UPDATE alert_config_entries
          SET github_token = COALESCE(
            github_token,
            (SELECT github_token FROM alert_config_entries
             WHERE github_token IS NOT NULL ORDER BY id ASC LIMIT 1)
          )
          WHERE id = (SELECT MIN(id) FROM alert_config_entries)
        ''');
        await customStatement('''
          DELETE FROM alert_config_entries
          WHERE id <> (SELECT MIN(id) FROM alert_config_entries)
        ''');
        await customStatement('UPDATE alert_config_entries SET id = 1');
      }
      if (from < 9) {
        // The AlarmManager exact-alarm scheduling path was removed in favour
        // of a foreground service, which polls reliably without needing this
        // permission; the column it configured is now unused.
        await m.dropColumn(alertConfigEntries, 'exact_alarms_enabled');
      }
      if (from < 11) {
        await m.addColumn(
          thermostatEntries,
          thermostatEntries.diagnosticsGistId,
        );
        await m.addColumn(thermostatEntries, thermostatEntries.deviceRef);
      }
      if (from < 12) {
        await m.createTable(deviceEvents);
      }
    },
  );

  Future<List<ThermostatEntry>> listThermostats() {
    return (select(
      thermostatEntries,
    )..orderBy([(tbl) => OrderingTerm.asc(tbl.name)])).get();
  }

  Future<List<ThermostatWithStateRow>> listThermostatsWithState() {
    final query = select(thermostatEntries).join([
      leftOuterJoin(
        thermostatStateEntries,
        thermostatStateEntries.thermostatId.equalsExp(thermostatEntries.id),
      ),
    ])..orderBy([OrderingTerm.asc(thermostatEntries.name)]);

    return query.get().then(
      (rows) => rows
          .map(
            (row) => (
              thermostat: row.readTable(thermostatEntries),
              state: row.readTableOrNull(thermostatStateEntries),
            ),
          )
          .toList(),
    );
  }

  Stream<List<ThermostatWithStateRow>> watchThermostatsWithState() {
    final query = select(thermostatEntries).join([
      leftOuterJoin(
        thermostatStateEntries,
        thermostatStateEntries.thermostatId.equalsExp(thermostatEntries.id),
      ),
    ])..orderBy([OrderingTerm.asc(thermostatEntries.name)]);

    return query.watch().map(
      (rows) => rows
          .map(
            (row) => (
              thermostat: row.readTable(thermostatEntries),
              state: row.readTableOrNull(thermostatStateEntries),
            ),
          )
          .toList(),
    );
  }

  Future<ThermostatEntry?> getThermostat(String id) {
    return (select(
      thermostatEntries,
    )..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
  }

  Future<ThermostatStateEntry?> getThermostatState(String id) {
    return (select(
      thermostatStateEntries,
    )..where((tbl) => tbl.thermostatId.equals(id))).getSingleOrNull();
  }

  Stream<ThermostatWithStateRow?> watchThermostatWithState(String id) {
    final query = select(thermostatEntries).join([
      leftOuterJoin(
        thermostatStateEntries,
        thermostatStateEntries.thermostatId.equalsExp(thermostatEntries.id),
      ),
    ])..where(thermostatEntries.id.equals(id));

    return query.watchSingleOrNull().map(
      (row) => row == null
          ? null
          : (
              thermostat: row.readTable(thermostatEntries),
              state: row.readTableOrNull(thermostatStateEntries),
            ),
    );
  }

  Future<void> upsertThermostat(ThermostatEntriesCompanion data) async {
    await into(thermostatEntries).insertOnConflictUpdate(data);
  }

  Future<void> upsertThermostatState(
    ThermostatStateEntriesCompanion data,
  ) async {
    await into(thermostatStateEntries).insertOnConflictUpdate(data);
  }

  Future<void> deleteThermostatById(String id) async {
    await (delete(thermostatEntries)..where((tbl) => tbl.id.equals(id))).go();
  }

  Future<void> deleteThermostatStateById(String id) async {
    await (delete(
      thermostatStateEntries,
    )..where((tbl) => tbl.thermostatId.equals(id))).go();
  }

  Future<void> deleteTemperatureReadingsByThermostat(String id) async {
    await (delete(
      temperatureReadings,
    )..where((tbl) => tbl.thermostatId.equals(id))).go();
  }

  Future<void> insertTemperatureReadings(
    List<TemperatureReadingsCompanion> rows,
  ) async {
    if (rows.isEmpty) {
      return;
    }
    await batch((batch) {
      batch.insertAllOnConflictUpdate(temperatureReadings, rows);
    });
  }

  Future<void> upsertDeviceEvent(DeviceEventsCompanion event) async {
    await transaction(() async {
      final existing =
          await (select(deviceEvents)
                ..where((row) => row.deviceRef.equals(event.deviceRef.value))
                ..where((row) => row.eventId.equals(event.eventId.value)))
              .getSingleOrNull();
      final incomingGistAt = event.gistUpdatedAt.value;
      final existingGistAt = existing?.gistUpdatedAt;
      final isLatestSource =
          existing == null ||
          (incomingGistAt != null &&
              (existingGistAt == null ||
                  !incomingGistAt.isBefore(existingGistAt))) ||
          (incomingGistAt == null &&
              existingGistAt == null &&
              !event.fetchedAt.value.isBefore(existing.fetchedAt));
      await into(deviceEvents).insertOnConflictUpdate(
        event.copyWith(
          // Event ID and code are immutable. If a malformed/coalesced source
          // reuses an ID with a different code, retain the original code.
          code: Value(existing?.code ?? event.code.value),
          count: Value(
            existing == null || event.count.value > existing.count
                ? event.count.value
                : existing.count,
          ),
          occurredAt:
              isLatestSource &&
                  event.occurredAt.present &&
                  event.occurredAt.value != null
              ? event.occurredAt
              : Value(existing?.occurredAt),
          uptimeSeconds:
              isLatestSource &&
                  event.uptimeSeconds.present &&
                  event.uptimeSeconds.value != null
              ? event.uptimeSeconds
              : Value(existing?.uptimeSeconds),
          gistUpdatedAt:
              isLatestSource &&
                  event.gistUpdatedAt.present &&
                  event.gistUpdatedAt.value != null
              ? event.gistUpdatedAt
              : Value(existing?.gistUpdatedAt),
          fetchedAt: Value(
            !isLatestSource
                ? existing.fetchedAt
                : existing != null &&
                      existing.fetchedAt.isAfter(event.fetchedAt.value)
                ? existing.fetchedAt
                : event.fetchedAt.value,
          ),
        ),
      );
    });
  }

  Future<List<DeviceEvent>> listDeviceEvents(
    String deviceRef, {
    int limit = 50,
    required DateTime cutoff,
  }) {
    return (select(deviceEvents)
          ..where((row) => row.deviceRef.equals(deviceRef))
          ..where((row) => row.fetchedAt.isBiggerOrEqualValue(cutoff))
          ..orderBy([(row) => OrderingTerm.desc(row.fetchedAt)])
          ..limit(limit.clamp(1, 100)))
        .get();
  }

  Stream<List<DeviceEvent>> watchDeviceEvents(
    String deviceRef, {
    int limit = 50,
    required DateTime cutoff,
  }) {
    return (select(deviceEvents)
          ..where((row) => row.deviceRef.equals(deviceRef))
          ..where((row) => row.fetchedAt.isBiggerOrEqualValue(cutoff))
          ..orderBy([(row) => OrderingTerm.desc(row.fetchedAt)])
          ..limit(limit.clamp(1, 100)))
        .watch();
  }

  Future<int> pruneDeviceEventsBefore(DateTime cutoff) {
    return (delete(
      deviceEvents,
    )..where((row) => row.fetchedAt.isSmallerThanValue(cutoff))).go();
  }

  Future<void> pruneDeviceEvents({
    required String deviceRef,
    required int keepLatest,
  }) async {
    await customStatement(
      '''
      DELETE FROM device_events WHERE device_ref = ? AND event_id NOT IN (
        SELECT event_id FROM device_events WHERE device_ref = ?
        ORDER BY fetched_at DESC, event_id DESC LIMIT ?
      )
    ''',
      [deviceRef, deviceRef, keepLatest],
    );
  }

  Future<DateTime?> getNewestReadingTime(String thermostatId) async {
    final row =
        await (select(temperatureReadings)
              ..where((tbl) => tbl.thermostatId.equals(thermostatId))
              ..orderBy([(tbl) => OrderingTerm.desc(tbl.observedAt)])
              ..limit(1))
            .getSingleOrNull();
    return row?.observedAt;
  }

  Future<DateTime?> getOldestReadingTime(String thermostatId) async {
    final row =
        await (select(temperatureReadings)
              ..where((tbl) => tbl.thermostatId.equals(thermostatId))
              ..orderBy([(tbl) => OrderingTerm.asc(tbl.observedAt)])
              ..limit(1))
            .getSingleOrNull();
    return row?.observedAt;
  }

  Future<Set<String>> listKnownRevisionIds(String thermostatId) async {
    final rows =
        await (select(temperatureReadings)
              ..where((tbl) => tbl.thermostatId.equals(thermostatId))
              ..where((tbl) => tbl.source.equals('revision'))
              ..orderBy([(tbl) => OrderingTerm.desc(tbl.observedAt)]))
            .get();
    final result = <String>{};
    for (final row in rows) {
      final id = row.sourceId;
      if (id != null && id.isNotEmpty) {
        result.add(id);
      }
    }
    return result;
  }

  Stream<List<TemperatureReading>> watchTemperatureReadings(
    String thermostatId, {
    DateTime? since,
  }) {
    final query = select(temperatureReadings)
      ..where((tbl) => tbl.thermostatId.equals(thermostatId))
      ..orderBy([(tbl) => OrderingTerm.asc(tbl.observedAt)]);
    if (since != null) {
      query.where((tbl) => tbl.observedAt.isBiggerOrEqualValue(since));
    }
    return query.watch();
  }

  Future<List<TemperatureReading>> listTemperatureReadings(
    String thermostatId, {
    DateTime? since,
  }) {
    final query = select(temperatureReadings)
      ..where((tbl) => tbl.thermostatId.equals(thermostatId))
      ..orderBy([(tbl) => OrderingTerm.asc(tbl.observedAt)]);
    if (since != null) {
      query.where((tbl) => tbl.observedAt.isBiggerOrEqualValue(since));
    }
    return query.get();
  }

  // The alert config is a singleton; pin it to one canonical row id so reads
  // are deterministic and concurrent writers can't each insert a separate row.
  static const int _alertConfigRowId = 1;

  Stream<AlertConfigEntry> watchAlertConfig() {
    return (select(alertConfigEntries)
          ..orderBy([(tbl) => OrderingTerm.asc(tbl.id)])
          ..limit(1))
        .watchSingleOrNull()
        .map((entry) => entry ?? _defaultAlertConfig());
  }

  Future<AlertConfigEntry> getAlertConfig() async {
    final entry =
        await (select(alertConfigEntries)
              ..orderBy([(tbl) => OrderingTerm.asc(tbl.id)])
              ..limit(1))
            .getSingleOrNull();
    return entry ?? _defaultAlertConfig();
  }

  Future<void> updateAlertConfig(AlertConfigEntriesCompanion companion) async {
    // Atomic upsert on the single canonical row. insertOnConflictUpdate avoids
    // the old non-atomic check-then-insert, under which two connections (the UI
    // isolate and a background monitor run) could both observe "no row" on a
    // fresh install and each INSERT, producing duplicate rows and inconsistent
    // reads.
    await into(alertConfigEntries).insertOnConflictUpdate(
      companion.copyWith(id: const Value(_alertConfigRowId)),
    );
  }

  /// Records when the background monitor last started a run so overlapping
  /// triggers (the foreground service and the WorkManager watchdog) can be
  /// debounced into a single run.
  Future<void> setLastMonitorRunAt(DateTime value) async {
    await updateAlertConfig(
      AlertConfigEntriesCompanion(lastMonitorRunAt: Value(value)),
    );
  }

  Future<int> pruneTemperatureReadingsBefore(DateTime cutoff) {
    return (delete(
      temperatureReadings,
    )..where((tbl) => tbl.observedAt.isSmallerThanValue(cutoff))).go();
  }

  Future<void> pruneTemperatureReadingsExceedingLimit(
    String thermostatId,
    int keepLatest,
  ) async {
    if (keepLatest <= 0) {
      await (delete(
        temperatureReadings,
      )..where((tbl) => tbl.thermostatId.equals(thermostatId))).go();
      return;
    }

    await customStatement(
      '''
      DELETE FROM temperature_readings
      WHERE thermostat_id = ? AND id NOT IN (
        SELECT id FROM temperature_readings
        WHERE thermostat_id = ?
        ORDER BY observed_at DESC, id DESC
        LIMIT ?
      )
      ''',
      [thermostatId, thermostatId, keepLatest],
    );
  }

  AlertConfigEntry _defaultAlertConfig() {
    return AlertConfigEntry(
      id: 1,
      pollIntervalMin: 5,
      soundUri: null,
      vibrate: true,
      volumeBoost: false,
      pauseAllUntil: null,
      githubToken: null,
      lastMonitorRunAt: null,
    );
  }
}
