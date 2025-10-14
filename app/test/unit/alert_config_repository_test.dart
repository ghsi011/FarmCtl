import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/settings/data/alert_config_repository.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';

void main() {
  late ThermostatDatabase database;
  late AlertConfigRepository repository;
  late DateTime currentTime;

  setUp(() {
    database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    currentTime = DateTime.utc(2025, 1, 1, 12);
    repository = AlertConfigRepository(database, clock: () => currentTime);
  });

  tearDown(() async {
    await database.close();
  });

  test('loadConfig returns defaults', () async {
    final config = await repository.loadConfig();

    expect(config.pollInterval, const Duration(minutes: 5));
    expect(config.exactAlarmsEnabled, isFalse);
    expect(config.soundUri, isNull);
    expect(config.vibrate, isTrue);
    expect(config.volumeBoost, isFalse);
    expect(config.pauseAllUntil, isNull);
  });

  test('setPollInterval persists new value', () async {
    await repository.setPollInterval(const Duration(minutes: 9));

    final config = await repository.loadConfig();
    expect(config.pollInterval, const Duration(minutes: 9));
  });

  test('pauseFor and clearPause update pause window', () async {
    await repository.pauseFor(const Duration(hours: 2));

    var config = await repository.loadConfig();
    expect(config.pauseAllUntil, currentTime.add(const Duration(hours: 2)));
    expect(config.isPaused(currentTime), isTrue);

    await repository.clearPause();
    config = await repository.loadConfig();
    expect(config.pauseAllUntil, isNull);
    expect(config.isPaused(currentTime), isFalse);
  });

  test('watchConfig emits updates', () async {
    final initial = await repository.watchConfig().first;
    expect(initial.pollInterval, const Duration(minutes: 5));

    final nextFuture = repository.watchConfig().skip(1).first;
    await repository.setPollInterval(const Duration(minutes: 7));
    final updated = await nextFuture;
    expect(updated.pollInterval, const Duration(minutes: 7));
  });

  test('setSoundUri stores and clears values', () async {
    await repository.setSoundUri('content://media/123');
    var config = await repository.loadConfig();
    expect(config.soundUri, 'content://media/123');

    await repository.setSoundUri(null);
    config = await repository.loadConfig();
    expect(config.soundUri, isNull);
  });
}
