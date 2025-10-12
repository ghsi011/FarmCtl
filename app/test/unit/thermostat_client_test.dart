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
  test('fetchCurrent returns parsed temperature', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        expect(options.headers[HttpHeaders.acceptHeader], 'text/plain');
        return ResponseBody.fromString('Temperature: 12.5 C', 200);
      });

    final client = ThermostatHttpClient(dio: dio);

    final result = await client.fetchCurrent('https://example.com/raw');

    expect(result.valueC, closeTo(12.5, 0.0001));
    expect(result.etag, isNull);
    expect(
      DateTime.now().difference(result.fetchedAt).inSeconds.abs(),
      lessThan(5),
    );
  });

  test('fetchCurrent throws on parse error', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter(
        (options) async => ResponseBody.fromString('invalid payload', 200),
      );
    final client = ThermostatHttpClient(dio: dio);

    expect(
      () => client.fetchCurrent('https://example.com/raw'),
      throwsA(
        isA<ThermostatFetchException>().having(
          (error) => error.status,
          'status',
          ThermostatReadingStatus.parseError,
        ),
      ),
    );
  });

  test('fetchCurrent throws on http error', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter(
        (options) async => ResponseBody.fromString('not found', 404),
      );
    final client = ThermostatHttpClient(dio: dio);

    expect(
      () => client.fetchCurrent('https://example.com/raw'),
      throwsA(
        isA<ThermostatFetchException>().having(
          (error) => error.status,
          'status',
          ThermostatReadingStatus.httpError,
        ),
      ),
    );
  });

  test('fetchCurrent throws on network error', () async {
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
      () => client.fetchCurrent('https://example.com/raw'),
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
