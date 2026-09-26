import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:farmctl/features/fleet/data/fleet_connection_store.dart';
import 'package:farmctl/features/fleet/data/fleet_contents_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _fleet =
    '''{"schema_version":1,"fleet_revision":"11111111-1111-4111-8111-111111111111","devices":{"monitor-a":{"change_id":"22222222-2222-4222-8222-222222222222","logical_id":"monitor-a","wifi_profiles":[{"profile_id":"primary","ssid":"private-ssid","password":"password123"}],"config_read_credential":"device-read-secret","temperature_gist_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","diagnostics_gist_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","gist_write_credential":"device-write-secret","sample_interval_seconds":60,"publication_interval_seconds":300}}}''';

class _Storage implements FleetConnectionStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Adapter implements HttpClientAdapter {
  int gets = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    gets++;
    final payload = jsonEncode({
      'type': 'file',
      'encoding': 'base64',
      'sha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'content': base64Encode(utf8.encode(_fleet)),
    });
    return ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(payload))),
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'fetches once, holds fleet only in session memory, clears on close',
    () async {
      final storage = _Storage();
      final adapter = _Adapter();
      final store = FleetConnectionStore(
        storage: storage,
        observeLifecycle: false,
        clientFactory: (connection) => FleetContentsClient(
          owner: connection.owner,
          repository: connection.repo,
          branch: connection.branch,
          path: connection.path,
          token: connection.writerToken,
          dio: Dio()..httpClientAdapter = adapter,
        ),
      );
      await store.saveConnection(
        'farm',
        'fleet',
        'main',
        'fleet.json',
        'writer-token',
      );
      final session = await store.openEditSession();
      expect(adapter.gets, 1);
      expect(
        session.configuration.devices['monitor-a']?.wifiProfiles.single.ssid,
        'private-ssid',
      );
      expect(storage.values.values, isNot(contains(_fleet)));
      expect(storage.values.values, isNot(contains('private-ssid')));
      session.close();
      expect(session.isActive, isFalse);
      await expectLater(
        () => session.configuration,
        throwsA(isA<FleetConnectionException>()),
      );
      store.dispose();
    },
  );

  test(
    'expiry and background transition permanently close a session',
    () async {
      final adapter = _Adapter();
      final storage = _Storage();
      final store = FleetConnectionStore(
        storage: storage,
        sessionLifetime: const Duration(milliseconds: 25),
        clientFactory: (connection) => FleetContentsClient(
          owner: connection.owner,
          repository: connection.repo,
          branch: connection.branch,
          path: connection.path,
          token: connection.writerToken,
          dio: Dio()..httpClientAdapter = adapter,
        ),
      );
      await store.saveConnection(
        'farm',
        'fleet',
        'main',
        'fleet.json',
        'writer-token',
      );
      final session = await store.openEditSession();
      await Future<void>.delayed(const Duration(milliseconds: 45));
      expect(session.isActive, isFalse);
      await expectLater(
        () => session.configuration,
        throwsA(isA<FleetConnectionException>()),
      );

      final next = await store.openEditSession();
      store.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(next.isActive, isFalse);
      await expectLater(
        () => next.configuration,
        throwsA(isA<FleetConnectionException>()),
      );
      store.dispose();
    },
  );
}
