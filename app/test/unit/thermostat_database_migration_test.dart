import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/data/thermostat_database.dart';

/// Migration tests. A v7 database is built by Drift, then mutated with raw SQL
/// to simulate an older on-disk schema (dropping the columns/tables added in
/// later versions and rewinding `user_version`). Re-opening then runs the real
/// `onUpgrade` path, which we assert leaves a working schema with data intact.
void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('farmctl_migration');
    dbFile = File('${tempDir.path}/thermostats.sqlite');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  ThermostatDatabase openDb() =>
      ThermostatDatabase.forTesting(NativeDatabase(dbFile));

  Future<void> seedThermostat(ThermostatDatabase db, String id) async {
    await db.upsertThermostat(
      ThermostatEntriesCompanion.insert(
        id: id,
        name: 'Barn',
        rawUrl: 'a' * 32,
        minC: 0,
        maxC: 20,
      ),
    );
  }

  test(
    'upgrades from v6 to v7, adding last_monitor_run_at and keeping data',
    () async {
      // Build the current (v7) schema and seed representative data.
      final db = openDb();
      await seedThermostat(db, 't1');
      await db.updateAlertConfig(
        const AlertConfigEntriesCompanion(githubToken: Value('ghp_seed')),
      );
      await db.upsertThermostatState(
        const ThermostatStateEntriesCompanion(
          thermostatId: Value('t1'),
          lastStatus: Value('ok'),
          lastValueC: Value(12.0),
        ),
      );
      await db.insertTemperatureReadings([
        TemperatureReadingsCompanion.insert(
          id: 'r1',
          thermostatId: 't1',
          source: 'revision',
          valueC: 12.0,
          observedAt: DateTime.utc(2025, 1, 1),
          sourceId: const Value('rev1'),
        ),
      ]);

      // Simulate a v6 on-disk schema: drop the v7 column and rewind the version.
      await db.customStatement(
        'ALTER TABLE alert_config_entries DROP COLUMN last_monitor_run_at',
      );
      await db.customStatement('PRAGMA user_version = 6');
      await db.close();

      // Re-open: the real onUpgrade(6 -> 7) should run.
      final upgraded = openDb();
      final config = await upgraded.getAlertConfig();
      expect(
        config.githubToken,
        'ghp_seed',
        reason: 'data must survive upgrade',
      );
      expect(
        config.lastMonitorRunAt,
        isNull,
        reason: 'new column defaults null',
      );

      // The re-added column must be writable.
      await upgraded.setLastMonitorRunAt(DateTime.utc(2025, 6, 27, 12));
      expect((await upgraded.getAlertConfig()).lastMonitorRunAt, isNotNull);

      expect(await upgraded.listThermostats(), hasLength(1));
      expect(await upgraded.listTemperatureReadings('t1'), hasLength(1));
      await upgraded.close();
    },
  );

  test('upgrades from v1 to latest without duplicate-column errors', () async {
    // Build the latest schema, seed a thermostat, then strip everything after v1.
    final db = openDb();
    await seedThermostat(db, 't1');
    await db.customStatement('DROP TABLE temperature_readings');
    await db.customStatement('DROP TABLE thermostat_state_entries');
    await db.customStatement(
      'ALTER TABLE alert_config_entries DROP COLUMN last_monitor_run_at',
    );
    await db.customStatement(
      'ALTER TABLE alert_config_entries DROP COLUMN github_token',
    );
    await db.customStatement('PRAGMA user_version = 1');
    await db.close();

    // Re-open: onUpgrade(1 -> 7) must run every step. Before the createTable/
    // addColumn ordering fix this threw a duplicate-column error on v3.
    final upgraded = openDb();

    // A successful query proves the whole migration chain ran.
    final config = await upgraded.getAlertConfig();
    expect(config.pollIntervalMin, 5);
    expect(config.githubToken, isNull);
    expect(config.lastMonitorRunAt, isNull);

    // The recreated state table has all current columns (write + read back).
    await upgraded.upsertThermostatState(
      const ThermostatStateEntriesCompanion(
        thermostatId: Value('t1'),
        lastStatus: Value('outOfRange'),
        lastAlarmAt: Value.absent(),
        silenceUntilOk: Value(true),
      ),
    );
    final state = await upgraded.getThermostatState('t1');
    expect(state, isNotNull);
    expect(state!.silenceUntilOk, isTrue);

    expect(await upgraded.listThermostats(), hasLength(1));
    await upgraded.close();
  });

  test('upgrades v7 -> v8, consolidating duplicate alert_config rows', () async {
    final db = openDb();
    // Simulate the pre-fix duplicate-row state. id=1 is the LIVE row the app
    // reads/writes (poll=5, exact alarms off, token already migrated to secure
    // storage so the plaintext column is null); id=2 is a frozen leftover that
    // still holds an old plaintext token and stale settings. Then rewind to v7.
    await db.customStatement(
      'INSERT INTO alert_config_entries '
      '(id, poll_interval_min, exact_alarms_enabled, sound_uri, vibrate, '
      'volume_boost, pause_all_until, github_token, last_monitor_run_at) '
      'VALUES (1, 5, 0, NULL, 1, 0, NULL, NULL, NULL)',
    );
    await db.customStatement(
      'INSERT INTO alert_config_entries '
      '(id, poll_interval_min, exact_alarms_enabled, sound_uri, vibrate, '
      'volume_boost, pause_all_until, github_token, last_monitor_run_at) '
      "VALUES (2, 9, 1, NULL, 1, 0, NULL, 'ghp_seed', NULL)",
    );
    await db.customStatement('PRAGMA user_version = 7');
    await db.close();

    // Re-open: onUpgrade(7 -> 8) collapses to a single row, keeping the LIVE
    // (lowest-id) row's settings and merging the duplicate's token forward.
    final upgraded = openDb();
    final rows = await upgraded.select(upgraded.alertConfigEntries).get();
    expect(rows, hasLength(1));
    final config = await upgraded.getAlertConfig();
    // Live settings survive (NOT the stale id=2 values 9 / true)...
    expect(config.pollIntervalMin, 5);
    expect(config.exactAlarmsEnabled, isFalse);
    // ...and the only token (from the duplicate) is forward-filled.
    expect(config.githubToken, 'ghp_seed');
    await upgraded.close();
  });
}
