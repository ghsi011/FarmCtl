import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:farmctl/features/thermostats/data/device_diagnostics_client.dart';
import 'package:farmctl/features/thermostats/data/thermostat_client.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/data/thermostat_repository.dart';
import 'package:farmctl/features/thermostats/data/thermostat_service.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'host_simulator_test.dart'
    show LoopbackGistAdapter, temperatureGist, diagnosticsGist;

Future<Map<String, dynamic>> checkpoint(
  Directory directory,
  String phase,
) async {
  final ready = File('${directory.path}/$phase.ready');
  final deadline = Stopwatch()..start();
  while (!await ready.exists()) {
    if (deadline.elapsed > const Duration(seconds: 10)) {
      throw StateError('Firmware checkpoint deadline: $phase');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(await ready.readAsString(), phase);
  final file = File('${directory.path}/$phase.json');
  expect(await file.length(), lessThan(4096));
  final evidence =
      jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  expect(evidence['phase'], phase);
  return evidence;
}

Future<void> acknowledge(Directory directory, String phase) async {
  final marker = '${directory.path}/$phase.ack';
  final temporary = File('$marker.tmp');
  await temporary.writeAsString('$phase\n', flush: true);
  await temporary.rename(marker);
}

void main() {
  final portText = Platform.environment['FARMCTL_SIMULATOR_PORT'];
  final directoryText = Platform.environment['FARMCTL_CLOCK_DIRECTORY'];
  test(
    'untrusted clock preserves stale observation until a new trusted sample',
    () async {
      final directory = Directory(directoryText!);
      final dio = Dio()
        ..httpClientAdapter = LoopbackGistAdapter(int.parse(portText!));
      var now = DateTime.utc(2026, 1, 2, 3, 0, 5);
      final client = ThermostatHttpClient(
        dio: dio,
        dioNoAuth: dio,
        githubToken: 'synthetic-host-token',
        allowAnonFallback: false,
        clock: () => now,
      );
      addTearDown(client.close);
      final diagnostics = GitHubDeviceDiagnosticsClient(
        dio: dio,
        githubToken: 'synthetic-host-token',
        clock: () => now,
      );
      final cache = Directory('${directory.path}/cache')..createSync();
      addTearDown(() => cache.deleteSync(recursive: true));
      final file = File('${cache.path}/cache.sqlite');
      var database = ThermostatDatabase.forTesting(NativeDatabase(file));
      addTearDown(() => database.close());
      var repository = ThermostatRepository(database);
      final service = ThermostatService(
        repository: repository,
        network: client,
        clock: () => now,
        pollIntervalSupplier: () async => const Duration(minutes: 1),
      );
      Future<void> assertDelivered(
        int count,
        String sample,
        int heartbeat,
        DateTime at,
      ) async {
        final snapshot = await diagnostics.fetch(
          gistId: diagnosticsGist,
          deviceRef: 'device-0',
        );
        expect(snapshot.lastSampleRef, sample);
        expect(snapshot.heartbeatSeq, heartbeat);
        expect(snapshot.gistUpdatedAt, at);
        final history = await client.fetchHistory(temperatureGist);
        expect(history, hasLength(count));
        expect(
          history.map((entry) => entry.valueC),
          count == 1 ? [4.25] : [4.25, 6.5],
        );
        expect(
          history.map((entry) => entry.observedAt),
          count == 1
              ? [DateTime.utc(2026, 1, 2, 3)]
              : [DateTime.utc(2026, 1, 2, 3), DateTime.utc(2026, 1, 2, 3, 20)],
        );
      }

      final initial = await checkpoint(directory, 'initial');
      expect(initial['trusted'], isTrue);
      expect(initial['transport_attempts'], {
        temperatureGist: 1,
        diagnosticsGist: 1,
      });
      expect(initial['wire_attempts'], initial['transport_attempts']);
      final thermostat = await service.createAndTest(
        ThermostatDraft(
          name: 'Clock guard fridge',
          rawUrl: temperatureGist,
          minC: 0,
          maxC: 10,
        ),
      );
      final fresh = await repository.loadState(thermostat.id);
      expect(fresh?.lastValueC, 4.25);
      expect(fresh?.status, ThermostatReadingStatus.ok);
      expect(fresh?.dataUpdatedAt, DateTime.utc(2026, 1, 2, 3));
      await assertDelivered(1, 'clock-boot:1', 1, DateTime.utc(2026, 1, 2, 3));
      await acknowledge(directory, 'initial');

      final paused = await checkpoint(directory, 'paused');
      expect(paused['trusted'], isFalse);
      expect(paused['sensor_reads'], 3);
      expect(paused['sequence'], 3);
      expect(paused['publication_ok'], [false, false]);
      expect(paused['transport_attempts'], initial['transport_attempts']);
      expect(paused['wire_attempts'], initial['wire_attempts']);
      now = DateTime.utc(2026, 1, 2, 3, 16);
      await service.refresh(thermostat);
      final stale = await repository.loadState(thermostat.id);
      expect(stale?.lastValueC, 4.25);
      expect(stale?.dataUpdatedAt, DateTime.utc(2026, 1, 2, 3));
      expect(stale?.lastFetchedAt, now);
      expect(stale?.status, ThermostatReadingStatus.stale);
      await assertDelivered(1, 'clock-boot:1', 1, DateTime.utc(2026, 1, 2, 3));
      await service.refreshHistory(thermostat.id, prioritizeLastHour: true);
      final priorRevisions = await repository.listKnownRevisionIds(
        thermostat.id,
      );
      expect(priorRevisions, hasLength(1));
      await acknowledge(directory, 'paused');

      final recovered = await checkpoint(directory, 'recovered');
      expect(recovered['trusted'], isTrue);
      expect(recovered['sensor_reads'], 4);
      expect(recovered['sequence'], 4);
      expect(recovered['publication_ok'], [true]);
      expect(recovered['transport_attempts'], {
        temperatureGist: 2,
        diagnosticsGist: 2,
      });
      expect(recovered['wire_attempts'], recovered['transport_attempts']);
      now = DateTime.utc(2026, 1, 2, 3, 20, 5);
      await service.refresh(thermostat);
      final resumed = await repository.loadState(thermostat.id);
      expect(resumed?.lastValueC, 6.5);
      expect(resumed?.dataUpdatedAt, DateTime.utc(2026, 1, 2, 3, 20));
      expect(resumed?.lastFetchedAt, now);
      expect(resumed?.status, ThermostatReadingStatus.ok);
      await assertDelivered(
        2,
        'clock-boot:4',
        4,
        DateTime.utc(2026, 1, 2, 3, 20),
      );
      await service.refreshHistory(thermostat.id, prioritizeLastHour: true);
      final revisions = await repository.listKnownRevisionIds(thermostat.id);
      expect(revisions, hasLength(2));
      expect(revisions, containsAll(priorRevisions));
      await database.close();
      database = ThermostatDatabase.forTesting(NativeDatabase(file));
      repository = ThermostatRepository(database);
      expect(
        (await repository.loadState(thermostat.id))?.dataUpdatedAt,
        DateTime.utc(2026, 1, 2, 3, 20),
      );
      expect(
        await repository.listKnownRevisionIds(thermostat.id),
        unorderedEquals(revisions),
      );
    },
    skip: portText == null || directoryText == null
        ? 'Run via tool/host_simulator/run.py to coordinate the clock case.'
        : false,
  );
}
