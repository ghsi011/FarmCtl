import 'package:drift/drift.dart' as drift;
import 'package:uuid/uuid.dart';

import '../models/thermostat.dart';
import 'thermostat_database.dart';

final _uuid = const Uuid();

class ThermostatRepository {
  ThermostatRepository(this._database);

  final ThermostatDatabase _database;

  Stream<List<Thermostat>> watchThermostats() {
    return _database.watchThermostats().map(
      (rows) => rows.map(Thermostat.fromEntry).toList(),
    );
  }

  Future<List<Thermostat>> fetchThermostats() async {
    final rows = await _database.listThermostats();
    return rows.map(Thermostat.fromEntry).toList();
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
    await _database.deleteThermostatById(id);
  }
}
