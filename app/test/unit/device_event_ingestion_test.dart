import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/data/thermostat_repository.dart';
import 'package:farmctl/features/thermostats/models/device_diagnostics.dart';

void main() {
  late ThermostatDatabase database;
  late ThermostatRepository repository;
  final now = DateTime.utc(2026, 9, 26, 12);

  setUp(() async {
    database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    repository = ThermostatRepository(database);
    await database.upsertThermostat(
      ThermostatEntriesCompanion.insert(
        id: 't1',
        name: 'Barn',
        rawUrl: 'a' * 32,
        minC: 0,
        maxC: 20,
        deviceRef: const Value('device-1'),
      ),
    );
  });

  tearDown(() => database.close());

  DeviceDiagnosticsSnapshot snapshot({
    required DateTime fetchedAt,
    DateTime? gistUpdatedAt,
    required List<DeviceDiagnosticsEvent> events,
  }) => DeviceDiagnosticsSnapshot(
    deviceRef: 'device-1',
    firmwareRunning: '1.2.3',
    sensorState: 'error',
    consecutiveFailures: 2,
    heartbeatSeq: 3,
    fetchedAt: fetchedAt,
    gistUpdatedAt: gistUpdatedAt,
    events: events,
  );

  test(
    'retained event IDs deduplicate across boots while distinct origins remain distinct',
    () async {
      final first = snapshot(
        fetchedAt: now,
        gistUpdatedAt: now.subtract(const Duration(minutes: 1)),
        events: const [
          DeviceDiagnosticsEvent(
            id: 'boot-opaque:4',
            code: 'sensor_failed',
            count: 1,
            uptimeSeconds: 42,
          ),
        ],
      );
      await repository.ingestDeviceEvents(
        thermostatId: 't1',
        snapshot: first,
        now: now,
      );
      await repository.ingestDeviceEvents(
        thermostatId: 't1',
        snapshot: first,
        now: now,
      );
      await repository.ingestDeviceEvents(
        thermostatId: 't1',
        snapshot: snapshot(
          fetchedAt: now.add(const Duration(minutes: 5)),
          gistUpdatedAt: now.add(const Duration(minutes: 4)),
          events: const [
            DeviceDiagnosticsEvent(
              id: 'boot-opaque:4',
              code: 'sensor_failed',
              count: 8,
              uptimeSeconds: 42,
            ),
            DeviceDiagnosticsEvent(
              id: 'different-origin:1',
              code: 'sensor_recovered',
              count: 1,
            ),
          ],
        ),
        now: now.add(const Duration(minutes: 5)),
      );

      final rows = await repository.loadDeviceEvents('device-1');
      expect(rows, hasLength(2));
      final retainedEvent = rows.singleWhere(
        (row) => row.eventId == 'boot-opaque:4',
      );
      expect(retainedEvent.count, 8);
      expect(
        retainedEvent.gistUpdatedAt!.toUtc(),
        now.add(const Duration(minutes: 4)),
      );
      expect(
        retainedEvent.fetchedAt.toUtc(),
        now.add(const Duration(minutes: 5)),
      );
      expect(retainedEvent.occurredAt, isNull); // no fabricated wall-clock time
    },
  );

  test(
    'older publication fetched later cannot regress event metadata',
    () async {
      final occurredAtT2 = now.subtract(const Duration(hours: 2));
      final occurredAtT1 = now.subtract(const Duration(hours: 3));
      await repository.ingestDeviceEvents(
        thermostatId: 't1',
        snapshot: snapshot(
          fetchedAt: now,
          gistUpdatedAt: now.subtract(const Duration(minutes: 1)),
          events: [
            DeviceDiagnosticsEvent(
              id: 'origin-a:2',
              code: 'sensor_failed',
              count: 4,
              occurredAt: occurredAtT2,
              uptimeSeconds: 200,
            ),
          ],
        ),
        now: now,
      );
      await repository.ingestDeviceEvents(
        thermostatId: 't1',
        snapshot: snapshot(
          fetchedAt: now.add(const Duration(minutes: 10)),
          gistUpdatedAt: now.subtract(const Duration(minutes: 5)),
          events: [
            DeviceDiagnosticsEvent(
              id: 'origin-a:2',
              code: 'sensor_recovered',
              count: 9,
              occurredAt: occurredAtT1,
              uptimeSeconds: 100,
            ),
          ],
        ),
        now: now.add(const Duration(minutes: 10)),
      );

      final row = (await repository.loadDeviceEvents(
        'device-1',
        now: now,
      )).single;
      expect(row.code, 'sensor_failed');
      expect(row.count, 9);
      expect(row.occurredAt!.toUtc(), occurredAtT2);
      expect(row.uptimeSeconds, 200);
      expect(
        row.gistUpdatedAt!.toUtc(),
        now.subtract(const Duration(minutes: 1)),
      );
      expect(row.fetchedAt.toUtc(), now);
    },
  );

  test(
    'mismatched immutable device ref is ignored; events do not touch readings or alarm state',
    () async {
      await database.upsertThermostatState(
        ThermostatStateEntriesCompanion.insert(
          thermostatId: 't1',
          lastStatus: const Value('outOfRange'),
          lastValueC: const Value(30),
          lastFetchedAt: Value(now),
          dataUpdatedAt: Value(now.subtract(const Duration(hours: 1))),
          lastAlarmAt: Value(now.subtract(const Duration(minutes: 2))),
        ),
      );
      await database.insertTemperatureReadings([
        TemperatureReadingsCompanion.insert(
          id: 'r1',
          thermostatId: 't1',
          source: 'revision',
          valueC: 30,
          observedAt: now,
        ),
      ]);
      final wrong = DeviceDiagnosticsSnapshot(
        deviceRef: 'wrong-device',
        firmwareRunning: '1',
        sensorState: 'ok',
        consecutiveFailures: 0,
        heartbeatSeq: 1,
        fetchedAt: now,
        gistUpdatedAt: null,
        events: const [
          DeviceDiagnosticsEvent(id: '1', code: 'sensor_failed', count: 1),
        ],
      );
      await repository.ingestDeviceEvents(
        thermostatId: 't1',
        snapshot: wrong,
        now: now,
      );
      final state = await database.getThermostatState('t1');
      expect(await repository.loadDeviceEvents('wrong-device'), isEmpty);
      expect(state!.lastStatus, 'outOfRange');
      expect(
        state.lastAlarmAt!.toUtc(),
        now.subtract(const Duration(minutes: 2)),
      );
      expect(
        state.dataUpdatedAt!.toUtc(),
        now.subtract(const Duration(hours: 1)),
      );
      expect(await database.listTemperatureReadings('t1'), hasLength(1));
    },
  );

  test(
    'history access prunes expired events without another diagnostics fetch',
    () async {
      final event = snapshot(
        fetchedAt: now,
        events: const [
          DeviceDiagnosticsEvent(id: 'old', code: 'sensor_failed', count: 1),
        ],
      );
      await repository.ingestDeviceEvents(
        thermostatId: 't1',
        snapshot: event,
        now: now,
      );
      final day31 = now.add(const Duration(days: 31));
      expect(
        await repository.loadDeviceEvents('device-1', now: day31),
        isEmpty,
      );
      expect(await database.select(database.deviceEvents).get(), isEmpty);
    },
  );
}
