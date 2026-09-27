import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:farmctl/features/fleet/data/fleet_contents_client.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.status, this.body, {this.headers = const {}});
  final int status;
  final Stream<Uint8List> body;
  final Map<String, List<String>> headers;
  RequestOptions? request;
  bool requestCancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    cancelFuture?.then((_) => requestCancelled = true);
    return ResponseBody(body, status, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

class _FailingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      message: 'sensitive-test-token read-token private payload',
      type: DioExceptionType.connectionError,
    );
  }

  @override
  void close({bool force = false}) {}
}

String _fleetContent() => jsonEncode({
  'schema_version': 1,
  'fleet_revision': '11111111-1111-4111-8111-111111111111',
  'devices': {
    'device-a': {
      'change_id': '22222222-2222-4222-8222-222222222222',
      'logical_id': 'monitor-a',
      'wifi_profiles': [
        {'profile_id': 'primary', 'ssid': 'Farm', 'password': 'password123'},
      ],
      'config_read_credential': 'read-token',
      'temperature_gist_id': 'a' * 32,
      'diagnostics_gist_id': 'b' * 32,
      'gist_write_credential': 'write-token',
      'sample_interval_seconds': 60,
      'publication_interval_seconds': 300,
    },
  },
});

String _payload({
  String type = 'file',
  String encoding = 'base64',
  String sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  List<int>? content,
}) => jsonEncode({
  'type': type,
  'encoding': encoding,
  'sha': sha,
  'content': base64Encode(content ?? utf8.encode(_fleetContent())),
  'download_url': 'https://private.example/never-use',
});

FleetContentsClient _client(_Adapter adapter) => FleetContentsClient(
  owner: 'farmctl',
  repository: 'config',
  branch: 'main',
  path: 'fleet.json',
  token: 'sensitive-test-token',
  dio: Dio()..httpClientAdapter = adapter,
);

Stream<Uint8List> _body(String data) =>
    Stream.value(Uint8List.fromList(utf8.encode(data)));

void main() {
  test(
    'fetches a validated file via the pinned API URI and captures blob SHA',
    () async {
      final adapter = _Adapter(200, _body(_payload()));
      final snapshot = await _client(adapter).fetch();
      expect(snapshot.content, _fleetContent());
      expect(snapshot.blobSha, 'a' * 40);
      expect(adapter.request!.followRedirects, isFalse);
      expect(adapter.request!.uri.host, 'api.github.com');
      expect(adapter.request!.uri.queryParameters['ref'], 'main');
      expect(
        adapter.request!.headers['Authorization'],
        'Bearer sensitive-test-token',
      );
    },
  );

  test(
    'rejects redirects, malformed file metadata, directory response, and oversized body',
    () async {
      for (final invalid in [
        _Adapter(
          302,
          _body('redirect'),
          headers: const {
            'location': ['https://private.example/file'],
          },
        ),
        _Adapter(200, _body(_payload(type: 'dir'))),
        _Adapter(200, _body(_payload(encoding: 'utf-8'))),
        _Adapter(200, _body(_payload(sha: 'not-a-blob-sha'))),
        _Adapter(200, _body(_payload(content: utf8.encode('{malformed')))),
        _Adapter(
          200,
          _body(
            _payload(
              content: utf8.encode(
                _fleetContent() +
                    (' ' * (FleetContentsClient.maxContentBytes + 1)),
              ),
            ),
          ),
        ),
        _Adapter(200, _body(_payload(content: const []))),
        _Adapter(
          200,
          Stream<Uint8List>.value(
            Uint8List(FleetContentsClient.maxResponseBytes + 1),
          ),
        ),
      ]) {
        await expectLater(
          _client(invalid).fetch(),
          throwsA(isA<FleetContentsException>()),
        );
      }
    },
  );

  test('does not include a supplied token in exception text', () async {
    final adapter = _Adapter(302, _body('redirect'));
    try {
      await _client(adapter).fetch();
      fail('Expected redirect refusal.');
    } on FleetContentsException catch (error) {
      expect(error.toString(), isNot(contains('sensitive-test-token')));
    }
  });

  test('sanitizes response stream errors that contain a private URI', () async {
    final adapter = _Adapter(
      200,
      Stream<Uint8List>.error(
        HttpException(
          'private stream detail',
          uri: Uri.parse(
            'https://private.example/file?token=private-uri-token',
          ),
        ),
      ),
    );
    final client = _client(adapter);
    try {
      await expectLater(
        client.fetch(),
        throwsA(
          isA<FleetContentsException>().having(
            (error) => error.toString(),
            'message',
            allOf(
              isNot(contains('private.example')),
              isNot(contains('private-uri-token')),
              isNot(contains('sensitive-test-token')),
              isNot(contains('private stream detail')),
            ),
          ),
        ),
      );
    } finally {
      client.close();
    }
  });

  test(
    'oversized stream cancels the request and stops upstream delivery',
    () async {
      late StreamController<Uint8List> controller;
      var cancelled = false;
      var emitted = 0;
      controller = StreamController<Uint8List>(
        onListen: () {
          emitted++;
          controller.add(Uint8List(FleetContentsClient.maxResponseBytes + 1));
          Future<void>.delayed(const Duration(milliseconds: 10), () {
            if (!cancelled) {
              emitted++;
              controller.add(Uint8List(1));
            }
          });
        },
        onCancel: () => cancelled = true,
      );
      final adapter = _Adapter(200, controller.stream);
      final client = _client(adapter);
      try {
        await expectLater(
          client.fetch(),
          throwsA(isA<FleetContentsException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(cancelled, isTrue);
        expect(adapter.requestCancelled, isTrue);
        expect(emitted, 1);
      } finally {
        client.close();
        await controller.close();
      }
    },
  );

  test(
    'PUT transport errors omit token and submitted secret content',
    () async {
      final client = FleetContentsClient(
        owner: 'farmctl',
        repository: 'config',
        branch: 'main',
        path: 'fleet.json',
        token: 'sensitive-test-token',
        dio: Dio()..httpClientAdapter = _FailingAdapter(),
      );
      try {
        await expectLater(
          client.putFile(content: _fleetContent(), blobSha: 'a' * 40),
          throwsA(
            isA<FleetContentsException>()
                .having(
                  (error) => error.toString(),
                  'message',
                  isNot(contains('sensitive-test-token')),
                )
                .having(
                  (error) => error.toString(),
                  'message',
                  isNot(contains('read-token')),
                ),
          ),
        );
      } finally {
        client.close();
      }
    },
  );
}
