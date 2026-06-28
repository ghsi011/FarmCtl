import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/data/thermostat_database.dart';

void main() {
  late ThermostatDatabase db;

  setUp(() {
    db = ThermostatDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> addThermostat(String id, String name) {
    return db.upsertThermostat(
      ThermostatEntriesCompanion.insert(
        id: id,
        name: name,
        rawUrl: 'a' * 32,
        minC: 0.0,
        maxC: 20.0,
      ),
    );
  }

  test('lists, gets and deletes thermostats', () async {
    await addThermostat('t1', 'Barn');
    await addThermostat('t2', 'Coop');

    expect(await db.listThermostats(), hasLength(2));
    expect((await db.getThermostat('t1'))?.name, 'Barn');
    expect(await db.getThermostat('missing'), isNull);

    await db.deleteThermostatById('t1');
    expect(await db.listThermostats(), hasLength(1));
  });

  test('joins thermostat state in the with-state queries', () async {
    await addThermostat('t1', 'Barn');
    await db.upsertThermostatState(
      const ThermostatStateEntriesCompanion(
        thermostatId: Value('t1'),
        lastStatus: Value('ok'),
        lastValueC: Value(12.0),
      ),
    );

    final list = await db.watchThermostatsWithState().first;
    expect(list, hasLength(1));
    expect(list.first.state?.lastValueC, 12.0);

    final single = await db.watchThermostatWithState('t1').first;
    expect(single?.state?.lastStatus, 'ok');
    expect(await db.watchThermostatWithState('missing').first, isNull);
  });

  test('stores and queries temperature readings', () async {
    await addThermostat('t1', 'Barn');
    await db.insertTemperatureReadings([
      TemperatureReadingsCompanion.insert(
        id: 'r1',
        thermostatId: 't1',
        source: 'revision',
        valueC: 10,
        observedAt: DateTime.utc(2025, 1, 1, 10),
        sourceId: const Value('rev1'),
      ),
      TemperatureReadingsCompanion.insert(
        id: 'r2',
        thermostatId: 't1',
        source: 'revision',
        valueC: 11,
        observedAt: DateTime.utc(2025, 1, 1, 12),
        sourceId: const Value('rev2'),
      ),
    ]);

    expect(await db.listTemperatureReadings('t1'), hasLength(2));
    expect(
      await db.listTemperatureReadings(
        't1',
        since: DateTime.utc(2025, 1, 1, 11),
      ),
      hasLength(1),
    );
    expect(await db.watchTemperatureReadings('t1').first, hasLength(2));

    expect(
      (await db.getOldestReadingTime('t1'))?.toUtc(),
      DateTime.utc(2025, 1, 1, 10),
    );
    expect(
      (await db.getNewestReadingTime('t1'))?.toUtc(),
      DateTime.utc(2025, 1, 1, 12),
    );
    expect(
      await db.listKnownRevisionIds('t1'),
      containsAll(<String>['rev1', 'rev2']),
    );
  });

  test('prunes readings by age and per-thermostat cap', () async {
    await addThermostat('t1', 'Barn');
    await db.insertTemperatureReadings([
      for (var i = 0; i < 5; i++)
        TemperatureReadingsCompanion.insert(
          id: 'r$i',
          thermostatId: 't1',
          source: 'revision',
          valueC: i.toDouble(),
          observedAt: DateTime.utc(2025, 1, 1 + i),
        ),
    ]);

    // Remove anything before Jan 3 (drops r0 and r1).
    final removed = await db.pruneTemperatureReadingsBefore(
      DateTime.utc(2025, 1, 3),
    );
    expect(removed, 2);
    expect(await db.listTemperatureReadings('t1'), hasLength(3));

    // Cap to the latest one.
    await db.pruneTemperatureReadingsExceedingLimit('t1', 1);
    expect(await db.listTemperatureReadings('t1'), hasLength(1));

    // A non-positive keep count clears them all.
    await db.pruneTemperatureReadingsExceedingLimit('t1', 0);
    expect(await db.listTemperatureReadings('t1'), isEmpty);
  });

  test('returns the default alert config until one is written', () async {
    final initial = await db.getAlertConfig();
    expect(initial.pollIntervalMin, 5);

    await db.updateAlertConfig(
      const AlertConfigEntriesCompanion(pollIntervalMin: Value(12)),
    );
    expect((await db.getAlertConfig()).pollIntervalMin, 12);
    expect((await db.watchAlertConfig().first).pollIntervalMin, 12);
  });
}
