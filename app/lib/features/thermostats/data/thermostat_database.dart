import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'thermostat_database.g.dart';

class ThermostatEntries extends Table {
  TextColumn get id => text()();

  TextColumn get name => text().withLength(min: 1, max: 40)();

  TextColumn get rawUrl => text()();

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

  BoolColumn get exactAlarmsEnabled =>
      boolean().withDefault(const Constant(false))();

  TextColumn get soundUri => text().nullable()();

  BoolColumn get vibrate => boolean().withDefault(const Constant(true))();

  BoolColumn get volumeBoost => boolean().withDefault(const Constant(false))();

  DateTimeColumn get pauseAllUntil => dateTime().nullable()();
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

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File(p.join(directory.path, 'thermostats.sqlite'));
    return NativeDatabase.createInBackground(file);
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
  ],
)
class ThermostatDatabase extends _$ThermostatDatabase {
  ThermostatDatabase() : super(_openConnection());

  ThermostatDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      if (from < 2) {
        await m.createTable(thermostatStateEntries);
      }
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
      if (from < 5) {
        await m.createTable(temperatureReadings);
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
      query.where((tbl) => tbl.observedAt.isBiggerThanValue(since));
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
      query.where((tbl) => tbl.observedAt.isBiggerThanValue(since));
    }
    return query.get();
  }

  Stream<AlertConfigEntry> watchAlertConfig() {
    return (select(alertConfigEntries)..limit(1)).watchSingleOrNull().map(
      (entry) => entry ?? _defaultAlertConfig(),
    );
  }

  Future<AlertConfigEntry> getAlertConfig() async {
    final entry = await (select(
      alertConfigEntries,
    )..limit(1)).getSingleOrNull();
    return entry ?? _defaultAlertConfig();
  }

  Future<void> updateAlertConfig(AlertConfigEntriesCompanion companion) async {
    final existing = await (select(
      alertConfigEntries,
    )..limit(1)).getSingleOrNull();
    if (existing == null) {
      await into(alertConfigEntries).insert(companion);
    } else {
      await (update(
        alertConfigEntries,
      )..where((tbl) => tbl.id.equals(existing.id))).write(companion);
    }
  }

  AlertConfigEntry _defaultAlertConfig() {
    return AlertConfigEntry(
      id: 1,
      pollIntervalMin: 5,
      exactAlarmsEnabled: false,
      soundUri: null,
      vibrate: true,
      volumeBoost: false,
      pauseAllUntil: null,
    );
  }
}
