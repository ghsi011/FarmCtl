import 'package:drift/drift.dart' as drift;
import 'package:uuid/uuid.dart';

import '../models/thermostat.dart';
import '../models/thermostat_state.dart';
import 'thermostat_database.dart';

final _uuid = const Uuid();

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
    await _database.deleteThermostatStateById(id);
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
        createdAt: const drift.Value.absent(),
        updatedAt: drift.Value(now),
      ),
    );
  }
}
