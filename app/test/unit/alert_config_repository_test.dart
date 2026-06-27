import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/settings/data/alert_config_repository.dart';
import 'package:farmctl/features/settings/data/secure_token_store.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';

class _FakeTokenStore implements SecureTokenStore {
  String? token;
  bool persistWrites = true;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String? value) async {
    // When persistWrites is false, simulate a secure-storage write that
    // silently fails to persist (e.g. keystore not ready in a background isolate).
    if (!persistWrites) {
      return;
    }
    token = (value == null || value.isEmpty) ? null : value;
  }
}

void main() {
  late ThermostatDatabase database;
  late AlertConfigRepository repository;
  late _FakeTokenStore tokenStore;
  late DateTime currentTime;

  setUp(() {
    database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    currentTime = DateTime.utc(2025, 1, 1, 12);
    tokenStore = _FakeTokenStore();
    repository = AlertConfigRepository(
      database,
      clock: () => currentTime,
      tokenStore: tokenStore,
    );
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

  test('setGithubToken stores in secure storage, not the database', () async {
    await repository.setGithubToken('ghp_secret');

    expect(tokenStore.token, 'ghp_secret');
    final config = await repository.loadConfig();
    expect(config.githubToken, 'ghp_secret');

    // The plaintext database column must not hold the token.
    final entry = await database.getAlertConfig();
    expect(entry.githubToken, isNull);
  });

  test('setGithubToken(null) clears the token', () async {
    await repository.setGithubToken('ghp_secret');
    await repository.setGithubToken(null);

    expect(tokenStore.token, isNull);
    final config = await repository.loadConfig();
    expect(config.githubToken, isNull);
  });

  test('does not scrub the plaintext token if the secure write fails', () async {
    // Seed a legacy plaintext token; secure storage silently fails to persist.
    await database.updateAlertConfig(
      const AlertConfigEntriesCompanion(githubToken: Value('ghp_legacy')),
    );
    tokenStore.persistWrites = false;

    final config = await repository.loadConfig();
    // The token is still usable for this run...
    expect(config.githubToken, 'ghp_legacy');
    // ...and the plaintext copy is NOT scrubbed, since the migration write did
    // not persist (otherwise the only copy would be lost forever).
    expect((await database.getAlertConfig()).githubToken, 'ghp_legacy');
    expect(tokenStore.token, isNull);
  });

  test('keeps the alert config as a single row across many writers', () async {
    await database.updateAlertConfig(
      const AlertConfigEntriesCompanion(pollIntervalMin: Value(9)),
    );
    await database.updateAlertConfig(
      const AlertConfigEntriesCompanion(exactAlarmsEnabled: Value(true)),
    );
    await database.setLastMonitorRunAt(DateTime.utc(2025, 6, 27, 12));

    final rows = await database.select(database.alertConfigEntries).get();
    expect(rows, hasLength(1));
    final cfg = await database.getAlertConfig();
    expect(cfg.pollIntervalMin, 9);
    expect(cfg.exactAlarmsEnabled, isTrue);
    expect(cfg.lastMonitorRunAt, isNotNull);
  });

  test('migrates a legacy plaintext token into secure storage', () async {
    // Simulate an existing install with the token in the plaintext column.
    await database.updateAlertConfig(
      const AlertConfigEntriesCompanion(githubToken: Value('ghp_legacy')),
    );
    expect((await database.getAlertConfig()).githubToken, 'ghp_legacy');
    expect(tokenStore.token, isNull);

    final config = await repository.loadConfig();
    expect(config.githubToken, 'ghp_legacy');

    // After migration the secret lives in secure storage and is scrubbed from
    // the database.
    expect(tokenStore.token, 'ghp_legacy');
    expect((await database.getAlertConfig()).githubToken, isNull);
  });
}
