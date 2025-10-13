import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/data/thermostat_repository.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';

void main() {
  late ThermostatDatabase database;
  late ThermostatRepository repository;

  setUp(() {
    database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    repository = ThermostatRepository(database);
  });

  tearDown(() async {
    await database.close();
  });

  test('create stores and returns thermostat', () async {
    final draft = ThermostatDraft(
      name: 'Barn',
      rawUrl: 'https://example.com/barn',
      minC: 0,
      maxC: 20,
    );

    final created = await repository.create(draft);
    final stored = await repository.fetchThermostats();

    expect(created.name, draft.name);
    expect(stored, hasLength(1));
    expect(stored.first.thermostat.id, created.id);
  });

  test('update applies changes', () async {
    final original = await repository.create(
      ThermostatDraft(
        name: 'Greenhouse',
        rawUrl: 'https://example.com/greenhouse',
        minC: 4,
        maxC: 12,
      ),
    );

    final updated = await repository.update(
      original,
      ThermostatDraft(
        name: 'Greenhouse West',
        rawUrl: 'https://example.com/greenhouse-west',
        minC: 3,
        maxC: 11,
      ),
    );

    expect(updated.name, 'Greenhouse West');
    expect(updated.rawUrl, 'https://example.com/greenhouse-west');
    expect(updated.minC, 3);
    expect(updated.maxC, 11);
  });

  test('delete removes thermostat', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Propagation',
        rawUrl: 'https://example.com/propagation',
        minC: 6,
        maxC: 18,
      ),
    );

    await repository.saveState(
      thermostatId: thermostat.id,
      status: ThermostatReadingStatus.ok,
      valueC: 12.3,
      fetchedAt: DateTime.utc(2025, 1, 1, 12),
      etag: 'etag',
      message: 'Fetched 12.3°C',
    );

    await repository.delete(thermostat.id);
    final stored = await repository.fetchThermostats();

    expect(stored, isEmpty);
    final state = await repository.loadState(thermostat.id);
    expect(state, isNull);
  });

  test('create throws on invalid data', () async {
    final draft = ThermostatDraft(
      name: '',
      rawUrl: 'not a url',
      minC: 0,
      maxC: -1,
    );

    expect(
      () => repository.create(draft),
      throwsA(isA<ThermostatValidationException>()),
    );
  });

  test('saveState upserts thermostat state', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Nursery',
        rawUrl: 'https://example.com/nursery',
        minC: 5,
        maxC: 18,
      ),
    );

    await repository.saveState(
      thermostatId: thermostat.id,
      status: ThermostatReadingStatus.ok,
      valueC: 9.5,
      fetchedAt: DateTime.utc(2025, 1, 2, 8),
      etag: 'tag',
      message: 'Fetched 9.5°C',
    );

    var state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.ok);
    expect(state.lastValueC, 9.5);
    expect(state.statusMessage, 'Fetched 9.5°C');

    await repository.saveState(
      thermostatId: thermostat.id,
      status: ThermostatReadingStatus.httpError,
      valueC: null,
      fetchedAt: DateTime.utc(2025, 1, 2, 9),
      etag: null,
      message: 'Failed with status 500',
    );

    state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.httpError);
    expect(state.lastValueC, 9.5);
    expect(state.statusMessage, 'Failed with status 500');
  });
}
