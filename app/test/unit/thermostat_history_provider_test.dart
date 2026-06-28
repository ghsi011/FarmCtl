import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/models/history_range.dart';
import 'package:farmctl/features/thermostats/models/temperature_sample.dart';
import 'package:farmctl/features/thermostats/providers/thermostat_providers.dart';

void main() {
  late ThermostatDatabase db;

  setUp(() {
    db = ThermostatDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
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

    expect(samples, isNotEmpty);
    expect(samples, everyElement(isA<TemperatureSample>()));
    // Downsampling may bucket/average, but every emitted value must stay within
    // the seeded range and rows are ordered oldest-first.
    expect(samples.every((s) => s.valueC >= 10 && s.valueC <= 14), isTrue);
    expect(samples.first.observedAt.isBefore(samples.last.observedAt), isTrue);
  });

  test('filters out samples older than the requested window', () async {
    final now = DateTime.now().toUtc();
    await seed([
      (id: 'recent', at: now.subtract(const Duration(minutes: 10)), v: 18),
      (id: 'ancient', at: DateTime.utc(2000, 1, 1), v: 1),
    ]);
    final container = containerWithDb();

    final samples = await readHistory(container, ThermostatHistoryRange.hour);

    // Only the within-the-hour reading survives the window filter.
    expect(samples, isNotEmpty);
    expect(samples.every((s) => s.observedAt.isAfter(DateTime(2001))), isTrue);
    expect(samples.any((s) => s.valueC == 1), isFalse);
  });
}
