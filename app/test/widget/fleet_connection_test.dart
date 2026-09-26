import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:farmctl/features/fleet/data/fleet_connection_store.dart';
import 'package:farmctl/features/fleet/data/fleet_contents_client.dart';
import 'package:farmctl/features/fleet/providers/fleet_providers.dart';
import 'package:farmctl/features/fleet/view/fleet_configuration_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage implements FleetConnectionStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _Adapter implements HttpClientAdapter {
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    final content = jsonEncode({
      'schema_version': 1,
      'fleet_revision': '11111111-1111-4111-8111-111111111111',
      'devices': {
        'device-a': {
          'change_id': '22222222-2222-4222-8222-222222222222',
          'logical_id': 'monitor-a',
          'wifi_profiles': [
            {
              'profile_id': 'primary',
              'ssid': 'private-wifi',
              'password': 'password123',
            },
          ],
          'config_read_credential': 'private-read-credential',
          'temperature_gist_id': 'a' * 32,
          'diagnostics_gist_id': 'b' * 32,
          'gist_write_credential': 'private-write-credential',
          'sample_interval_seconds': 60,
          'publication_interval_seconds': 300,
        },
      },
    });
    final payload = jsonEncode({
      'type': 'file',
      'encoding': 'base64',
      'sha': 'c' * 40,
      'content': base64Encode(utf8.encode(content)),
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
  testWidgets('saves private connection without echoing writer token', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = _MemoryStorage();
    final adapter = _Adapter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          fleetConnectionStorageProvider.overrideWithValue(storage),
          fleetClientFactoryProvider.overrideWithValue(
            (connection) => FleetContentsClient(
              owner: connection.owner,
              repository: connection.repo,
              branch: connection.branch,
              path: connection.path,
              token: connection.writerToken,
              dio: Dio()..httpClientAdapter = adapter,
            ),
          ),
        ],
        child: const MaterialApp(home: FleetConfigurationPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Repository owner'),
      'farm-owner',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Repository name'),
      'private-fleet',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Writer token'),
      'secret-writer-token',
    );
    await tester.ensureVisible(find.text('Save connection'));
    await tester.tap(find.text('Save connection'));
    await tester.pumpAndSettle();

    expect(storage.values.values, contains('farm-owner'));
    expect(storage.values.values, contains('private-fleet'));
    expect(storage.values.values, contains('secret-writer-token'));
    final tokenField = tester.widget<TextFormField>(
      find.widgetWithText(TextFormField, 'Writer token'),
    );
    expect(tokenField.controller!.text, isEmpty);
    expect(
      find.text('Connection saved securely on this phone.'),
      findsOneWidget,
    );
    expect(
      adapter.request,
      isNull,
      reason: 'Opening the form must not fetch automatically.',
    );
    await tester.ensureVisible(find.text('Fetch desired state'));
    await tester.tap(find.text('Fetch desired state'));
    await tester.pumpAndSettle();
    expect(
      adapter.request!.headers['Authorization'],
      'Bearer secret-writer-token',
    );
    expect(find.textContaining('monitor-a'), findsOneWidget);
    expect(find.text('private-wifi'), findsNothing);
    expect(find.text('private-read-credential'), findsNothing);
    expect(find.text('private-write-credential'), findsNothing);
  });

  testWidgets('clearing connection removes credentials and remains read-only', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final storage = _MemoryStorage()
      ..values.addAll({
        'fleet_connection_v1_owner': 'owner',
        'fleet_connection_v1_repo': 'repo',
        'fleet_connection_v1_branch': 'main',
        'fleet_connection_v1_path': 'fleet.json',
        'fleet_connection_v1_writer_token': 'private-token',
      });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [fleetConnectionStorageProvider.overrideWithValue(storage)],
        child: const MaterialApp(home: FleetConfigurationPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Editing unlocks after compatibility check'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Device-applied status is not available yet. Changes cannot be submitted from FarmCtl.',
      ),
      findsOneWidget,
    );
    expect(find.text('private-token'), findsNothing);
    expect(find.text('Save changes'), findsNothing);
    await tester.ensureVisible(find.text('Clear connection'));
    await tester.tap(find.text('Clear connection'));
    await tester.pumpAndSettle();
    expect(storage.values, isEmpty);
    expect(find.text('Saved connection cleared.'), findsOneWidget);
  });
}
