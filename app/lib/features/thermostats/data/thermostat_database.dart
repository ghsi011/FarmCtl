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
  Set<Column<Object>> get primaryKey => {id};
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

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File(p.join(directory.path, 'thermostats.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}

@DriftDatabase(tables: [ThermostatEntries, AlertConfigEntries])
class ThermostatDatabase extends _$ThermostatDatabase {
  ThermostatDatabase() : super(_openConnection());

  ThermostatDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  Future<List<ThermostatEntry>> listThermostats() {
    return (select(
      thermostatEntries,
    )..orderBy([(tbl) => OrderingTerm.asc(tbl.name)])).get();
  }

  Stream<List<ThermostatEntry>> watchThermostats() {
    return (select(
      thermostatEntries,
    )..orderBy([(tbl) => OrderingTerm.asc(tbl.name)])).watch();
  }

  Future<ThermostatEntry?> getThermostat(String id) {
    return (select(
      thermostatEntries,
    )..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
  }

  Future<void> upsertThermostat(ThermostatEntriesCompanion data) async {
    await into(thermostatEntries).insertOnConflictUpdate(data);
  }

  Future<void> deleteThermostatById(String id) async {
    await (delete(thermostatEntries)..where((tbl) => tbl.id.equals(id))).go();
  }
}
