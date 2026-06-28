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
  List<ThermostatHistorySample> history = const [];
  ThermostatFetchException? historyException;
  List<GistCommit> commits = const [];
  Map<String, double> revisionValues = const {};

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

  @override
  Future<List<ThermostatHistorySample>> fetchHistory(String gistId) async {
    if (historyException != null) {
      throw historyException!;
    }
    return history;
  }

  @override
  Future<List<GistCommit>> listCommits(
    String gistId, {
    int page = 1,
    int perPage = 100,
  }) async {
    return commits;
  }

  @override
  Future<double?> fetchRevisionValue(String gistId, String revisionId) async {
    return revisionValues[revisionId];
  }

  @override
  Future<String> testToken() async {
    return 'OK';
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
    expect(state.statusMessage, 'Fetched 14.20°C');
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
    expect(state.statusMessage, 'Fetched 9.00°C');
  });

  test('createAndTest rejects an invalid draft before any network call', () {
    expect(
      () => service.createAndTest(
        ThermostatDraft(name: '', rawUrl: 'short', minC: 30, maxC: 10),
      ),
      throwsA(isA<ThermostatValidationException>()),
    );
  });

  test('updateAndTest rejects an invalid draft', () async {
    final created = await service.createAndTest(
      ThermostatDraft(
        name: 'Barn',
        rawUrl: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        minC: 0,
        maxC: 20,
      ),
    );
    expect(
      () => service.updateAndTest(
        created,
        ThermostatDraft(name: '', rawUrl: 'bad', minC: 5, maxC: 1),
      ),
      throwsA(isA<ThermostatValidationException>()),
    );
  });

  test('createAndTest flags a reading above the configured range', () async {
    network._result = ThermostatFetchSuccess(
      valueC: 99.0,
      fetchedAt: DateTime.utc(2025, 1, 1, 12),
      etag: 'hot',
    );
    final created = await service.createAndTest(
      ThermostatDraft(
        name: 'Freezer',
        rawUrl: 'ffffffffffffffffffffffffffffffff',
        minC: -20,
        maxC: 0,
      ),
    );

    final state = await repository.loadState(created.id);
    expect(state!.status, ThermostatReadingStatus.outOfRange);
    expect(state.lastValueC, 99.0);
  });

  test(
    'updateAndTest keeps out-of-range when the new range excludes the value',
    () async {
      final created = await service.createAndTest(
        ThermostatDraft(
          name: 'Kiln',
          rawUrl: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
          minC: 0,
          maxC: 200,
        ),
      );
      // 14.2 is within 0..200 -> ok after create.
      expect(
        (await repository.loadState(created.id))!.status,
        ThermostatReadingStatus.ok,
      );

      // Editing to a range that excludes the (unchanged) reading must NOT clear
      // the out-of-range condition to ok.
      await service.updateAndTest(
        created,
        ThermostatDraft(
          name: 'Kiln',
          rawUrl: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
          minC: 0,
          maxC: 10,
        ),
      );

      final state = await repository.loadState(created.id);
      expect(state!.status, ThermostatReadingStatus.outOfRange);
      expect(state.statusMessage, contains('Out of range'));
    },
  );

  test(
    'createAndTest persists out-of-range when the initial value violates the range',
    () async {
      network._result = ThermostatFetchSuccess(
        valueC: 95.0,
        fetchedAt: DateTime.utc(2025, 1, 1, 12),
        etag: 'e',
      );
      final created = await service.createAndTest(
        ThermostatDraft(
          name: 'Furnace',
          rawUrl: 'ffffffffffffffffffffffffffffffff',
          minC: 0,
          maxC: 40,
        ),
      );
      final state = await repository.loadState(created.id);
      expect(state!.status, ThermostatReadingStatus.outOfRange);
    },
  );

  test('updateAndTest clears silence/snooze when back in range', () async {
    final created = await service.createAndTest(
      ThermostatDraft(
        name: 'Vent',
        rawUrl: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        minC: 10,
        maxC: 20,
      ),
    );
    // The thermostat is currently out of range, silenced and snoozed.
    await repository.saveState(
      thermostatId: created.id,
      status: ThermostatReadingStatus.outOfRange,
      valueC: 30,
      fetchedAt: DateTime.utc(2025, 1, 1, 9),
      etag: 'old',
      message: 'Out of range',
      setSilenceUntilOk: true,
      silenceUntilOk: true,
      setSnoozedUntil: true,
      snoozedUntil: DateTime.utc(2025, 1, 1, 10),
    );

    // Edit it; the test fetch (14.2) is back inside the range.
    await service.updateAndTest(
      created,
      ThermostatDraft(
        name: 'Vent',
        rawUrl: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        minC: 10,
        maxC: 20,
      ),
    );

    final state = await repository.loadState(created.id);
    expect(state!.status, ThermostatReadingStatus.ok);
    // Suppression must be cleared so a future out-of-range still alarms.
    expect(state.silenceUntilOk, isFalse);
    expect(state.snoozedUntil, isNull);
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
      expect(result.message, 'Fetched 18.40°C');
      expect(result.valueC, 18.4);

      final state = await repository.loadState(thermostat.id);
      expect(state, isNotNull);
      expect(state!.status, ThermostatReadingStatus.ok);
      expect(state.lastValueC, 18.4);
      expect(state.lastFetchedAt, result.fetchedAt);
      expect(state.statusMessage, 'Fetched 18.40°C');
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
        expect(result.message, 'Out of range: 25.20°C (10.00°C – 20.00°C)');
        expect(result.valueC, 25.2);

        final state = await repository.loadState(thermostat.id);
        expect(state, isNotNull);
        expect(state!.status, ThermostatReadingStatus.outOfRange);
        expect(state.lastValueC, 25.2);
        expect(
          state.statusMessage,
          'Out of range: 25.20°C (10.00°C – 20.00°C)',
        );
      },
    );

    test('refresh persists fetch errors with previous value', () async {
      await repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.ok,
        valueC: 15.0,
        fetchedAt: DateTime.utc(2025, 1, 3, 7),
        etag: 'etag',
        message: 'Fetched 15.00°C',
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

  test('refreshHistory persists revision samples', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'History Sensor',
        rawUrl: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        minC: 0,
        maxC: 20,
      ),
    );

    network.commits = [
      GistCommit(revisionId: 'rev1', observedAt: DateTime.utc(2025, 1, 1, 12)),
      GistCommit(revisionId: 'rev2', observedAt: DateTime.utc(2025, 1, 1, 13)),
    ];
    network.revisionValues = const {'rev1': 11.5, 'rev2': 12.0};

    await service.refreshHistory(thermostat.id);

    final samples = await repository.watchHistory(thermostat.id).first;
    expect(samples, hasLength(2));
    expect(samples.last.valueC, 12.0);
    expect(samples.first.source, 'revision');
  });
}
