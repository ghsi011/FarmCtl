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
  final directoryText = Platform.environment['FARMCTL_INTERRUPTED_DIRECTORY'];
  test(
    'interrupted requests stay bounded and preserve only delivered history',
    () async {
      // Given real clients/service and an owned file-backed SQLite database.
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

      final initial = await checkpoint(directory, 'initial');
      expect(initial['publication_ok'], [true]);
      expect(initial['wire_attempts'], {
        temperatureGist: 1,
        diagnosticsGist: 1,
      });
      final thermostat = await service.createAndTest(
        ThermostatDraft(
          name: 'Interrupted fridge',
          rawUrl: temperatureGist,
          minC: 0,
          maxC: 10,
        ),
      );
      final initialAt = DateTime.utc(2026, 1, 2, 3);
      Future<void> assertHistory(
        List<double> values,
        List<DateTime> times,
      ) async {
        final delivered = await client.fetchHistory(temperatureGist);
        expect(delivered.map((entry) => entry.valueC), values);
        expect(delivered.map((entry) => entry.observedAt), times);
        final persisted = await repository.watchHistory(thermostat.id).first;
        expect(persisted.map((entry) => entry.valueC), values);
        expect(persisted.map((entry) => entry.observedAt), times);
      }

      await service.refreshHistory(thermostat.id, prioritizeLastHour: true);
      await assertHistory([4.25], [initialAt]);
      await acknowledge(directory, 'initial');

      // When EOF and a native request deadline fail before fixture application.
      final phases = ['dropped', 'first_backoff', 'stalled', 'second_backoff'];
      for (var index = 0; index < phases.length; index++) {
        final phase = phases[index];
        final evidence = await checkpoint(directory, phase);
        expect(evidence['publication_ok'], [false]);
        expect(evidence['sequence'], index + 2);
        expect(evidence['sensor_reads'], evidence['sequence']);
        expect(evidence['transport_attempts'], {
          temperatureGist: index < 2 ? 2 : 3,
          diagnosticsGist: index + 2,
        });
        expect(evidence['wire_attempts'], evidence['transport_attempts']);
        expect(evidence['elapsed_ms'], lessThan(1500));
        if (phase == 'stalled') {
          expect(evidence['elapsed_ms'], greaterThanOrEqualTo(500));
        }
        now = DateTime.utc(2026, 1, 2, 3, 16, 59);
        await service.refresh(thermostat);
        final state = await repository.loadState(thermostat.id);
        // Then the failed/suppressed samples create no fresh value or history.
        expect(state?.lastValueC, 4.25);
        expect(state?.dataUpdatedAt, initialAt);
        expect(state?.lastFetchedAt, now);
        expect(state?.status, ThermostatReadingStatus.stale);
        final heartbeat = await diagnostics.fetch(
          gistId: diagnosticsGist,
          deviceRef: 'device-0',
        );
        expect(heartbeat.heartbeatSeq, index + 2);
        expect(heartbeat.lastSampleRef, 'interrupted-boot:1');
        await service.refreshHistory(thermostat.id, prioritizeLastHour: true);
        expect(
          await repository.listKnownRevisionIds(thermostat.id),
          hasLength(1),
        );
        await assertHistory([4.25], [initialAt]);
        await acknowledge(directory, phase);
      }

      final recovered = await checkpoint(directory, 'recovered');
      expect(recovered['publication_ok'], [true]);
      expect(recovered['sequence'], 6);
      expect(recovered['sensor_reads'], 6);
      expect(recovered['transport_attempts'], {
        temperatureGist: 4,
        diagnosticsGist: 5,
      });
      expect(recovered['wire_attempts'], recovered['transport_attempts']);
      final recoveredAt = DateTime.utc(2026, 1, 2, 3, 15, 17);
      now = DateTime.utc(2026, 1, 2, 3, 17, 5);
      await service.refresh(thermostat);
      final state = await repository.loadState(thermostat.id);
      expect(state?.lastValueC, 6.5);
      expect(state?.dataUpdatedAt, recoveredAt);
      expect(state?.status, ThermostatReadingStatus.ok);
      await service.refreshHistory(thermostat.id, prioritizeLastHour: true);
      final revisions = await repository.listKnownRevisionIds(thermostat.id);
      expect(revisions, hasLength(2));
      await assertHistory([4.25, 6.5], [initialAt, recoveredAt]);

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
      await assertHistory([4.25, 6.5], [initialAt, recoveredAt]);
    },
    skip: portText == null || directoryText == null
        ? 'Run via tool/host_simulator/run.py to coordinate interrupted requests.'
        : false,
  );
}
