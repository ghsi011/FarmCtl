import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/data/thermostat_repository.dart';
import 'package:farmctl/features/thermostats/models/history_range.dart';
import 'package:farmctl/features/thermostats/models/temperature_sample.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';

void main() {
  late ThermostatDatabase db;
  late bool databaseClosed;

  setUp(() {
    db = ThermostatDatabase.forTesting(NativeDatabase.memory());
    databaseClosed = false;
  });

  tearDown(() async {
    if (!databaseClosed) await db.close();
  });

  Future<void> seed(List<({String id, DateTime at, double v})> readings) async {
    await db.upsertThermostat(
      ThermostatEntriesCompanion.insert(
        id: 't1',
        name: 'Barn',
        rawUrl: 'a' * 32,
        minC: 0.0,
        maxC: 20.0,
      ),
    );
    await db.insertTemperatureReadings([
      for (final r in readings)
        TemperatureReadingsCompanion.insert(
          id: r.id,
          thermostatId: 't1',
          source: 'revision',
          valueC: r.v,
          observedAt: r.at,
          sourceId: Value(r.id),
        ),
    ]);
  }

  ProviderContainer containerWithDb() {
    final container = ProviderContainer(
      overrides: [thermostatDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<List<TemperatureSample>> readHistory(
    ProviderContainer container,
    ThermostatHistoryRange range,
  ) async {
    final provider = thermostatHistoryProvider((
      thermostatId: 't1',
      range: range,
    ));
    // Keep the stream subscribed so its first value is delivered.
    final sub = container.listen(provider, (_, _) {});
    addTearDown(sub.close);
    return container.read(provider.future);
  }

  test('emits downsampled samples for the full range', () async {
    await seed([
      (id: 'r1', at: DateTime.utc(2025, 1, 1, 10), v: 10),
      (id: 'r2', at: DateTime.utc(2025, 1, 1, 11), v: 12),
      (id: 'r3', at: DateTime.utc(2025, 1, 1, 12), v: 14),
    ]);
    final container = containerWithDb();

    final samples = await readHistory(container, ThermostatHistoryRange.all);

    // The 'all' range buckets by 120 minutes from the first sample, so the
    // 10:00/11:00 readings merge (avg 11, aggregated) and 12:00 stands alone.
    expect(samples, hasLength(2));
    expect(samples.first.valueC, 11);
    expect(samples.first.source, 'aggregated');
    expect(samples.last.valueC, 14);
    expect(samples.last.source, 'revision');
    expect(samples.first.observedAt.isBefore(samples.last.observedAt), isTrue);
  });

  test('filters out samples older than the requested window', () async {
    final now = DateTime.utc(2025, 1, 1, 12);
    await seed([
      (id: 'recent', at: now.subtract(const Duration(minutes: 10)), v: 18),
      (id: 'ancient', at: DateTime.utc(2000, 1, 1), v: 1),
    ]);
    final container = ProviderContainer(
      overrides: [
        thermostatDatabaseProvider.overrideWithValue(db),
        nowProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(container.dispose);

    final samples = await readHistory(container, ThermostatHistoryRange.hour);

    // Only the within-the-hour reading survives the window filter; the year-2000
    // reading is dropped before downsampling.
    expect(samples, hasLength(1));
    expect(samples.single.valueC, 18);
  });

  testWidgets('Last hour expires samples without a database emission', (
    tester,
  ) async {
    // A fixed future instant also keeps the initial sample inside the baseline
    // provider's wall-clock cutoff, so the failure is stale data, not empty data.
    final initialNow = DateTime.utc(2100, 1, 1);
    final startedAt = tester.binding.clock.now();
    await tester.runAsync(
      () => seed([
        (
          id: 'expiring',
          at: initialNow.subtract(const Duration(minutes: 59)),
          v: 18,
        ),
      ]),
    );
    final container = ProviderContainer(
      overrides: [
        thermostatDatabaseProvider.overrideWithValue(db),
        nowProvider.overrideWithValue(
          () =>
              initialNow.add(tester.binding.clock.now().difference(startedAt)),
        ),
      ],
    );
    final provider = thermostatHistoryProvider((
      thermostatId: 't1',
      range: ThermostatHistoryRange.hour,
    ));
    final subscription = container.listen(provider, (_, _) {});
    try {
      await tester.pump();
      final initialSamples = await tester.runAsync(
        () => container.read(provider.future),
      );
      expect(initialSamples, hasLength(1));
      expect(initialSamples!.single.valueC, 18);

      // Keep the same subscription and make no further database writes.
      await tester.pump(const Duration(minutes: 2));
      await tester.pump();
      final samples = await tester.runAsync(
        () => container.read(provider.future),
      );
      expect(
        samples,
        isEmpty,
        reason:
            'Last hour must drop the now-61-minute-old sample without a '
            'database emission or resubscription.',
      );
    } finally {
      await tester.runAsync(() async {
        subscription.close();
        container.dispose();
        await db.close();
        databaseClosed = true;
      });
    }
  });

  for (final range in [
    ThermostatHistoryRange.hour,
    ThermostatHistoryRange.day,
  ]) {
    testWidgets('${range.name} advances cutoff on writes between ticks', (
      tester,
    ) async {
      var now = DateTime.utc(2025, 1, 1, 12);
      await tester.runAsync(
        () => seed([(id: 'boundary', at: now.subtract(range.window!), v: 11)]),
      );
      final container = ProviderContainer(
        overrides: [
          thermostatDatabaseProvider.overrideWithValue(db),
          nowProvider.overrideWithValue(() => now),
        ],
      );
      final provider = thermostatHistoryProvider((
        thermostatId: 't1',
        range: range,
      ));
      final freshDelivered = Completer<void>();
      final subscription = container.listen(provider, (_, value) {
        if (!freshDelivered.isCompleted &&
            (value.asData?.value.any((sample) => sample.valueC == 17) ??
                false)) {
          freshDelivered.complete();
        }
      });
      try {
        await tester.pump();
        final initial = await tester.runAsync(
          () => container.read(provider.future),
        );
        expect(initial!.single.valueC, 11);
        // Advance the injectable clock only: no periodic tick has fired yet.
        now = now.add(const Duration(seconds: 30));
        await tester.runAsync(() => seed([(id: 'fresh', at: now, v: 17)]));
        // Wait for the actual provider emission, without advancing fake time
        // to the periodic tick or imposing a wall-clock delivery allowance.
        await tester.pump();
        await tester.runAsync(() => freshDelivered.future);
        expect(
          container.read(provider).requireValue.map((sample) => sample.valueC),
          [17],
        );
      } finally {
        await tester.runAsync(() async {
          subscription.close();
          container.dispose();
          await db.close();
          databaseClosed = true;
        });
      }
    });

    testWidgets('${range.name} includes cutoff, rolls, and reopens fresh', (
      tester,
    ) async {
      final initialNow = DateTime.utc(2025, 1, 1, 12);
      final startedAt = tester.binding.clock.now();
      var clockReads = 0;
      await tester.runAsync(
        () => seed([
          (id: 'boundary', at: initialNow.subtract(range.window!), v: 11),
          (
            id: 'outside',
            at: initialNow
                .subtract(range.window!)
                .subtract(const Duration(seconds: 1)),
            v: 99,
          ),
        ]),
      );
      final container = ProviderContainer(
        overrides: [
          thermostatDatabaseProvider.overrideWithValue(db),
          nowProvider.overrideWithValue(() {
            clockReads++;
            return initialNow.add(
              tester.binding.clock.now().difference(startedAt),
            );
          }),
        ],
      );
      final provider = thermostatHistoryProvider((
        thermostatId: 't1',
        range: range,
      ));
      var subscription = container.listen(provider, (_, _) {});
      try {
        await tester.pump();
        final initial = await tester.runAsync(
          () => container.read(provider.future),
        );
        expect(initial!.map((sample) => sample.valueC), [11]);
        await tester.pump(const Duration(minutes: 1));
        await tester.pump();
        final expired = await tester.runAsync(
          () => container.read(provider.future),
        );
        expect(expired, isEmpty);

        subscription.close();
        await tester.pump();
        await tester.pump();
        final readsAfterClose = clockReads;
        await tester.pump(const Duration(minutes: 5));
        expect(
          clockReads,
          readsAfterClose,
          reason: 'No ticking survives the last subscription',
        );
        await tester.runAsync(
          () => seed([
            (
              id: 'fresh',
              at: initialNow.add(const Duration(minutes: 6)),
              v: 17,
            ),
          ]),
        );
        subscription = container.listen(provider, (_, _) {});
        await tester.pump();
        final reopened = await tester.runAsync(
          () => container.read(provider.future),
        );
        expect(reopened!.map((sample) => sample.valueC), [17]);
      } finally {
        await tester.runAsync(() async {
          subscription.close();
          container.dispose();
          await db.close();
          databaseClosed = true;
        });
      }
    });
  }

  testWidgets('All neither reads the clock nor re-queries on time changes', (
    tester,
  ) async {
    await tester.runAsync(
      () => seed([
        (id: 'old', at: DateTime.utc(2000, 1, 1), v: 11),
        (id: 'new', at: DateTime.utc(2025, 1, 1), v: 17),
      ]),
    );
    final repository = _CountingRepository(db);
    var clockReads = 0;
    var emissions = 0;
    final container = ProviderContainer(
      overrides: [
        thermostatRepositoryProvider.overrideWithValue(repository),
        nowProvider.overrideWithValue(() {
          clockReads++;
          return DateTime.utc(2025, 1, 1);
        }),
      ],
    );
    final provider = thermostatHistoryProvider((
      thermostatId: 't1',
      range: ThermostatHistoryRange.all,
    ));
    final subscription = container.listen(provider, (_, value) {
      if (value.asData != null) emissions++;
    });
    try {
      await tester.pump();
      final initial = await tester.runAsync(
        () => container.read(provider.future),
      );
      expect(initial!.map((sample) => sample.valueC), [11, 17]);
      final initialEmissions = emissions;
      container.invalidate(nowProvider);
      await tester.pump(const Duration(days: 2));
      await tester.pump();
      expect(clockReads, 0);
      expect(repository.historyQueries, 1);
      expect(emissions, initialEmissions);
      expect(
        container.read(provider).requireValue.map((sample) => sample.valueC),
        [11, 17],
      );
    } finally {
      await tester.runAsync(() async {
        subscription.close();
        container.dispose();
        await db.close();
        databaseClosed = true;
      });
    }
  });
}

class _CountingRepository extends ThermostatRepository {
  _CountingRepository(super.database);

  int historyQueries = 0;

  @override
  Stream<List<TemperatureSample>> watchHistory(
    String thermostatId, {
    DateTime? since,
  }) {
    historyQueries++;
    return super.watchHistory(thermostatId, since: since);
  }
}
