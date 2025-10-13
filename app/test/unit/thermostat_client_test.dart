import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:farmctl/features/thermostats/data/thermostat_client.dart';
import 'package:farmctl/features/thermostats/models/thermostat_state.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this._handler);

  final Future<ResponseBody> Function(RequestOptions options) _handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return _handler(options);
  }
}

void main() {
  test('fetchCurrent returns parsed temperature (Gist API)', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        if (options.path.contains('/gists/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')) {
          expect(
            options.headers[HttpHeaders.acceptHeader],
            'application/vnd.github+json',
          );
          return ResponseBody.fromString(
            '{"files": {"thermostat.txt": {"filename": "thermostat.txt", "truncated": false, "content": "Temperature: 12.5 C"}}}',
            200,
            headers: {
              Headers.contentTypeHeader: [ContentType.json.mimeType],
            },
          );
        }
        return ResponseBody.fromString('not found', 404);
      });

    final client = ThermostatHttpClient(dio: dio);

    final result = await client.fetchCurrent(
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );

    expect(result.valueC, closeTo(12.5, 0.0001));
    expect(
      DateTime.now().difference(result.fetchedAt).inSeconds.abs(),
      lessThan(5),
    );
  });

  test('fetchCurrent throws on parse error (Gist API)', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        if (options.path.contains('/gists/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')) {
          return ResponseBody.fromString(
            '{"files": {"thermostat.txt": {"filename": "thermostat.txt", "truncated": false, "content": "invalid payload"}}}',
            200,
            headers: {
              Headers.contentTypeHeader: [ContentType.json.mimeType],
            },
          );
        }
        return ResponseBody.fromString('not found', 404);
      });
    final client = ThermostatHttpClient(dio: dio);

    expect(
      () => client.fetchCurrent('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'),
      throwsA(
        isA<ThermostatFetchException>().having(
          (error) => error.status,
          'status',
          ThermostatReadingStatus.parseError,
        ),
      ),
    );
  });

  test('fetchCurrent throws on http error (Gist API)', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        if (options.path.contains('/gists/cccccccccccccccccccccccccccccccc')) {
          return ResponseBody.fromString('not found', 404);
        }
        return ResponseBody.fromString('not found', 404);
      });
    final client = ThermostatHttpClient(dio: dio);

    expect(
      () => client.fetchCurrent('cccccccccccccccccccccccccccccccc'),
      throwsA(
        isA<ThermostatFetchException>().having(
          (error) => error.status,
          'status',
          ThermostatReadingStatus.httpError,
        ),
      ),
    );
  });

  test('fetchCurrent throws on network error (Gist API)', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: const SocketException('Failed host lookup'),
        );
      });
    final client = ThermostatHttpClient(dio: dio);

    expect(
      () => client.fetchCurrent('dddddddddddddddddddddddddddddddd'),
      throwsA(
        isA<ThermostatFetchException>().having(
          (error) => error.status,
          'status',
          ThermostatReadingStatus.networkError,
        ),
      ),
    );
  });

  test('fetchHistory returns sorted revision samples', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        if (options.path.endsWith('/commits')) {
          return ResponseBody.fromString(
            '[{"version":"rev2","committed_at":"2025-01-02T12:00:00Z"},{"version":"rev1","committed_at":"2025-01-02T10:00:00Z"}]',
            200,
            headers: {
              Headers.contentTypeHeader: [ContentType.json.mimeType],
            },
          );
        }
        if (options.path.contains('rev2')) {
          return ResponseBody.fromString(
            '{"files": {"thermostat.txt": {"truncated": false, "content": "Temperature: 11.0 C"}}}',
            200,
            headers: {
              Headers.contentTypeHeader: [ContentType.json.mimeType],
            },
          );
        }
        if (options.path.contains('rev1')) {
          return ResponseBody.fromString(
            '{"files": {"thermostat.txt": {"truncated": false, "content": "Temperature: 10.5 C"}}}',
            200,
            headers: {
              Headers.contentTypeHeader: [ContentType.json.mimeType],
            },
          );
        }
        return ResponseBody.fromString('not found', 404);
      });
    final client = ThermostatHttpClient(dio: dio);

    final samples = await client.fetchHistory(
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(samples, hasLength(2));
    expect(samples.first.valueC, 10.5);
    expect(samples.last.revisionId, 'rev2');
  });
}
