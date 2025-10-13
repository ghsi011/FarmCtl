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
}
