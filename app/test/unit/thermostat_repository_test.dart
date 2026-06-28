import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/data/thermostat_repository.dart';
import 'package:farmctl/features/thermostats/models/temperature_sample.dart';
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
      rawUrl: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
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
        rawUrl: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        minC: 4,
        maxC: 12,
      ),
    );

    final updated = await repository.update(
      original,
      ThermostatDraft(
        name: 'Greenhouse West',
        rawUrl: 'cccccccccccccccccccccccccccccccc',
        minC: 3,
        maxC: 11,
      ),
    );

    expect(updated.name, 'Greenhouse West');
    expect(updated.rawUrl, 'cccccccccccccccccccccccccccccccc');
    expect(updated.minC, 3);
    expect(updated.maxC, 11);
  });

  test('delete removes thermostat', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Propagation',
        rawUrl: 'ffffffffffffffffffffffffffffffff',
        minC: 6,
        maxC: 18,
      ),
    );

    await repository.replaceHistory(
      thermostatId: thermostat.id,
      samples: [
        TemperatureSample.revision(
          thermostatId: thermostat.id,
          revisionId: 'rev',
          valueC: 10,
          observedAt: DateTime.utc(2025, 1, 1),
        ),
      ],
    );

    await repository.saveState(
      thermostatId: thermostat.id,
      status: ThermostatReadingStatus.ok,
      valueC: 12.3,
      fetchedAt: DateTime.utc(2025, 1, 1, 12),
      etag: 'etag',
      message: 'Fetched 12.30°C',
    );

    await repository.delete(thermostat.id);
    final stored = await repository.fetchThermostats();

    expect(stored, isEmpty);
    final state = await repository.loadState(thermostat.id);
    expect(state, isNull);
    final history = await repository.watchHistory(thermostat.id).first;
    expect(history, isEmpty);
  });

  test('create throws on invalid data', () async {
    final draft = ThermostatDraft(
      name: '',
      rawUrl: 'not-a-gist-id',
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
        rawUrl: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
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
      message: 'Fetched 9.50°C',
    );

    var state = await repository.loadState(thermostat.id);
    expect(state, isNotNull);
    expect(state!.status, ThermostatReadingStatus.ok);
    expect(state.lastValueC, 9.5);
    expect(state.statusMessage, 'Fetched 9.50°C');
    expect(state.snoozedUntil, isNull);
    expect(state.silenceUntilOk, isFalse);

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

  test(
    'updateSnoozedUntil and updateSilenceUntilOk persist controls',
    () async {
      final thermostat = await repository.create(
        ThermostatDraft(
          name: 'Lab',
          rawUrl: '99999999999999999999999999999999',
          minC: 4,
          maxC: 18,
        ),
      );

      final now = DateTime.utc(2025, 1, 2, 10);
      await repository.saveState(
        thermostatId: thermostat.id,
        status: ThermostatReadingStatus.outOfRange,
        valueC: 2.0,
        fetchedAt: now,
        etag: null,
        message: 'Too cold',
        setSnoozedUntil: true,
        snoozedUntil: now.add(const Duration(minutes: 15)),
      );

      var state = await repository.loadState(thermostat.id);
      expect(state, isNotNull);
      expect(state!.snoozedUntil, now.add(const Duration(minutes: 15)));
      expect(state.silenceUntilOk, isFalse);

      await repository.updateSilenceUntilOk(thermostat.id, true);
      state = await repository.loadState(thermostat.id);
      expect(state, isNotNull);
      expect(state!.silenceUntilOk, isTrue);

      await repository.updateSnoozedUntil(thermostat.id, null);
      state = await repository.loadState(thermostat.id);
      expect(state, isNotNull);
      expect(state!.snoozedUntil, isNull);
    },
  );

  test(
    'pruneRetention removes stale readings and caps total entries',
    () async {
      final thermostat = await repository.create(
        ThermostatDraft(
          name: 'Storage',
          rawUrl: '11111111111111111111111111111111',
          minC: 2,
          maxC: 10,
        ),
      );

      final now = DateTime.utc(2025, 10, 20, 12);
      final samples = <TemperatureSample>[];

      for (var i = 0; i < 12; i++) {
        samples.add(
          TemperatureSample.revision(
            thermostatId: thermostat.id,
            revisionId: 'old_$i',
            valueC: 4.0 + i,
            observedAt: now.subtract(Duration(days: 600 + i)),
          ),
        );
      }

      for (var i = 0; i < 5200; i++) {
        samples.add(
          TemperatureSample.revision(
            thermostatId: thermostat.id,
            revisionId: 'recent_$i',
            valueC: 6.0,
            observedAt: now.subtract(Duration(minutes: i)),
          ),
        );
      }

      await repository.upsertHistory(
        thermostatId: thermostat.id,
        samples: samples,
      );

      await repository.pruneRetention(
        thermostatId: thermostat.id,
        maxAge: const Duration(days: 365),
        maxEntriesPerThermostat: 5000,
        now: now,
      );

      final remaining = await database.listTemperatureReadings(thermostat.id);
      expect(remaining.length, 5000);
      expect(
        remaining.every((row) => !row.id.contains('old_')),
        isTrue,
        reason: 'older revisions should be pruned',
      );
      final oldest = remaining
          .map((row) => row.observedAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      expect(
        oldest.isAfter(now.subtract(const Duration(days: 365))),
        isTrue,
        reason: 'readings older than retention window should be removed',
      );
    },
  );

  test('replaceHistory stores samples and sorts ascending', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'History',
        rawUrl: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        minC: 1,
        maxC: 10,
      ),
    );

    await repository.replaceHistory(
      thermostatId: thermostat.id,
      samples: [
        TemperatureSample.revision(
          thermostatId: thermostat.id,
          revisionId: 'two',
          valueC: 9.0,
          observedAt: DateTime.utc(2025, 1, 1, 11),
        ),
        TemperatureSample.revision(
          thermostatId: thermostat.id,
          revisionId: 'one',
          valueC: 8.5,
          observedAt: DateTime.utc(2025, 1, 1, 10),
        ),
      ],
    );

    final samples = await repository.watchHistory(thermostat.id).first;
    expect(samples, hasLength(2));
    expect(samples.first.valueC, 8.5);
    expect(samples.last.sourceId, 'two');
  });

  test('watchHistory returns observedAt normalised to UTC', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'Timezone',
        rawUrl: '44444444444444444444444444444444',
        minC: 0,
        maxC: 20,
      ),
    );
    await repository.replaceHistory(
      thermostatId: thermostat.id,
      samples: [
        TemperatureSample.revision(
          thermostatId: thermostat.id,
          revisionId: 'r1',
          valueC: 10,
          observedAt: DateTime.utc(2025, 1, 1, 10),
        ),
      ],
    );

    final samples = await repository.watchHistory(thermostat.id).first;
    expect(samples.single.observedAt.isUtc, isTrue);
  });

  test(
    'recordOutOfRangeAndShouldAlarm fires once then rate-limits (compare-and-set)',
    () async {
      final thermostat = await repository.create(
        ThermostatDraft(
          name: 'Vault',
          rawUrl: '22222222222222222222222222222222',
          minC: 10,
          maxC: 20,
        ),
      );
      final now = DateTime.utc(2025, 1, 1, 12);

      final first = await repository.recordOutOfRangeAndShouldAlarm(
        thermostatId: thermostat.id,
        valueC: 4,
        fetchedAt: now,
        etag: 'e1',
        message: 'Out of range',
        now: now,
      );
      expect(first, isTrue);
      var state = await repository.loadState(thermostat.id);
      expect(state!.status, ThermostatReadingStatus.outOfRange);
      expect(state.lastAlarmAt, now);

      // A second observation at the same instant must not fire again — it reads
      // the freshly-written lastAlarmAt inside the transaction and rate-limits.
      final second = await repository.recordOutOfRangeAndShouldAlarm(
        thermostatId: thermostat.id,
        valueC: 3.5,
        fetchedAt: now,
        etag: 'e2',
        message: 'Out of range',
        now: now,
      );
      expect(second, isFalse);
      state = await repository.loadState(thermostat.id);
      expect(state!.lastAlarmAt, now); // unchanged
      expect(state.lastValueC, 3.5); // value still updated
    },
  );

  test(
    'recordOutOfRangeAndShouldAlarm respects a concurrently-set silence',
    () async {
      final thermostat = await repository.create(
        ThermostatDraft(
          name: 'Cellar',
          rawUrl: '33333333333333333333333333333333',
          minC: 10,
          maxC: 20,
        ),
      );
      final now = DateTime.utc(2025, 1, 1, 12);

      // Simulate the user silencing the thermostat just before the run writes.
      await repository.updateSilenceUntilOk(thermostat.id, true);

      final fired = await repository.recordOutOfRangeAndShouldAlarm(
        thermostatId: thermostat.id,
        valueC: 4,
        fetchedAt: now,
        message: 'Out of range',
        now: now,
      );

      expect(fired, isFalse);
      final state = await repository.loadState(thermostat.id);
      expect(state!.silenceUntilOk, isTrue); // preserved
      expect(state.lastAlarmAt, isNull);
    },
  );

  test('findById, reading-time bounds and known revision ids', () async {
    final thermostat = await repository.create(
      ThermostatDraft(
        name: 'History',
        rawUrl: '77777777777777777777777777777777',
        minC: 0,
        maxC: 30,
      ),
    );

    expect((await repository.findById(thermostat.id))?.id, thermostat.id);
    expect(await repository.findById('does-not-exist'), isNull);

    // No readings yet.
    expect(await repository.getOldestReadingTime(thermostat.id), isNull);
    expect(await repository.getNewestReadingTime(thermostat.id), isNull);
    expect(await repository.listKnownRevisionIds(thermostat.id), isEmpty);

    await repository.upsertHistory(
      thermostatId: thermostat.id,
      samples: [
        TemperatureSample.revision(
          thermostatId: thermostat.id,
          revisionId: 'r1',
          valueC: 10,
          observedAt: DateTime.utc(2025, 1, 1, 10),
        ),
        TemperatureSample.revision(
          thermostatId: thermostat.id,
          revisionId: 'r2',
          valueC: 11,
          observedAt: DateTime.utc(2025, 1, 1, 12),
        ),
      ],
    );

    final oldest = await repository.getOldestReadingTime(thermostat.id);
    final newest = await repository.getNewestReadingTime(thermostat.id);
    expect(oldest, isNotNull);
    expect(newest, isNotNull);
    expect(newest!.isAfter(oldest!), isTrue);
    expect(
      await repository.listKnownRevisionIds(thermostat.id),
      containsAll(<String>['r1', 'r2']),
    );
  });
}
