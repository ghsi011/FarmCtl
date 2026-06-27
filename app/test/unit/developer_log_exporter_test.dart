import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/settings/data/alert_config_repository.dart';
import 'package:farmctl/features/settings/data/secure_token_store.dart';
import 'package:farmctl/features/settings/services/developer_log_exporter.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/data/thermostat_repository.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';

class _FakeTokenStore implements SecureTokenStore {
  String? token;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String? value) async => token = value;
}

void main() {
  late ThermostatDatabase database;
  late ThermostatRepository thermostatRepository;
  late AlertConfigRepository alertConfigRepository;
  late _FakeTokenStore tokenStore;
  late Directory tempDir;

  setUp(() {
    database = ThermostatDatabase.forTesting(NativeDatabase.memory());
    thermostatRepository = ThermostatRepository(database);
    tokenStore = _FakeTokenStore()..token = 'ghp_super_secret';
    alertConfigRepository = AlertConfigRepository(
      database,
      tokenStore: tokenStore,
    );
    tempDir = Directory.systemTemp.createTempSync('farmctl_export');
  });

  tearDown(() async {
    await database.close();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  DeveloperLogExporter buildExporter(DateTime now) {
    return DeveloperLogExporter(
      thermostatRepository: thermostatRepository,
      alertConfigRepository: alertConfigRepository,
      directoryProvider: () async => tempDir,
      clock: () => now,
    );
  }

  test('exports settings and thermostats as JSON', () async {
    final now = DateTime.utc(2025, 6, 27, 9, 30, 15);
    final thermostat = await thermostatRepository.create(
      ThermostatDraft(name: 'Greenhouse', rawUrl: 'a' * 32, minC: 5, maxC: 25),
    );
    await thermostatRepository.saveState(
      thermostatId: thermostat.id,
      status: ThermostatReadingStatus.ok,
      valueC: 12.5,
      fetchedAt: now,
      etag: 'etag',
      message: 'Fetched 12.50°C',
    );

    final uri = await buildExporter(now).export();
    final file = File.fromUri(uri);
    expect(file.existsSync(), isTrue);

    final payload =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(payload['generatedAt'], now.toIso8601String());

    final thermostats = payload['thermostats'] as List<dynamic>;
    expect(thermostats, hasLength(1));
    final entry = thermostats.first as Map<String, dynamic>;
    final thermostatJson = entry['thermostat'] as Map<String, dynamic>;
    expect(thermostatJson['name'], 'Greenhouse');
    expect(thermostatJson['gistId'], 'a' * 32);
    expect((entry['state'] as Map<String, dynamic>)['lastValueC'], 12.5);
  });

  test('never includes the GitHub token in the export', () async {
    final now = DateTime.utc(2025, 6, 27, 9, 30, 15);
    await thermostatRepository.create(
      ThermostatDraft(name: 'Barn', rawUrl: 'b' * 32, minC: 0, maxC: 20),
    );

    final uri = await buildExporter(now).export();
    final raw = await File.fromUri(uri).readAsString();

    expect(raw.contains('ghp_super_secret'), isFalse);
    expect(raw.contains('githubToken'), isFalse);

    final settings =
        (jsonDecode(raw) as Map<String, dynamic>)['settings']
            as Map<String, dynamic>;
    expect(settings.containsKey('githubToken'), isFalse);
  });

  test('uses a filesystem-safe timestamped filename', () async {
    final now = DateTime.utc(2025, 6, 27, 9, 30, 15);
    final uri = await buildExporter(now).export();
    final name = uri.pathSegments.last;

    expect(name.startsWith('farmctl-log-'), isTrue);
    expect(name.endsWith('.json'), isTrue);
    // Colons from the ISO-8601 timestamp must be replaced to stay path-safe.
    expect(name.contains(':'), isFalse);
  });
}
