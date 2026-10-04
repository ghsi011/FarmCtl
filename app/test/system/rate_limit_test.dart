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

import 'clock_guard_test.dart' show checkpoint, acknowledge;
import 'host_simulator_test.dart'
    show LoopbackGistAdapter, temperatureGist, diagnosticsGist;

void main() {
  final portText = Platform.environment['FARMCTL_SIMULATOR_PORT'];
  final directoryText = Platform.environment['FARMCTL_RATE_DIRECTORY'];
  test(
    'shared rate cooldown preserves delivered observations until exact recovery',
    () async {
      // Given real clients/service and a parent-owned SQLite cache.
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
        List<double> values,
        List<DateTime> times,
        String sample,
        int heartbeat,
      ) async {
        final history = await client.fetchHistory(temperatureGist);
        expect(history.map((entry) => entry.valueC), values);
        expect(history.map((entry) => entry.observedAt), times);
        final snapshot = await diagnostics.fetch(
          gistId: diagnosticsGist,
          deviceRef: 'device-0',
        );
        expect(snapshot.lastSampleRef, sample);
        expect(snapshot.heartbeatSeq, heartbeat);
        expect(snapshot.gistUpdatedAt, times.last);
      }

      final initial = await checkpoint(directory, 'initial');
      expect(initial['publication_ok'], [true]);
      expect(initial['wire_attempts'], {
        temperatureGist: 1,
        diagnosticsGist: 1,
      });
      final thermostat = await service.createAndTest(
        ThermostatDraft(
          name: 'Rate limit fridge',
          rawUrl: temperatureGist,
          minC: 0,
          maxC: 10,
        ),
      );
      final initialAt = DateTime.utc(2026, 1, 2, 3);
      Future<void> assertPersisted(
        List<double> values,
        List<DateTime> times,
      ) async {
        final history = await repository.watchHistory(thermostat.id).first;
        expect(history.map((entry) => entry.valueC), values);
        expect(history.map((entry) => entry.observedAt), times);
      }

      await assertDelivered([4.25], [initialAt], 'rate-boot:1', 1);
      await acknowledge(directory, 'initial');

      // When a wire 429 pauses both streams beyond the 60-second fallback.
      for (final phase in ['limited', 'paused']) {
        final evidence = await checkpoint(directory, phase);
        expect(
          evidence['publication_ok'],
          phase == 'limited' ? [false] : [false, false],
        );
        expect(evidence['sequence'], phase == 'limited' ? 2 : 4);
        expect(evidence['sensor_reads'], evidence['sequence']);
        expect(evidence['transport_attempts'], {
          temperatureGist: 2,
          diagnosticsGist: 1,
        });
        expect(evidence['wire_attempts'], evidence['transport_attempts']);
        now = DateTime.utc(2026, 1, 2, 3, 16, 59);
        await service.refresh(thermostat);
        final stale = await repository.loadState(thermostat.id);
        // Then fetches preserve the delivered value/age and create no history.
        expect(stale?.lastValueC, 4.25);
        expect(stale?.dataUpdatedAt, initialAt);
        expect(stale?.lastFetchedAt, now);
        expect(stale?.status, ThermostatReadingStatus.stale);
        await assertDelivered([4.25], [initialAt], 'rate-boot:1', 1);
        await service.refreshHistory(thermostat.id, prioritizeLastHour: true);
        expect(
          await repository.listKnownRevisionIds(thermostat.id),
          hasLength(1),
        );
        await assertPersisted([4.25], [initialAt]);
        await acknowledge(directory, phase);
      }

      final recovered = await checkpoint(directory, 'recovered');
      expect(recovered['publication_ok'], [true]);
      expect(recovered['sensor_reads'], 5);
      expect(recovered['sequence'], 5);
      expect(recovered['transport_attempts'], {
        temperatureGist: 3,
        diagnosticsGist: 2,
      });
      expect(recovered['wire_attempts'], recovered['transport_attempts']);
      final recoveredAt = DateTime.utc(2026, 1, 2, 3, 17);
      now = recoveredAt.add(const Duration(seconds: 5));
      await service.refresh(thermostat);
      final resumed = await repository.loadState(thermostat.id);
      expect(resumed?.lastValueC, 6.5);
      expect(resumed?.dataUpdatedAt, recoveredAt);
      expect(resumed?.lastFetchedAt, now);
      expect(resumed?.status, ThermostatReadingStatus.ok);
      await assertDelivered(
        [4.25, 6.5],
        [initialAt, recoveredAt],
        'rate-boot:5',
        5,
      );
      await service.refreshHistory(thermostat.id, prioritizeLastHour: true);
      final revisions = await repository.listKnownRevisionIds(thermostat.id);
      expect(revisions, hasLength(2));
      await assertPersisted([4.25, 6.5], [initialAt, recoveredAt]);
      await database.close();
      database = ThermostatDatabase.forTesting(NativeDatabase(file));
      repository = ThermostatRepository(database);
      expect((await repository.loadState(thermostat.id))?.lastValueC, 6.5);
      expect(
        (await repository.loadState(thermostat.id))?.dataUpdatedAt,
        recoveredAt,
      );
      expect(
        await repository.listKnownRevisionIds(thermostat.id),
        unorderedEquals(revisions),
      );
      await assertPersisted([4.25, 6.5], [initialAt, recoveredAt]);
    },
    skip: portText == null || directoryText == null
        ? 'Run via tool/host_simulator/run.py to coordinate the rate case.'
        : false,
  );
}
