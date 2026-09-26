import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:farmctl/features/thermostats/data/device_diagnostics_client.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);
}

const _gist = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _token = 'secret-token-not-for-errors';
const _deviceRef = 'opaque-42';

String _payload({String? content, String updatedAt = '2026-01-02T03:04:05Z'}) =>
    jsonEncode({
      'updated_at': updatedAt,
      'files': {
        'diagnostics.json': {
          'truncated': false,
          'content':
              content ??
              jsonEncode({
                'schema_version': 1,
                'device_ref': _deviceRef,
                'boot_id': 'boot-opaque-7',
                'heartbeat_seq': 18,
                'firmware': {'running': '1.2.3'},
                'sensor': {
                  'state': 'ok',
                  'consecutive_failures': 0,
                  'last_sample_ref': 'sample-9',
                },
                'reported_at': '2026-01-02T03:03:00Z',
                'configuration': {'applied_id': null, 'last_attempt': null},
                'events': [
                  {
                    'id': 'boot-opaque-7:9',
                    'code': 'sensor_failed',
                    'count': 3,
                    'occurred_at': null,
                    'uptime_s': 120,
                  },
                ],
                'dropped_events': 2,
                'exception': 'never persist or display this',
                'token': _token,
              }),
        },
      },
    });

void main() {
  late DateTime fixedNow;
  setUp(() => fixedNow = DateTime.utc(2026, 1, 2, 3, 5));

  Dio clientDio({
    required int status,
    required List<int> bytes,
    Map<String, List<String>>? headers,
    void Function(RequestOptions options)? inspect,
  }) => Dio()
    ..httpClientAdapter = _FakeAdapter((options) async {
      inspect?.call(options);
      return ResponseBody.fromBytes(bytes, status, headers: headers);
    });

  test(
    'decodes only allowlisted diagnostics fields with independent fetch time',
    () async {
      final dio = clientDio(
        status: 200,
        bytes: utf8.encode(_payload()),
        inspect: (options) {
          expect(options.uri.host, 'api.github.com');
          expect(options.followRedirects, isFalse);
          expect(
            options.headers[HttpHeaders.authorizationHeader],
            'token $_token',
          );
        },
      );
      final snapshot = await GitHubDeviceDiagnosticsClient(
        dio: dio,
        githubToken: _token,
        clock: () => fixedNow,
      ).fetch(gistId: _gist, deviceRef: _deviceRef);

      expect(snapshot.deviceRef, _deviceRef);
      expect(snapshot.firmwareRunning, '1.2.3');
      expect(snapshot.sensorState, 'ok');
      expect(snapshot.consecutiveFailures, 0);
      expect(snapshot.heartbeatSeq, 18);
      expect(snapshot.lastSampleRef, 'sample-9');
      expect(snapshot.reportedAt, DateTime.utc(2026, 1, 2, 3, 3));
      expect(snapshot.gistUpdatedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(snapshot.fetchedAt, fixedNow);
      expect(snapshot.events, hasLength(1));
      expect(snapshot.events.single.id, 'boot-opaque-7:9');
      expect(snapshot.events.single.count, 3);
      expect(snapshot.events.single.occurredAt, isNull);
      expect(snapshot.events.single.uptimeSeconds, 120);
      expect(snapshot.droppedEvents, 2);
      expect(snapshot.toString(), isNot(contains(_token)));
    },
  );

  test(
    'rejects oversized, unknown-code, and duplicate device events',
    () async {
      for (final events in <Object>[
        List<Object>.generate(
          101,
          (index) => {
            'id': 'boot-a:$index',
            'code': 'sensor_failed',
            'count': 1,
          },
        ),
        [
          {'id': 'boot-a:1', 'code': 'private exception text', 'count': 1},
        ],
        [
          {'id': 'boot-a:1', 'code': 'sensor_failed', 'count': 1},
          {'id': 'boot-a:1', 'code': 'sensor_failed', 'count': 2},
        ],
      ]) {
        final content = jsonEncode({
          'schema_version': 1,
          'device_ref': _deviceRef,
          'heartbeat_seq': 1,
          'firmware': {'running': '1.2.3'},
          'sensor': {
            'state': 'ok',
            'consecutive_failures': 0,
            'last_sample_ref': null,
          },
          'reported_at': null,
          'events': events,
        });
        final client = GitHubDeviceDiagnosticsClient(
          dio: clientDio(
            status: 200,
            bytes: utf8.encode(_payload(content: content)),
          ),
          githubToken: _token,
        );
        await expectLater(
          client.fetch(gistId: _gist, deviceRef: _deviceRef),
          throwsA(
            isA<DeviceDiagnosticsException>().having(
              (error) => error.kind,
              'kind',
              DeviceDiagnosticsErrorKind.invalidFields,
            ),
          ),
        );
      }
    },
  );

  for (final entry in <String, ({int status, String body})>{
    'malformed response': (status: 200, body: '{'),
    'unsupported schema': (
      status: 200,
      body: _payload(content: '{"schema_version":2}'),
    ),
    'mismatched device': (
      status: 200,
      body: _payload(
        content:
            '{"schema_version":1,"device_ref":"other","heartbeat_seq":1,"firmware":{"running":"1.2.3"},"sensor":{"state":"ok","consecutive_failures":0,"last_sample_ref":null},"reported_at":null}',
      ),
    ),
  }.entries) {
    test('rejects ${entry.key} without leaking payload data', () async {
      final client = GitHubDeviceDiagnosticsClient(
        dio: clientDio(
          status: entry.value.status,
          bytes: utf8.encode(entry.value.body),
        ),
        githubToken: _token,
      );
      await expectLater(
        client.fetch(gistId: _gist, deviceRef: _deviceRef),
        throwsA(
          isA<DeviceDiagnosticsException>().having(
            (error) => error.toString(),
            'message',
            isNot(contains(_token)),
          ),
        ),
      );
      if (entry.key == 'malformed response') {
        await expectLater(
          client.fetch(gistId: _gist, deviceRef: _deviceRef),
          throwsA(
            isA<DeviceDiagnosticsException>().having(
              (error) => error.kind,
              'kind',
              DeviceDiagnosticsErrorKind.malformed,
            ),
          ),
        );
      }
    });
  }

  test(
    'rejects old camelCase keys rather than treating them as healthy',
    () async {
      final legacyCamelCase = _payload(
        content:
            '{"schema_version":1,"device_ref":"$_deviceRef","firmware":{"running":"1.2.3"},"sensorState":"ok","consecutiveFailures":0,"heartbeatSeq":18,"lastSampleRef":"sample-9","reportedAt":null}',
      );
      final client = GitHubDeviceDiagnosticsClient(
        dio: clientDio(status: 200, bytes: utf8.encode(legacyCamelCase)),
        githubToken: _token,
      );
      await expectLater(
        client.fetch(gistId: _gist, deviceRef: _deviceRef),
        throwsA(
          isA<DeviceDiagnosticsException>().having(
            (error) => error.kind,
            'kind',
            DeviceDiagnosticsErrorKind.invalidFields,
          ),
        ),
      );
    },
  );

  test('schema and device mismatches have distinct typed error kinds', () async {
    final unsupported = GitHubDeviceDiagnosticsClient(
      dio: clientDio(
        status: 200,
        bytes: utf8.encode(
          _payload(content: '{"schema_version":2,"device_ref":"$_deviceRef"}'),
        ),
      ),
      githubToken: _token,
    );
    await expectLater(
      unsupported.fetch(gistId: _gist, deviceRef: _deviceRef),
      throwsA(
        isA<DeviceDiagnosticsException>().having(
          (error) => error.kind,
          'kind',
          DeviceDiagnosticsErrorKind.unsupportedSchema,
        ),
      ),
    );

    final mismatched = GitHubDeviceDiagnosticsClient(
      dio: clientDio(
        status: 200,
        bytes: utf8.encode(
          _payload(
            content:
                '{"schema_version":1,"device_ref":"wrong","heartbeat_seq":1,"firmware":{"running":"1.2.3"},"sensor":{"state":"ok","consecutive_failures":0,"last_sample_ref":null},"reported_at":null}',
          ),
        ),
      ),
      githubToken: _token,
    );
    await expectLater(
      mismatched.fetch(gistId: _gist, deviceRef: _deviceRef),
      throwsA(
        isA<DeviceDiagnosticsException>().having(
          (error) => error.kind,
          'kind',
          DeviceDiagnosticsErrorKind.deviceReferenceMismatch,
        ),
      ),
    );
  });

  test(
    'requires origin-qualified immutable event IDs, without snapshot boot rewriting',
    () async {
      for (final id in <Object>['4', 4, ':4', 'boot-a:1:2']) {
        final content = jsonEncode({
          'schema_version': 1,
          'device_ref': _deviceRef,
          'heartbeat_seq': 1,
          'boot_id': 'current-boot-b',
          'firmware': {'running': '1.2.3'},
          'sensor': {
            'state': 'ok',
            'consecutive_failures': 0,
            'last_sample_ref': null,
          },
          'reported_at': null,
          'events': [
            {'id': id, 'code': 'sensor_failed', 'count': 2},
          ],
        });
        await expectLater(
          GitHubDeviceDiagnosticsClient(
            dio: clientDio(
              status: 200,
              bytes: utf8.encode(_payload(content: content)),
            ),
            githubToken: _token,
          ).fetch(gistId: _gist, deviceRef: _deviceRef),
          throwsA(
            isA<DeviceDiagnosticsException>().having(
              (error) => error.kind,
              'kind',
              DeviceDiagnosticsErrorKind.invalidFields,
            ),
          ),
        );
      }

      final content = jsonEncode({
        'schema_version': 1,
        'device_ref': _deviceRef,
        'boot_id': 'new-snapshot-boot',
        'heartbeat_seq': 2,
        'firmware': {'running': '1.2.3'},
        'sensor': {
          'state': 'ok',
          'consecutive_failures': 0,
          'last_sample_ref': null,
        },
        'reported_at': null,
        'events': [
          {'id': 'origin-boot-a:9', 'code': 'sensor_failed', 'count': 7},
        ],
      });
      final snapshot = await GitHubDeviceDiagnosticsClient(
        dio: clientDio(
          status: 200,
          bytes: utf8.encode(_payload(content: content)),
        ),
        githubToken: _token,
      ).fetch(gistId: _gist, deviceRef: _deviceRef);
      expect(snapshot.events.single.id, 'origin-boot-a:9');
    },
  );

  test('rejects oversized response before JSON decoding', () async {
    final bytes = utf8.encode(' ' * (diagnosticsMaxResponseBytes + 1));
    final client = GitHubDeviceDiagnosticsClient(
      dio: clientDio(status: 200, bytes: bytes),
      githubToken: _token,
    );
    await expectLater(
      client.fetch(gistId: _gist, deviceRef: _deviceRef),
      throwsA(isA<DeviceDiagnosticsException>()),
    );
  });

  test('rejects oversized embedded file content', () async {
    final client = GitHubDeviceDiagnosticsClient(
      dio: clientDio(
        status: 200,
        bytes: utf8.encode(
          _payload(content: 'x' * (diagnosticsMaxFileBytes + 1)),
        ),
      ),
      githubToken: _token,
    );
    await expectLater(
      client.fetch(gistId: _gist, deviceRef: _deviceRef),
      throwsA(
        isA<DeviceDiagnosticsException>().having(
          (error) => error.kind,
          'kind',
          DeviceDiagnosticsErrorKind.oversized,
        ),
      ),
    );
  });

  test('aborts oversized chunked response without Content-Length', () async {
    var cancelled = false;
    final controller = StreamController<Uint8List>(
      onCancel: () => cancelled = true,
    );
    controller.add(Uint8List(100000)..fillRange(0, 100000, 32));
    controller.add(Uint8List(100000)..fillRange(0, 100000, 32));
    controller.add(Uint8List(100000)..fillRange(0, 100000, 32));
    controller.close();
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        return ResponseBody(controller.stream, 200);
      });
    await expectLater(
      GitHubDeviceDiagnosticsClient(
        dio: dio,
        githubToken: _token,
      ).fetch(gistId: _gist, deviceRef: _deviceRef),
      throwsA(
        isA<DeviceDiagnosticsException>().having(
          (error) => error.kind,
          'kind',
          DeviceDiagnosticsErrorKind.oversized,
        ),
      ),
    );
    expect(cancelled, isTrue);
  });

  test('total deadline cancels a stalled response stream', () async {
    var cancelled = false;
    final controller = StreamController<Uint8List>(
      onCancel: () => cancelled = true,
    );
    controller.add(Uint8List.fromList(utf8.encode('{')));
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        return ResponseBody(controller.stream, 200);
      });
    await expectLater(
      GitHubDeviceDiagnosticsClient(
        dio: dio,
        githubToken: _token,
        transactionTimeout: const Duration(milliseconds: 30),
      ).fetch(gistId: _gist, deviceRef: _deviceRef),
      throwsA(
        isA<DeviceDiagnosticsException>()
            .having(
              (error) => error.kind,
              'kind',
              DeviceDiagnosticsErrorKind.timedOut,
            )
            .having(
              (error) => error.toString(),
              'safe message',
              allOf(
                isNot(contains(_token)),
                isNot(contains('api.github.com')),
                isNot(contains('{')),
              ),
            ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(cancelled, isTrue);
  });

  test('non-200 response body is cancelled and not exposed', () async {
    var cancelled = false;
    final controller = StreamController<Uint8List>(
      onCancel: () => cancelled = true,
    );
    controller.add(Uint8List.fromList(utf8.encode(_token)));
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        return ResponseBody(controller.stream, 403);
      });
    await expectLater(
      GitHubDeviceDiagnosticsClient(
        dio: dio,
        githubToken: _token,
      ).fetch(gistId: _gist, deviceRef: _deviceRef),
      throwsA(
        isA<DeviceDiagnosticsException>().having(
          (error) => error.toString(),
          'safe message',
          isNot(contains(_token)),
        ),
      ),
    );
    expect(cancelled, isTrue);
  });

  test('rejects redirects and does not follow redirect target', () async {
    var requests = 0;
    var cancelled = false;
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        requests++;
        expect(options.followRedirects, isFalse);
        expect(options.uri.host, 'api.github.com');
        expect(
          options.headers[HttpHeaders.authorizationHeader],
          'token $_token',
        );
        final controller = StreamController<Uint8List>(
          onCancel: () => cancelled = true,
        );
        controller.add(Uint8List.fromList(utf8.encode(_token)));
        return ResponseBody(
          controller.stream,
          302,
          headers: {
            'location': ['https://attacker.invalid/collect'],
          },
        );
      });
    await expectLater(
      GitHubDeviceDiagnosticsClient(
        dio: dio,
        githubToken: _token,
      ).fetch(gistId: _gist, deviceRef: _deviceRef),
      throwsA(
        isA<DeviceDiagnosticsException>().having(
          (error) => error.toString(),
          'safe message',
          allOf(isNot(contains(_token)), isNot(contains('attacker.invalid'))),
        ),
      ),
    );
    expect(requests, 1);
    expect(cancelled, isTrue);
  });

  test('maps fetch errors to a redacted typed error', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        throw DioException(
          requestOptions: options,
          message: 'transport exposed $_token',
        );
      });
    await expectLater(
      GitHubDeviceDiagnosticsClient(
        dio: dio,
        githubToken: _token,
      ).fetch(gistId: _gist, deviceRef: _deviceRef),
      throwsA(
        isA<DeviceDiagnosticsException>().having(
          (error) => error.toString(),
          'message',
          isNot(contains(_token)),
        ),
      ),
    );
  });
}
