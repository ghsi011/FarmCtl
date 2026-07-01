import 'package:drift/drift.dart' as drift;
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

  ThermostatFetchSuccess? _result;
  ThermostatFetchException? _exception;
  List<GistCommit> commits = const [];

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

  @override
  Future<List<ThermostatHistorySample>> fetchHistory(String gistId) async {
    return const [];
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
    return null;
  }

  @override
  Future<String> testToken() async {
    return 'OK';
  }
}

class _RecordingAlarmDispatcher implements ThermostatAlarmDispatcher {
  final List<String> triggered = [];
  final List<String> staleTriggered = [];

  @override
  Future<void> showAlarm({
    required Thermostat thermostat,
    required double valueC,
    required DateTime triggeredAt,
  }) async {
    triggered.add('${thermostat.id}::$valueC');
  }

  @override
  Future<void> showStaleDataAlarm({
    required Thermostat thermostat,
    required DateTime dataUpdatedAt,
    required DateTime triggeredAt,
  }) async {
    staleTriggered.add('${thermostat.id}::${dataUpdatedAt.toIso8601String()}');
  }
}

void main() {
  late ThermostatDatabase database;
  late ThermostatRepository repository;
  late _FakeNetwork network;
  late _RecordingAlarmDispatcher alarms;

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
    alarms = _RecordingAlarmDispatcher();
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
        maxC: 30,
      ),
    );

    final runner = ThermostatMonitorRunner(
      repository: repository,
      network: network,
      alarmDispatcher: alarms,
      clock: () => DateTime.utc(2025, 1, 1, 13),
    );

    await runner.run();

    final state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.ok);
    expect(state.lastValueC, 21.5);
    expect(state.statusMessage, 'Fetched 21.50°C');
    expect(state.etag, 'etag');
    expect(alarms.triggered, isEmpty);
  });

  test('run marks thermostat out of range and triggers alarm', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Greenhouse',
        rawUrl: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        minC: 0,
        maxC: 20,
      ),
    );

    network._result = ThermostatFetchSuccess(
      valueC: 25.2,
      fetchedAt: DateTime.utc(2025, 1, 1, 12, 15),
      etag: 'etag-2',
    );

    final runner = ThermostatMonitorRunner(
      repository: repository,
      network: network,
      alarmDispatcher: alarms,
      clock: () => DateTime.utc(2025, 1, 1, 12, 16),
    );

    await runner.run();

    final state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.outOfRange);
    expect(state.statusMessage, 'Out of range: 25.20°C (0.00°C – 20.00°C)');
    expect(state.lastAlarmAt, DateTime.utc(2025, 1, 1, 12, 16));
    expect(alarms.triggered, contains('${thermostat.id}::25.2'));
  });

  test('run records failure details', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Greenhouse East',
        rawUrl: 'cccccccccccccccccccccccccccccccc',
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
      alarmDispatcher: alarms,
      clock: () => DateTime.utc(2025, 1, 1, 13),
    );

    await runner.run();

    final state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.networkError);
    expect(state.statusMessage, 'network down');
    expect(state.lastFetchedAt, DateTime.utc(2025, 1, 1, 13));
    expect(alarms.triggered, isEmpty);
  });

  test(
    'run clears narrow-range hysteresis alarm when value returns in range',
    () async {
      final thermostat = await repository.create(
        ThermostatDraft(
          name: 'Nursery',
          rawUrl: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
          minC: 19,
          maxC: 20,
        ),
      );

      await database.upsertThermostat(
        ThermostatEntriesCompanion(
          id: drift.Value(thermostat.id),
          name: drift.Value(thermostat.name),
          rawUrl: drift.Value(thermostat.rawUrl),
          minC: drift.Value(thermostat.minC),
          maxC: drift.Value(thermostat.maxC),
          hysteresisEnabled: const drift.Value(true),
          monitoringEnabled: drift.Value(thermostat.monitoringEnabled),
          createdAt: drift.Value(thermostat.createdAt),
          updatedAt: drift.Value(thermostat.updatedAt),
        ),
      );

      await repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.outOfRange,
        valueC: 21,
        fetchedAt: DateTime.utc(2025, 1, 1, 11, 55),
        etag: 'etag',
        message: 'Out of range',
      );

      network._result = ThermostatFetchSuccess(
        valueC: 19.6,
        fetchedAt: DateTime.utc(2025, 1, 1, 12),
        etag: 'etag-2',
      );

      final runner = ThermostatMonitorRunner(
        repository: repository,
        network: network,
        alarmDispatcher: alarms,
        clock: () => DateTime.utc(2025, 1, 1, 12, 1),
      );

      await runner.run();

      final state = await repository.loadState(thermostat.id);
      expect(state, isNotNull);
      expect(state!.status, ThermostatReadingStatus.ok);
      expect(state.lastValueC, 19.6);
      expect(state.statusMessage, 'Fetched 19.60°C');
      expect(alarms.triggered, isEmpty);
    },
  );

  test('run respects snooze window', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Propagation',
        rawUrl: 'dddddddddddddddddddddddddddddddd',
        minC: 10,
        maxC: 20,
      ),
    );

    final now = DateTime.utc(2025, 1, 1, 12);
    await repository.saveState(
      thermostatId: thermostat.id,
      status: ThermostatReadingStatus.outOfRange,
      valueC: 5,
      fetchedAt: now.subtract(const Duration(minutes: 10)),
      etag: 'etag',
      message: 'Out of range',
      lastAlarmAt: now.subtract(const Duration(minutes: 1)),
      setLastAlarmAt: true,
      setSnoozedUntil: true,
      snoozedUntil: now.add(const Duration(minutes: 4)),
    );

    network._result = ThermostatFetchSuccess(
      valueC: 4.5,
      fetchedAt: now,
      etag: 'etag-3',
    );

    final runner = ThermostatMonitorRunner(
      repository: repository,
      network: network,
      alarmDispatcher: alarms,
      clock: () => now,
    );

    await runner.run();

    final state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.outOfRange);
    expect(state.lastAlarmAt, now.subtract(const Duration(minutes: 1)));
    expect(state.snoozedUntil, now.add(const Duration(minutes: 4)));
    expect(alarms.triggered, isEmpty);
  });

  test('run suppresses alarm while silenced until OK', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Silo',
        rawUrl: 'ffffffffffffffffffffffffffffffff',
        minC: 10,
        maxC: 20,
      ),
    );

    final now = DateTime.utc(2025, 1, 1, 12);
    await repository.saveState(
      thermostatId: thermostat.id,
      status: ThermostatReadingStatus.outOfRange,
      valueC: 5,
      fetchedAt: now.subtract(const Duration(minutes: 10)),
      etag: 'etag',
      message: 'Out of range',
      setSilenceUntilOk: true,
      silenceUntilOk: true,
    );

    network._result = ThermostatFetchSuccess(
      valueC: 4,
      fetchedAt: now,
      etag: 'etag-silence',
    );

    final runner = ThermostatMonitorRunner(
      repository: repository,
      network: network,
      alarmDispatcher: alarms,
      clock: () => now,
    );

    await runner.run();

    final state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.outOfRange);
    expect(state.silenceUntilOk, isTrue);
    expect(alarms.triggered, isEmpty);
  });

  test('run honours the rate limit just under five minutes', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Coop',
        rawUrl: '11111111111111111111111111111111',
        minC: 10,
        maxC: 20,
      ),
    );

    final now = DateTime.utc(2025, 1, 1, 12);
    await repository.saveState(
      thermostatId: thermostat.id,
      status: ThermostatReadingStatus.outOfRange,
      valueC: 5,
      fetchedAt: now.subtract(const Duration(minutes: 4)),
      etag: 'etag',
      message: 'Out of range',
      lastAlarmAt: now.subtract(const Duration(minutes: 4)),
      setLastAlarmAt: true,
    );

    network._result = ThermostatFetchSuccess(
      valueC: 4,
      fetchedAt: now,
      etag: 'etag-rl',
    );

    final runner = ThermostatMonitorRunner(
      repository: repository,
      network: network,
      alarmDispatcher: alarms,
      clock: () => now,
    );

    await runner.run();

    final state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.outOfRange);
    // Unchanged: no new alarm within the rate-limit window.
    expect(state.lastAlarmAt, now.subtract(const Duration(minutes: 4)));
    expect(alarms.triggered, isEmpty);
  });

  test('run re-alarms once the rate limit has elapsed', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Coop East',
        rawUrl: '22222222222222222222222222222222',
        minC: 10,
        maxC: 20,
      ),
    );

    final now = DateTime.utc(2025, 1, 1, 12);
    await repository.saveState(
      thermostatId: thermostat.id,
      status: ThermostatReadingStatus.outOfRange,
      valueC: 5,
      fetchedAt: now.subtract(const Duration(minutes: 6)),
      etag: 'etag',
      message: 'Out of range',
      lastAlarmAt: now.subtract(const Duration(minutes: 6)),
      setLastAlarmAt: true,
    );

    network._result = ThermostatFetchSuccess(
      valueC: 4,
      fetchedAt: now,
      etag: 'etag-rl2',
    );

    final runner = ThermostatMonitorRunner(
      repository: repository,
      network: network,
      alarmDispatcher: alarms,
      clock: () => now,
    );

    await runner.run();

    final state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.outOfRange);
    expect(state.lastAlarmAt, now);
    expect(alarms.triggered, contains('${thermostat.id}::4.0'));
  });

  test('run re-alarms after an expired snooze and clears it', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Hutch',
        rawUrl: '33333333333333333333333333333333',
        minC: 10,
        maxC: 20,
      ),
    );

    final now = DateTime.utc(2025, 1, 1, 12);
    await repository.saveState(
      thermostatId: thermostat.id,
      status: ThermostatReadingStatus.outOfRange,
      valueC: 5,
      fetchedAt: now.subtract(const Duration(minutes: 10)),
      etag: 'etag',
      message: 'Out of range',
      lastAlarmAt: now.subtract(const Duration(minutes: 10)),
      setLastAlarmAt: true,
      snoozedUntil: now.subtract(const Duration(minutes: 1)),
      setSnoozedUntil: true,
    );

    network._result = ThermostatFetchSuccess(
      valueC: 4,
      fetchedAt: now,
      etag: 'etag-snooze',
    );

    final runner = ThermostatMonitorRunner(
      repository: repository,
      network: network,
      alarmDispatcher: alarms,
      clock: () => now,
    );

    await runner.run();

    final state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.outOfRange);
    expect(state.lastAlarmAt, now);
    expect(state.snoozedUntil, isNull);
    expect(alarms.triggered, contains('${thermostat.id}::4.0'));
  });

  group('stale data (dead sensor) detection', () {
    // Poll interval 5 min -> threshold max(15 min, 15 min) = 15 minutes.
    const pollInterval = Duration(minutes: 5);
    final now = DateTime.utc(2025, 1, 1, 12);

    Future<Thermostat> createThermostat() {
      return repository.create(
        ThermostatDraft(
          name: 'Silent Barn',
          rawUrl: '44444444444444444444444444444444',
          minC: 10,
          maxC: 20,
        ),
      );
    }

    ThermostatMonitorRunner buildRunner() {
      return ThermostatMonitorRunner(
        repository: repository,
        network: network,
        alarmDispatcher: alarms,
        pollInterval: pollInterval,
        clock: () => now,
      );
    }

    test('stale data raises a stale alarm with a clear message', () async {
      final thermostat = await createThermostat();
      // In-range value, but the gist content is 61 minutes old.
      final dataUpdatedAt = now.subtract(const Duration(minutes: 61));
      network._result = ThermostatFetchSuccess(
        valueC: 15,
        fetchedAt: now,
        dataUpdatedAt: dataUpdatedAt,
        etag: 'etag-stale',
      );

      await buildRunner().run();

      final state = await repository.loadState(thermostat.id);
      expect(state, isNotNull);
      expect(state!.status, ThermostatReadingStatus.stale);
      expect(state.dataUpdatedAt, dataUpdatedAt);
      expect(state.lastAlarmAt, now);
      expect(
        state.statusMessage,
        'No new data since 2025-01-01 10:59 UTC — sensor may be offline',
      );
      expect(
        alarms.staleTriggered,
        contains('${thermostat.id}::${dataUpdatedAt.toIso8601String()}'),
      );
      // The out-of-range alarm path must not fire for stale data.
      expect(alarms.triggered, isEmpty);
    });

    test('stale data respects an active snooze', () async {
      final thermostat = await createThermostat();
      await repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.stale,
        valueC: 15,
        fetchedAt: now.subtract(const Duration(minutes: 10)),
        message: 'stale',
        setSnoozedUntil: true,
        snoozedUntil: now.add(const Duration(minutes: 4)),
      );
      network._result = ThermostatFetchSuccess(
        valueC: 15,
        fetchedAt: now,
        dataUpdatedAt: now.subtract(const Duration(hours: 2)),
        etag: 'etag-snoozed',
      );

      await buildRunner().run();

      final state = await repository.loadState(thermostat.id);
      expect(state!.status, ThermostatReadingStatus.stale);
      expect(state.snoozedUntil, now.add(const Duration(minutes: 4)));
      expect(alarms.staleTriggered, isEmpty);
      expect(alarms.triggered, isEmpty);
    });

    test('stale data does not re-fire within the rate limit', () async {
      final thermostat = await createThermostat();
      await repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.stale,
        valueC: 15,
        fetchedAt: now.subtract(const Duration(minutes: 4)),
        message: 'stale',
        lastAlarmAt: now.subtract(const Duration(minutes: 4)),
        setLastAlarmAt: true,
      );
      network._result = ThermostatFetchSuccess(
        valueC: 15,
        fetchedAt: now,
        dataUpdatedAt: now.subtract(const Duration(hours: 2)),
        etag: 'etag-rl',
      );

      await buildRunner().run();

      final state = await repository.loadState(thermostat.id);
      expect(state!.status, ThermostatReadingStatus.stale);
      // Unchanged: no new alarm within the rate-limit window.
      expect(state.lastAlarmAt, now.subtract(const Duration(minutes: 4)));
      expect(alarms.staleTriggered, isEmpty);
    });

    test('stale data re-fires once the rate limit has elapsed', () async {
      final thermostat = await createThermostat();
      await repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.stale,
        valueC: 15,
        fetchedAt: now.subtract(const Duration(minutes: 6)),
        message: 'stale',
        lastAlarmAt: now.subtract(const Duration(minutes: 6)),
        setLastAlarmAt: true,
      );
      network._result = ThermostatFetchSuccess(
        valueC: 15,
        fetchedAt: now,
        dataUpdatedAt: now.subtract(const Duration(hours: 2)),
        etag: 'etag-rl2',
      );

      await buildRunner().run();

      final state = await repository.loadState(thermostat.id);
      expect(state!.status, ThermostatReadingStatus.stale);
      expect(state.lastAlarmAt, now);
      expect(alarms.staleTriggered, hasLength(1));
    });

    test('fresh data stays OK and does not alarm', () async {
      final thermostat = await createThermostat();
      final dataUpdatedAt = now.subtract(const Duration(minutes: 3));
      network._result = ThermostatFetchSuccess(
        valueC: 15,
        fetchedAt: now,
        dataUpdatedAt: dataUpdatedAt,
        etag: 'etag-fresh',
      );

      await buildRunner().run();

      final state = await repository.loadState(thermostat.id);
      expect(state!.status, ThermostatReadingStatus.ok);
      expect(state.dataUpdatedAt, dataUpdatedAt);
      expect(alarms.staleTriggered, isEmpty);
      expect(alarms.triggered, isEmpty);
    });

    test('a reading without updated_at is never treated as stale', () async {
      final thermostat = await createThermostat();
      network._result = ThermostatFetchSuccess(
        valueC: 15,
        fetchedAt: now,
        etag: 'etag-no-ts',
      );

      await buildRunner().run();

      final state = await repository.loadState(thermostat.id);
      expect(state!.status, ThermostatReadingStatus.ok);
      expect(state.dataUpdatedAt, isNull);
      expect(alarms.staleTriggered, isEmpty);
    });

    test('an out-of-range stale reading alarms as out-of-range', () async {
      final thermostat = await createThermostat();
      network._result = ThermostatFetchSuccess(
        valueC: 99,
        fetchedAt: now,
        dataUpdatedAt: now.subtract(const Duration(hours: 2)),
        etag: 'etag-oor',
      );

      await buildRunner().run();

      final state = await repository.loadState(thermostat.id);
      // Out-of-range wins: the temperature itself is the louder problem.
      expect(state!.status, ThermostatReadingStatus.outOfRange);
      expect(state.dataUpdatedAt, now.subtract(const Duration(hours: 2)));
      expect(alarms.triggered, contains('${thermostat.id}::99.0'));
      expect(alarms.staleTriggered, isEmpty);
    });

    test('recovered data clears a stale status back to OK', () async {
      final thermostat = await createThermostat();
      await repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.stale,
        valueC: 15,
        fetchedAt: now.subtract(const Duration(minutes: 10)),
        message: 'stale',
        setSilenceUntilOk: true,
        silenceUntilOk: true,
      );
      network._result = ThermostatFetchSuccess(
        valueC: 15,
        fetchedAt: now,
        dataUpdatedAt: now.subtract(const Duration(minutes: 2)),
        etag: 'etag-recovered',
      );

      await buildRunner().run();

      final state = await repository.loadState(thermostat.id);
      expect(state!.status, ThermostatReadingStatus.ok);
      // Recovery clears "silence until OK", like any OK reading.
      expect(state.silenceUntilOk, isFalse);
      expect(alarms.staleTriggered, isEmpty);
    });
  });

  test(
    'run does not poll or alarm a thermostat with monitoring disabled',
    () async {
      final thermostat = await repository.create(
        ThermostatDraft(
          name: 'Disabled',
          rawUrl: '99999999999999999999999999999999',
          minC: 0,
          maxC: 20,
        ),
      );
      // Turn monitoring off for this thermostat.
      await database.upsertThermostat(
        ThermostatEntriesCompanion(
          id: drift.Value(thermostat.id),
          name: drift.Value(thermostat.name),
          rawUrl: drift.Value(thermostat.rawUrl),
          minC: drift.Value(thermostat.minC),
          maxC: drift.Value(thermostat.maxC),
          monitoringEnabled: const drift.Value(false),
          createdAt: drift.Value(thermostat.createdAt),
          updatedAt: drift.Value(thermostat.updatedAt),
        ),
      );

      // An out-of-range value that WOULD alarm if the thermostat were monitored.
      network._result = ThermostatFetchSuccess(
        valueC: 99,
        fetchedAt: DateTime.utc(2025, 1, 1, 12),
        etag: 'etag-disabled',
      );

      final runner = ThermostatMonitorRunner(
        repository: repository,
        network: network,
        alarmDispatcher: alarms,
        clock: () => DateTime.utc(2025, 1, 1, 12),
      );

      await runner.run();

      // It is skipped entirely: no reading is fetched/persisted and no alarm fires.
      expect(await repository.loadState(thermostat.id), isNull);
      expect(alarms.triggered, isEmpty);
    },
  );
}
