import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:farmctl/features/fleet/data/fleet_configuration_service.dart';
import 'package:farmctl/features/fleet/data/fleet_contents_client.dart';
import 'package:farmctl/features/fleet/models/fleet_configuration.dart';
import 'package:flutter_test/flutter_test.dart';

const _revision = '11111111-1111-4111-8111-111111111111';
const _changeA = '22222222-2222-4222-8222-222222222222';
const _changeB = '33333333-3333-4333-8333-333333333333';
const _freshRevision = '44444444-4444-4444-8444-444444444444';
const _freshChange = '55555555-5555-4555-8555-555555555555';
const _secondRevision = '66666666-6666-4666-8666-666666666666';
const _secondChange = '77777777-7777-4777-8777-777777777777';
const _blobSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _commitSha = 'cccccccccccccccccccccccccccccccccccccccc';

String _device(String change, String logical) => jsonEncode({
  'change_id': change,
  'logical_id': logical,
  'wifi_profiles': [
    {'profile_id': 'primary', 'ssid': 'Farm', 'password': 'password123'},
  ],
  'config_read_credential': 'read-secret-value',
  'temperature_gist_id': 'a' * 32,
  'diagnostics_gist_id': 'b' * 32,
  'gist_write_credential': 'write-secret-value',
  'sample_interval_seconds': 60,
  'publication_interval_seconds': 300,
});

String _baseContent({bool twoDevices = true}) {
  final devices = <String, Object?>{
    'device-a': jsonDecode(_device(_changeA, 'monitor-a')),
    if (twoDevices) 'device-b': jsonDecode(_device(_changeB, 'monitor-b')),
  };
  return jsonEncode({
    'schema_version': 1,
    'fleet_revision': _revision,
    'devices': devices,
  });
}

FleetContentsSnapshot _baseSnapshot({bool twoDevices = true}) =>
    FleetContentsSnapshot(
      content: _baseContent(twoDevices: twoDevices),
      blobSha: _blobSha,
    );

FleetDeviceConfiguration _edited(
  FleetConfiguration base, {
  String ref = 'device-a',
  String? logical,
}) {
  final original = base.devices[ref]!;
  return FleetDeviceConfiguration(
    changeId: '66666666-6666-4666-8666-666666666666',
    logicalId: logical ?? '${original.logicalId}-edited',
    wifiProfiles: original.wifiProfiles,
    configReadCredential: original.configReadCredential,
    temperatureGistId: original.temperatureGistId,
    diagnosticsGistId: original.diagnosticsGistId,
    gistWriteCredential: original.gistWriteCredential,
    sampleIntervalSeconds: 60,
    publicationIntervalSeconds: original.publicationIntervalSeconds,
  );
}

String _submittedContent(RequestOptions options) {
  final Object? data = options.data;
  final String body;
  if (data is String) {
    body = data;
  } else if (data is List<int>) {
    body = utf8.decode(data);
  } else {
    throw StateError('Unexpected mocked request body representation.');
  }
  final request = jsonDecode(body) as Map<String, dynamic>;
  return utf8.decode(base64Decode(request['content'] as String));
}

Map<String, dynamic> _putBody(RequestOptions options) =>
    jsonDecode(options.data as String) as Map<String, dynamic>;

ResponseBody _response(int status, String content, {String? commitSha}) {
  final String body;
  if (status == 200 || status == 201) {
    body = jsonEncode({
      'content': {
        'type': 'file',
        'encoding': 'base64',
        'sha': _blobSha,
        'content': base64Encode(utf8.encode(content)),
      },
      if (commitSha != null) 'commit': {'sha': commitSha},
    });
  } else {
    body = jsonEncode({'message': 'conflict'});
  }
  return ResponseBody(
    Stream.value(Uint8List.fromList(utf8.encode(body))),
    status,
  );
}

ResponseBody _getResponse(String content) => ResponseBody(
  Stream.value(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'type': 'file',
          'encoding': 'base64',
          'sha': _blobSha,
          'content': base64Encode(utf8.encode(content)),
        }),
      ),
    ),
  ),
  200,
);

class _Adapter implements HttpClientAdapter {
  _Adapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions request) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return await handler(options);
  }

  @override
  void close({bool force = false}) {}
}

FleetConfigurationService _service(_Adapter adapter) =>
    FleetConfigurationService(
      FleetContentsClient(
        owner: 'farmctl',
        repository: 'config',
        branch: 'main',
        path: 'fleet.json',
        token: 'phone-writer-secret',
        dio: Dio()..httpClientAdapter = adapter,
      ),
      uuidV4: () => _generatedIds.removeAt(0),
    );

final _generatedIds = <String>[
  _freshRevision,
  _freshChange,
  _secondRevision,
  _secondChange,
];

void main() {
  setUp(
    () => _generatedIds
      ..clear()
      ..addAll([_freshRevision, _freshChange, _secondRevision, _secondChange]),
  );

  test(
    'uses saved blob SHA, preserves other change ID, then verifies exact bytes',
    () async {
      var remote = _baseSnapshot().content;
      final adapter = _Adapter((request) {
        if (request.method == 'PUT') {
          final body = _putBody(request);
          expect(body['sha'], _blobSha);
          expect(body['branch'], 'main');
          remote = _submittedContent(request);
          return _response(200, '{}', commitSha: _commitSha);
        }
        return _getResponse(remote);
      });
      final service = _service(adapter);
      final base = FleetConfiguration.parse(_baseSnapshot().content);
      final result = await service.submit(
        baseSnapshot: _baseSnapshot(),
        deviceRef: 'device-a',
        editedDeviceConfig: _edited(base),
      );
      expect(result.status, FleetSubmissionStatus.submittedPending);
      expect(result.commitSha, _commitSha);
      expect(result.revision, _freshRevision);
      expect(result.changeId, _freshChange);
      expect(adapter.requests.map((request) => request.method), ['PUT', 'GET']);
      final saved = FleetConfiguration.parse(remote);
      expect(saved.devices['device-a']!.changeId, _freshChange);
      expect(saved.devices['device-b']!.changeId, _changeB);
      expect(adapter.requests.first.followRedirects, isFalse);
      expect(adapter.requests.first.uri.host, 'api.github.com');
    },
  );

  test('rejects unknown device and duplicate logical ID before PUT', () async {
    final adapter = _Adapter((_) => _getResponse(_baseSnapshot().content));
    final service = _service(adapter);
    final snapshot = _baseSnapshot();
    final base = FleetConfiguration.parse(snapshot.content);
    await expectLater(
      service.submit(
        baseSnapshot: snapshot,
        deviceRef: 'unknown-device',
        editedDeviceConfig: _edited(base),
      ),
      throwsA(isA<FleetSubmissionException>()),
    );
    await expectLater(
      service.submit(
        baseSnapshot: snapshot,
        deviceRef: 'device-a',
        editedDeviceConfig: _edited(base, logical: 'monitor-b'),
      ),
      throwsA(isA<FleetSubmissionException>()),
    );
    expect(adapter.requests, isEmpty);
  });

  test(
    'two writers retain the same original SHA and second writer must reapply',
    () async {
      var remote = _baseSnapshot().content;
      var puts = 0;
      final adapter = _Adapter((request) {
        if (request.method == 'PUT') {
          expect(_putBody(request)['sha'], _blobSha);
          puts++;
          if (puts == 1) {
            remote = _submittedContent(request);
            return _response(200, '{}', commitSha: _commitSha);
          }
          return _response(409, '{}');
        }
        return _getResponse(remote);
      });
      final service = _service(adapter);
      final savedBase = _baseSnapshot();
      final baseConfig = FleetConfiguration.parse(savedBase.content);
      final first = await service.submit(
        baseSnapshot: savedBase,
        deviceRef: 'device-a',
        editedDeviceConfig: _edited(baseConfig),
      );
      final second = await service.submit(
        baseSnapshot: savedBase,
        deviceRef: 'device-b',
        editedDeviceConfig: _edited(baseConfig, ref: 'device-b'),
      );
      expect(first.status, FleetSubmissionStatus.submittedPending);
      expect(second.status, FleetSubmissionStatus.needsReapply);
      expect(second.latestSnapshot, isNotNull);
      expect(puts, 2);
      expect(adapter.requests.where((r) => r.method == 'GET'), hasLength(2));
    },
  );

  test(
    'lost PUT response confirms pending only on exact fresh readback',
    () async {
      for (final exact in [true, false]) {
        String remote = _baseSnapshot().content;
        var putCount = 0;
        final adapter = _Adapter((request) {
          if (request.method == 'PUT') {
            putCount++;
            if (exact) remote = _submittedContent(request);
            throw DioException(
              requestOptions: request,
              type: DioExceptionType.connectionError,
            );
          }
          return _getResponse(remote);
        });
        final savedBase = _baseSnapshot();
        final result = await _service(adapter).submit(
          baseSnapshot: savedBase,
          deviceRef: 'device-a',
          editedDeviceConfig: _edited(
            FleetConfiguration.parse(savedBase.content),
          ),
        );
        expect(
          result.status,
          exact
              ? FleetSubmissionStatus.submittedPending
              : FleetSubmissionStatus.needsReapply,
        );
        expect(result.commitSha, isNull);
        expect(putCount, 1);
        expect(adapter.requests.map((r) => r.method), ['PUT', 'GET']);
      }
    },
  );

  test(
    'stream error after PUT headers triggers one safe recovery GET',
    () async {
      final adapter = _Adapter((request) {
        if (request.method == 'PUT') {
          return ResponseBody(
            Stream<Uint8List>.error(
              HttpException(
                'secret stream body detail',
                uri: Uri.parse(
                  'https://private.example/file?token=private-uri-token',
                ),
              ),
            ),
            200,
          );
        }
        return _getResponse(_baseSnapshot().content);
      });
      final snapshot = _baseSnapshot();
      final result = await _service(adapter).submit(
        baseSnapshot: snapshot,
        deviceRef: 'device-a',
        editedDeviceConfig: _edited(FleetConfiguration.parse(snapshot.content)),
      );
      expect(result.status, FleetSubmissionStatus.needsReapply);
      expect(adapter.requests.map((request) => request.method), ['PUT', 'GET']);
      expect(
        adapter.requests.where((request) => request.method == 'PUT'),
        hasLength(1),
      );
      expect(result.toString(), isNot(contains('private.example')));
      expect(result.toString(), isNot(contains('private-uri-token')));
      expect(result.toString(), isNot(contains('phone-writer-secret')));
      expect(result.toString(), isNot(contains('read-secret-value')));
    },
  );

  test('serializes concurrent local PUT requests on one client', () async {
    final firstPutStarted = Completer<void>();
    final releaseFirstPut = Completer<void>();
    var activePuts = 0;
    var maximumConcurrentPuts = 0;
    var putCount = 0;
    var remote = _baseSnapshot().content;
    final adapter = _Adapter((request) async {
      if (request.method == 'PUT') {
        putCount++;
        activePuts++;
        if (activePuts > maximumConcurrentPuts) {
          maximumConcurrentPuts = activePuts;
        }
        if (putCount == 1) {
          firstPutStarted.complete();
          await releaseFirstPut.future;
          remote = _submittedContent(request);
          activePuts--;
          return _response(200, '{}', commitSha: _commitSha);
        }
        activePuts--;
        return _response(409, '{}');
      }
      return _getResponse(remote);
    });
    final service = _service(adapter);
    final savedBase = _baseSnapshot();
    final config = FleetConfiguration.parse(savedBase.content);
    final first = service.submit(
      baseSnapshot: savedBase,
      deviceRef: 'device-a',
      editedDeviceConfig: _edited(config),
    );
    await firstPutStarted.future;
    final second = service.submit(
      baseSnapshot: savedBase,
      deviceRef: 'device-b',
      editedDeviceConfig: _edited(config, ref: 'device-b'),
    );
    expect(putCount, 1);
    releaseFirstPut.complete();
    final results = await Future.wait([first, second]);
    expect(maximumConcurrentPuts, 1);
    expect(results.map((result) => result.status), [
      FleetSubmissionStatus.submittedPending,
      FleetSubmissionStatus.needsReapply,
    ]);
  });

  test('redirected PUT is not followed or reported as success', () async {
    final adapter = _Adapter((request) {
      if (request.method == 'PUT') {
        return ResponseBody(
          Stream.value(Uint8List.fromList(utf8.encode('redirect'))),
          302,
          headers: const {
            'location': ['https://private.example/file'],
          },
        );
      }
      return _getResponse(_baseSnapshot().content);
    });
    final snapshot = _baseSnapshot();
    final result = await _service(adapter).submit(
      baseSnapshot: snapshot,
      deviceRef: 'device-a',
      editedDeviceConfig: _edited(FleetConfiguration.parse(snapshot.content)),
    );
    expect(result.status, FleetSubmissionStatus.needsReapply);
    expect(adapter.requests.map((r) => r.method), ['PUT', 'GET']);
    expect(adapter.requests.first.followRedirects, isFalse);
    expect(adapter.requests.first.uri.host, 'api.github.com');
  });
}
