import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:drift/native.dart';
import 'package:farmctl/features/thermostats/data/device_diagnostics_client.dart';
import 'package:farmctl/features/thermostats/data/thermostat_client.dart';
import 'package:farmctl/features/thermostats/data/thermostat_database.dart';
import 'package:farmctl/features/thermostats/data/thermostat_repository.dart';
import 'package:farmctl/features/thermostats/data/thermostat_service.dart';
import 'package:farmctl/features/thermostats/models/thermostat.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';
import 'package:flutter_test/flutter_test.dart';

const temperatureGist = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const diagnosticsGist = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// Test-only routing of absolute API URLs. No shipped endpoint changes.
class LoopbackGistAdapter implements HttpClientAdapter {
  LoopbackGistAdapter(this.port);
  final int port;
  final _delegate = IOHttpClientAdapter(
    createHttpClient: () => HttpClient()..findProxy = (_) => 'DIRECT',
  );
  bool failReads = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final uri = options.uri;
    if (uri.scheme != 'https' ||
        uri.host != 'api.github.com' ||
        uri.port != 443 ||
        options.method != 'GET' ||
        !RegExp(
          r'^/gists/(a{32}|b{32})(/(commits|[0-9a-f]{40}))?$',
        ).hasMatch(uri.path)) {
      throw StateError('Unsupported simulator request');
    }
    final query = Map<String, dynamic>.from(options.queryParameters);
    if (failReads) query['fixture_error'] = '503';
    return _delegate.fetch(
      options.copyWith(
        baseUrl: 'http://127.0.0.1:$port',
        path: uri.path,
        queryParameters: query,
        followRedirects: false,
        headers: {
          HttpHeaders.acceptHeader: 'application/vnd.github+json',
          HttpHeaders.authorizationHeader: 'token synthetic-host-token',
        },
      ),
      requestStream,
      cancelFuture,
    );
  }

  @override
  void close({bool force = false}) => _delegate.close(force: force);
}

void main() {
  final portText = Platform.environment['FARMCTL_SIMULATOR_PORT'];
  final skip = portText == null
      ? 'Run via tool/host_simulator/run.py to supply the shared fixture.'
      : false;

  test(
    'firmware samples retain observation age and history in app storage',
    () async {
      // Given: real Unix firmware has published through the shared loopback API.
      final port = int.parse(portText!);
      final adapter = LoopbackGistAdapter(port);
      final dio = Dio()..httpClientAdapter = adapter;
      var now = DateTime.utc(2026, 1, 2, 3, 15, 5);
      final client = ThermostatHttpClient(
        dio: dio,
        dioNoAuth: dio,
        githubToken: 'synthetic-host-token',
        allowAnonFallback: false,
        clock: () => now,
      );
      addTearDown(client.close);
      final directory = Directory.systemTemp.createTempSync('farmctl-host-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/cache.sqlite');
      var database = ThermostatDatabase.forTesting(NativeDatabase(file));
      addTearDown(() => database.close());
      var repository = ThermostatRepository(database);
      final service = ThermostatService(
        repository: repository,
        network: client,
        clock: () => now,
        pollIntervalSupplier: () async => const Duration(minutes: 1),
      );

      // When: the real service consumes the firmware's current sample.
      final thermostat = await service.createAndTest(
        ThermostatDraft(
          name: 'Synthetic fridge',
          rawUrl: temperatureGist,
          minC: 0,
          maxC: 10,
        ),
      );
      // Then: value and observation time persist independently of fetch time.
      final fresh = await repository.loadState(thermostat.id);
      expect(fresh?.lastValueC, 6.5);
      expect(fresh?.status, ThermostatReadingStatus.ok);
      expect(fresh?.dataUpdatedAt, DateTime.utc(2026, 1, 2, 3, 15));
      expect(fresh?.lastFetchedAt, now);

      final history = await client.fetchHistory(temperatureGist);
      expect(history.map((sample) => sample.valueC).toList(), [
        4.25,
        4.25,
        6.5,
      ]);
      expect(history.map((sample) => sample.observedAt).toList(), [
        DateTime.utc(2026, 1, 2, 3),
        DateTime.utc(2026, 1, 2, 3, 5),
        DateTime.utc(2026, 1, 2, 3, 15),
      ]);
      await service.refreshHistory(thermostat.id, prioritizeLastHour: true);
      final persistedRevisionIds = await repository.listKnownRevisionIds(
        thermostat.id,
      );
      expect(persistedRevisionIds, hasLength(3));

      now = DateTime.utc(2026, 1, 2, 3, 31);
      await service.refresh(thermostat);
      final stale = await repository.loadState(thermostat.id);
      expect(stale?.status, ThermostatReadingStatus.stale);
      expect(stale?.dataUpdatedAt, DateTime.utc(2026, 1, 2, 3, 15));
      expect(stale?.lastFetchedAt, now);

      adapter.failReads = true;
      final failed = await service.refresh(thermostat);
      expect(failed.status, ThermostatReadingStatus.httpError);
      expect((await repository.loadState(thermostat.id))?.lastValueC, 6.5);
      adapter.failReads = false;
      await service.refresh(thermostat);
      expect(
        (await repository.loadState(thermostat.id))?.status,
        ThermostatReadingStatus.stale,
      );

      await database.close();
      database = ThermostatDatabase.forTesting(NativeDatabase(file));
      repository = ThermostatRepository(database);
      expect(
        (await repository.loadState(thermostat.id))?.dataUpdatedAt,
        DateTime.utc(2026, 1, 2, 3, 15),
      );
      expect(
        await repository.listKnownRevisionIds(thermostat.id),
        unorderedEquals(persistedRevisionIds),
      );
    },
    skip: skip,
  );

  test(
    'independent diagnostics reports failed sampling without fresh temperature',
    () async {
      // Given: the same firmware run contains a failed diagnostics delivery.
      final dio = Dio()
        ..httpClientAdapter = LoopbackGistAdapter(int.parse(portText!));
      addTearDown(() => dio.close(force: true));
      final client = GitHubDeviceDiagnosticsClient(
        dio: dio,
        githubToken: 'synthetic-host-token',
        clock: () => DateTime.utc(2026, 1, 2, 3, 20),
      );
      // When: the app reads the later independent diagnostics heartbeat.
      final snapshot = await client.fetch(
        gistId: diagnosticsGist,
        deviceRef: 'device-0',
      );
      // Then: last successful temperature remains sample three, with sensor failure.
      expect(snapshot.sensorState, 'error');
      expect(snapshot.lastSampleRef, 'host-boot:3');
      expect(snapshot.heartbeatSeq, 5);
      expect(snapshot.gistUpdatedAt, DateTime.utc(2026, 1, 2, 3, 20));
      expect(
        snapshot.events.where((event) => event.code == 'sensor_failed'),
        hasLength(2),
      );
    },
    skip: skip,
  );
}
