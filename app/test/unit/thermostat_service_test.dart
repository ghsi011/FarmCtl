import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/data/thermostat_client.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/data/thermostat_repository.dart';
import 'package:farmctl/features/thermostats/data/thermostat_service.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';

class _FakeNetworkDataSource implements ThermostatNetworkDataSource {
  _FakeNetworkDataSource(this._result);

  ThermostatFetchSuccess? _result;
  ThermostatFetchException? _exception;

  @override
  Future<ThermostatFetchSuccess> fetchCurrent(String url) async {
    if (_exception != null) {
      throw _exception!;
    }
    final result = _result;
    if (result == null) {
      throw StateError('No result configured');
    }
    return result;
  }
}

void main() {
  late ThermostatDatabase database;
  late ThermostatRepository repository;
  late _FakeNetworkDataSource network;
  late ThermostatService service;

  setUp(() {
    database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    repository = ThermostatRepository(database);
    network = _FakeNetworkDataSource(
      ThermostatFetchSuccess(
        valueC: 14.2,
        fetchedAt: DateTime.utc(2025, 1, 1, 12),
        etag: 'etag',
      ),
    );
    service = ThermostatService(repository: repository, network: network);
  });

  tearDown(() async {
    await database.close();
  });

  test('createAndTest saves thermostat and state', () async {
    final created = await service.createAndTest(
      ThermostatDraft(
        name: 'Barn',
        rawUrl: 'https://example.com/barn',
        minC: 0,
        maxC: 20,
      ),
    );

    final summaries = await repository.fetchThermostats();
    expect(summaries, hasLength(1));
    expect(summaries.first.thermostat.id, created.id);
    final state = summaries.first.state;
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.ok);
    expect(state.lastValueC, 14.2);
  });

  test('updateAndTest updates thermostat and state', () async {
    final initial = await service.createAndTest(
      ThermostatDraft(
        name: 'Greenhouse',
        rawUrl: 'https://example.com/greenhouse',
        minC: 4,
        maxC: 12,
      ),
    );

    network._result = ThermostatFetchSuccess(
      valueC: 9.0,
      fetchedAt: DateTime.utc(2025, 1, 1, 13),
      etag: 'next',
    );

    final updated = await service.updateAndTest(
      initial,
      ThermostatDraft(
        name: 'Greenhouse West',
        rawUrl: 'https://example.com/greenhouse-west',
        minC: 3,
        maxC: 11,
      ),
    );

    expect(updated.name, 'Greenhouse West');
    final state = await repository.loadState(updated.id);
    expect(state, isNotNull);
    expect(state!.lastValueC, 9.0);
  });

  test('createAndTest rethrows fetch errors', () async {
    network._exception = const ThermostatFetchException(
      status: ThermostatReadingStatus.networkError,
      message: 'network error',
    );

    expect(
      () => service.createAndTest(
        ThermostatDraft(
          name: 'Faulty',
          rawUrl: 'https://example.com/faulty',
          minC: 0,
          maxC: 10,
        ),
      ),
      throwsA(isA<ThermostatFetchException>()),
    );

    final summaries = await repository.fetchThermostats();
    expect(summaries, isEmpty);
  });
}
