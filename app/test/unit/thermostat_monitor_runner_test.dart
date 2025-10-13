import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/core/background/thermostat_monitor.dart';
import 'package:farmctl/features/thermostats/data/thermostat_client.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/data/thermostat_repository.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';

class _FakeNetwork implements ThermostatNetworkDataSource {
  _FakeNetwork(this._result);

  final ThermostatFetchSuccess? _result;
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
  late _FakeNetwork network;

  setUp(() {
    database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    repository = ThermostatRepository(database);
    network = _FakeNetwork(
      ThermostatFetchSuccess(
        valueC: 21.5,
        fetchedAt: DateTime.utc(2025, 1, 1, 12),
        etag: 'etag',
      ),
    );
  });

  tearDown(() async {
    await database.close();
  });

  test('run updates state on success', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Barn',
        rawUrl: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        minC: 0,
        maxC: 20,
      ),
    );

    final runner = ThermostatMonitorRunner(
      repository: repository,
      network: network,
      clock: () => DateTime.utc(2025, 1, 1, 13),
    );

    await runner.run();

    final state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.ok);
    expect(state.lastValueC, 21.5);
    expect(state.statusMessage, 'Fetched 21.5°C');
    expect(state.etag, 'etag');
  });

  test('run records failure details', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Greenhouse',
        rawUrl: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        minC: 2,
        maxC: 12,
      ),
    );

    network._exception = const ThermostatFetchException(
      status: ThermostatReadingStatus.networkError,
      message: 'network down',
    );

    final runner = ThermostatMonitorRunner(
      repository: repository,
      network: network,
      clock: () => DateTime.utc(2025, 1, 1, 13),
    );

    await runner.run();

    final state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.networkError);
    expect(state.statusMessage, 'network down');
    expect(state.lastFetchedAt, DateTime.utc(2025, 1, 1, 13));
  });
}
