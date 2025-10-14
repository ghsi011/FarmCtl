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

  @override
  Future<void> showAlarm({
    required Thermostat thermostat,
    required double valueC,
    required DateTime triggeredAt,
  }) async {
    triggered.add('${thermostat.id}::$valueC');
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
}
