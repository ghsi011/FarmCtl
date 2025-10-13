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
  Object? _otherError;

  @override
  Future<ThermostatFetchSuccess> fetchCurrent(String url) async {
    final otherError = _otherError;
    if (otherError != null) {
      throw otherError;
    }
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
        rawUrl: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
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
    expect(state.statusMessage, 'Fetched 14.2°C');
  });

  test('updateAndTest updates thermostat and state', () async {
    final initial = await service.createAndTest(
      ThermostatDraft(
        name: 'Greenhouse',
        rawUrl: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
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
        rawUrl: 'cccccccccccccccccccccccccccccccc',
        minC: 3,
        maxC: 11,
      ),
    );

    expect(updated.name, 'Greenhouse West');
    final state = await repository.loadState(updated.id);
    expect(state, isNotNull);
    expect(state!.lastValueC, 9.0);
    expect(state.statusMessage, 'Fetched 9.0°C');
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
          rawUrl: 'dddddddddddddddddddddddddddddddd',
          minC: 0,
          maxC: 10,
        ),
      ),
      throwsA(isA<ThermostatFetchException>()),
    );

    final summaries = await repository.fetchThermostats();
    expect(summaries, isEmpty);
  });

  group('refresh', () {
    late Thermostat thermostat;

    setUp(() async {
      thermostat = await repository.create(
        ThermostatDraft(
          name: 'Refreshable',
          rawUrl: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
          minC: 10,
          maxC: 20,
        ),
      );
    });

    test('refresh stores latest value and clears snooze and silence', () async {
      await repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.outOfRange,
        valueC: 30,
        fetchedAt: DateTime.utc(2025, 1, 1, 9),
        etag: 'old',
        message: 'Out of range',
        snoozedUntil: DateTime.utc(2025, 1, 1, 10),
        setSnoozedUntil: true,
        silenceUntilOk: true,
        setSilenceUntilOk: true,
      );

      network._result = ThermostatFetchSuccess(
        valueC: 18.4,
        fetchedAt: DateTime.utc(2025, 1, 1, 11),
        etag: 'new',
      );

      final result = await service.refresh(thermostat);

      expect(result.status, ThermostatReadingStatus.ok);
      expect(result.message, 'Fetched 18.4°C');
      expect(result.valueC, 18.4);

      final state = await repository.loadState(thermostat.id);
      expect(state, isNotNull);
      expect(state!.status, ThermostatReadingStatus.ok);
      expect(state.lastValueC, 18.4);
      expect(state.lastFetchedAt, result.fetchedAt);
      expect(state.statusMessage, 'Fetched 18.4°C');
      expect(state.snoozedUntil, isNull);
      expect(state.silenceUntilOk, isFalse);
    });

    test(
      'refresh marks out of range when temperature outside bounds',
      () async {
        network._result = ThermostatFetchSuccess(
          valueC: 25.2,
          fetchedAt: DateTime.utc(2025, 1, 2, 12),
          etag: 'etag',
        );

        final result = await service.refresh(thermostat);

        expect(result.status, ThermostatReadingStatus.outOfRange);
        expect(result.message, 'Out of range: 25.2°C (10.0°C – 20.0°C)');
        expect(result.valueC, 25.2);

        final state = await repository.loadState(thermostat.id);
        expect(state, isNotNull);
        expect(state!.status, ThermostatReadingStatus.outOfRange);
        expect(state.lastValueC, 25.2);
        expect(state.statusMessage, 'Out of range: 25.2°C (10.0°C – 20.0°C)');
      },
    );

    test('refresh persists fetch errors with previous value', () async {
      await repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.ok,
        valueC: 15.0,
        fetchedAt: DateTime.utc(2025, 1, 3, 7),
        etag: 'etag',
        message: 'Fetched 15.0°C',
      );

      network._exception = const ThermostatFetchException(
        status: ThermostatReadingStatus.networkError,
        message: 'Network down',
      );

      final result = await service.refresh(thermostat);

      expect(result.status, ThermostatReadingStatus.networkError);
      expect(result.message, 'Network down');
      expect(result.valueC, 15.0);

      final state = await repository.loadState(thermostat.id);
      expect(state, isNotNull);
      expect(state!.status, ThermostatReadingStatus.networkError);
      expect(state.lastValueC, 15.0);
      expect(state.statusMessage, 'Network down');
      final persistedFetchedAt = state.lastFetchedAt;
      expect(persistedFetchedAt, isNotNull);
      expect(
        persistedFetchedAt!.difference(result.fetchedAt).inMilliseconds.abs(),
        lessThan(1000),
      );
    });

    test('refresh guards against unexpected errors', () async {
      network._otherError = Exception('boom');

      final result = await service.refresh(thermostat);

      expect(result.status, ThermostatReadingStatus.unknown);
      expect(result.message, 'Unexpected error: Exception: boom');
      expect(result.valueC, isNull);

      final state = await repository.loadState(thermostat.id);
      expect(state, isNotNull);
      expect(state!.status, ThermostatReadingStatus.unknown);
      expect(state.lastValueC, isNull);
      expect(state.statusMessage, 'Unexpected error: Exception: boom');
      final persistedFetchedAt = state.lastFetchedAt;
      expect(persistedFetchedAt, isNotNull);
      expect(
        persistedFetchedAt!.difference(result.fetchedAt).inMilliseconds.abs(),
        lessThan(1000),
      );
    });
  });
}
