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

    final fixedNow = DateTime.utc(2025, 6, 27, 12);
    final client = ThermostatHttpClient(dio: dio, clock: () => fixedNow);

    final result = await client.fetchCurrent(
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );

    expect(result.valueC, closeTo(12.5, 0.0001));
    // Injected clock removes the previous wall-clock dependency.
    expect(result.fetchedAt, fixedNow);
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

  test('rejects an invalid Gist ID without hitting the network', () async {
    var called = false;
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        called = true;
        return ResponseBody.fromString('', 200);
      });
    final client = ThermostatHttpClient(dio: dio);

    await expectLater(
      () => client.fetchHistory('not-a-gist-id'),
      throwsA(
        isA<ThermostatFetchException>().having(
          (error) => error.status,
          'status',
          ThermostatReadingStatus.parseError,
        ),
      ),
    );
    expect(called, isFalse);
  });

  test('fetchHistory maps a non-200 commits response to httpError', () async {
    // Without validateStatus this 500 would throw before reaching the status
    // check and be relabelled networkError (M-4 regression guard).
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        return ResponseBody.fromString('{"message":"boom"}', 500);
      });
    final client = ThermostatHttpClient(dio: dio); // no token -> no anon path

    await expectLater(
      () => client.fetchHistory('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
      throwsA(
        isA<ThermostatFetchException>().having(
          (error) => error.status,
          'status',
          ThermostatReadingStatus.httpError,
        ),
      ),
    );
  });

  test('listCommits maps a 5xx response to httpError', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        return ResponseBody.fromString('{"message":"unavailable"}', 503);
      });
    final client = ThermostatHttpClient(dio: dio);

    await expectLater(
      () => client.listCommits('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
      throwsA(
        isA<ThermostatFetchException>().having(
          (error) => error.status,
          'status',
          ThermostatReadingStatus.httpError,
        ),
      ),
    );
  });

  test('fetchCurrent maps malformed JSON on a 200 to parseError', () async {
    final dio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        return ResponseBody.fromString('definitely not json', 200);
      });
    final client = ThermostatHttpClient(dio: dio);

    await expectLater(
      () => client.fetchCurrent('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
      throwsA(
        isA<ThermostatFetchException>().having(
          (error) => error.status,
          'status',
          ThermostatReadingStatus.parseError,
        ),
      ),
    );
  });

  test('fetchHistory falls back to the anonymous client on a 403', () async {
    final jsonHeaders = {
      Headers.contentTypeHeader: [ContentType.json.mimeType],
    };
    // The authenticated client is rate-limited (403) on every request.
    final authDio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        return ResponseBody.fromString(
          '{"message":"API rate limit exceeded"}',
          403,
          headers: jsonHeaders,
        );
      });
    // The anonymous client serves both the commit list and the revision body.
    final anonDio = Dio()
      ..httpClientAdapter = _FakeAdapter((options) async {
        if (options.path.endsWith('/commits')) {
          return ResponseBody.fromString(
            '[{"version":"rev1","committed_at":"2025-01-02T10:00:00Z"}]',
            200,
            headers: jsonHeaders,
          );
        }
        if (options.path.contains('rev1')) {
          return ResponseBody.fromString(
            '{"files":{"thermostat.txt":{"truncated":false,"content":"Temperature: 10.5 C"}}}',
            200,
            headers: jsonHeaders,
          );
        }
        return ResponseBody.fromString('not found', 404);
      });

    final client = ThermostatHttpClient(
      dio: authDio,
      dioNoAuth: anonDio,
      githubToken: 'ghp_token',
    );

    final samples = await client.fetchHistory(
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(samples, hasLength(1));
    expect(samples.first.revisionId, 'rev1');
    expect(samples.first.valueC, 10.5);
  });

  test(
    'fetchHistory reports an anonymous-fallback failure as httpError',
    () async {
      // Authenticated request is rate-limited (403); the anonymous fallback then
      // fails with a 5xx. The error must surface as httpError, not parseError.
      final authDio = Dio()
        ..httpClientAdapter = _FakeAdapter((options) async {
          return ResponseBody.fromString('{"message":"rate limited"}', 403);
        });
      final anonDio = Dio()
        ..httpClientAdapter = _FakeAdapter((options) async {
          return ResponseBody.fromString('{"message":"server error"}', 500);
        });
      final client = ThermostatHttpClient(
        dio: authDio,
        dioNoAuth: anonDio,
        githubToken: 'ghp_token',
      );

      await expectLater(
        () => client.fetchHistory('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
        throwsA(
          isA<ThermostatFetchException>().having(
            (error) => error.status,
            'status',
            ThermostatReadingStatus.httpError,
          ),
        ),
      );
    },
  );
}
