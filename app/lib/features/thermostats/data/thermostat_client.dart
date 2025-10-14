import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:farmctl_parsing/temperature_parser.dart';

import '../models/thermostat_state.dart';

abstract class ThermostatNetworkDataSource {
  Future<ThermostatFetchSuccess> fetchCurrent(String gistId);
  Future<List<ThermostatHistorySample>> fetchHistory(String gistId);
  Future<List<GistCommit>> listCommits(
    String gistId, {
    int page = 1,
    int perPage = 100,
  });
  Future<double?> fetchRevisionValue(String gistId, String revisionId);
}

class ThermostatHttpClient implements ThermostatNetworkDataSource {
  ThermostatHttpClient({
    Dio? dio,
    String? githubToken,
    bool allowAnonFallback = true,
  }) : _resolvedToken =
           githubToken ??
           Platform.environment['FARMCTL_GITHUB_TOKEN'] ??
           Platform.environment['GITHUB_TOKEN'],
       _dio =
           dio ??
           _createDio(
             githubToken ??
                 Platform.environment['FARMCTL_GITHUB_TOKEN'] ??
                 Platform.environment['GITHUB_TOKEN'],
           ),
       _dioNoAuth = _createDio(null),
       _hasGithubToken = (() {
         final token =
             githubToken ??
             Platform.environment['FARMCTL_GITHUB_TOKEN'] ??
             Platform.environment['GITHUB_TOKEN'];
         return token != null && token.isNotEmpty;
       })(),
       _allowAnonFallback = allowAnonFallback;

  final Dio _dio;
  final Dio _dioNoAuth;
  final String? _resolvedToken;
  final bool _hasGithubToken;
  final bool _allowAnonFallback;
  static const int _maxHistoryCommits =
      60; // cap history requests to reduce API load

  static Dio _createDio([String? githubToken]) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
        headers: () {
          final headers = <String, dynamic>{
            HttpHeaders.userAgentHeader: 'farmctl/0.1',
            HttpHeaders.acceptHeader: 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
          };
          final token =
              githubToken ??
              Platform.environment['FARMCTL_GITHUB_TOKEN'] ??
              Platform.environment['GITHUB_TOKEN'];
          if (token != null && token.isNotEmpty) {
            headers[HttpHeaders.authorizationHeader] = 'token $token';
          }
          return headers;
        }(),
      ),
    );
    dio.interceptors.add(
      RetryInterceptor(
        dio: dio,
        logPrint: (_) {},
        retries: 2,
        retryDelays: const [Duration(seconds: 1), Duration(seconds: 3)],
        retryEvaluator: (error, attempt) {
          if (error.type == DioExceptionType.badResponse) {
            final status = error.response?.statusCode ?? 0;
            return status >= 500 && status < 600;
          }
          return error.type == DioExceptionType.connectionTimeout ||
              error.type == DioExceptionType.sendTimeout ||
              error.type == DioExceptionType.receiveTimeout ||
              error.type == DioExceptionType.connectionError ||
              error.type == DioExceptionType.unknown;
        },
      ),
    );
    return dio;
  }

  bool get hasGithubToken => _hasGithubToken;
  String? get resolvedToken => _resolvedToken;

  @override
  Future<ThermostatFetchSuccess> fetchCurrent(String gistId) async {
    try {
      final input = gistId.trim();
      if (!_looksLikeGistId(input)) {
        throw ThermostatFetchException(
          status: ThermostatReadingStatus.parseError,
          message: 'Invalid Gist ID.',
        );
      }
      final snapshot = await _fetchSnapshot(
        'https://api.github.com/gists/$input',
      );
      return ThermostatFetchSuccess(
        valueC: snapshot.value,
        fetchedAt: DateTime.now().toUtc(),
        etag: snapshot.etag,
      );
    } on ThermostatFetchException {
      rethrow;
    } on DioException catch (error) {
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.networkError,
        message: 'Failed to reach GitHub Gist API.',
        cause: error,
      );
    } catch (error) {
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.networkError,
        message: 'Failed to fetch from Gist API.',
        cause: error,
      );
    }
  }

  @override
  Future<List<ThermostatHistorySample>> fetchHistory(String gistId) async {
    try {
      final input = gistId.trim();
      if (!_looksLikeGistId(input)) {
        throw ThermostatFetchException(
          status: ThermostatReadingStatus.parseError,
          message: 'Invalid Gist ID.',
        );
      }

      final response = await _dio.get<String>(
        'https://api.github.com/gists/$input/commits',
        options: Options(
          responseType: ResponseType.plain,
          headers: _resolvedToken != null && _resolvedToken.isNotEmpty
              ? {HttpHeaders.authorizationHeader: 'token $_resolvedToken'}
              : null,
        ),
        queryParameters: {
          // Limit the number of commits we fetch to avoid excessive API calls
          'per_page': _maxHistoryCommits,
        },
      );
      if (response.statusCode == 403 && _hasGithubToken && _allowAnonFallback) {
        final anon = await _dioNoAuth.get<String>(
          'https://api.github.com/gists/$input/commits',
          options: Options(
            responseType: ResponseType.plain,
            headers: const {
              HttpHeaders.acceptHeader: 'application/vnd.github+json',
            },
          ),
          queryParameters: {'per_page': _maxHistoryCommits},
        );
        // Continue with anon response
        final raw = anon.data ?? '[]';
        final decoded = jsonDecode(raw) as List<dynamic>;
        final samples = <ThermostatHistorySample>[];
        var processed = 0;
        for (final entry in decoded) {
          if (processed >= _maxHistoryCommits) break;
          if (entry is! Map<String, dynamic>) continue;
          final revisionId = entry['version'] as String?;
          final committedAtRaw = entry['committed_at'] as String?;
          if (revisionId == null || committedAtRaw == null) continue;
          DateTime observedAt;
          try {
            observedAt = DateTime.parse(committedAtRaw).toUtc();
          } catch (_) {
            continue;
          }
          final value = await _fetchRevisionValue(input, revisionId);
          if (value == null) continue;
          samples.add(
            ThermostatHistorySample(
              revisionId: revisionId,
              valueC: value,
              observedAt: observedAt,
            ),
          );
          processed += 1;
        }
        samples.sort((a, b) => a.observedAt.compareTo(b.observedAt));
        return samples;
      }

      final statusCode = response.statusCode ?? 0;
      if (statusCode != 200) {
        String? reason;
        try {
          final data =
              jsonDecode(response.data ?? '{}') as Map<String, dynamic>;
          reason = data['message'] as String?;
        } catch (_) {
          reason = null;
        }
        throw ThermostatFetchException(
          status: ThermostatReadingStatus.httpError,
          statusCode: statusCode,
          message: reason != null && reason.isNotEmpty
              ? 'Gist commits API failed: $reason (HTTP $statusCode)'
              : 'Gist commits API failed with status $statusCode.',
        );
      }

      final raw = response.data ?? '[]';
      final decoded = jsonDecode(raw) as List<dynamic>;
      final samples = <ThermostatHistorySample>[];

      var processed = 0;
      for (final entry in decoded) {
        if (processed >= _maxHistoryCommits) {
          break;
        }
        if (entry is! Map<String, dynamic>) {
          continue;
        }
        final revisionId = entry['version'] as String?;
        final committedAtRaw = entry['committed_at'] as String?;
        if (revisionId == null || committedAtRaw == null) {
          continue;
        }
        DateTime observedAt;
        try {
          observedAt = DateTime.parse(committedAtRaw).toUtc();
        } catch (_) {
          continue;
        }

        final value = await _fetchRevisionValue(input, revisionId);
        if (value == null) {
          continue;
        }

        samples.add(
          ThermostatHistorySample(
            revisionId: revisionId,
            valueC: value,
            observedAt: observedAt,
          ),
        );
        processed += 1;
      }

      samples.sort((a, b) => a.observedAt.compareTo(b.observedAt));
      return samples;
    } on ThermostatFetchException {
      rethrow;
    } on DioException catch (error) {
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.networkError,
        message: 'Failed to fetch Gist history.',
        cause: error,
      );
    } catch (error) {
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.networkError,
        message: 'Failed to load history from Gist.',
        cause: error,
      );
    }
  }

  @override
  Future<List<GistCommit>> listCommits(
    String gistId, {
    int page = 1,
    int perPage = 100,
  }) async {
    try {
      final input = gistId.trim();
      if (!_looksLikeGistId(input)) {
        throw ThermostatFetchException(
          status: ThermostatReadingStatus.parseError,
          message: 'Invalid Gist ID.',
        );
      }

      final response = await _dio.get<String>(
        'https://api.github.com/gists/$input/commits',
        options: Options(
          responseType: ResponseType.plain,
          headers: _resolvedToken != null && _resolvedToken.isNotEmpty
              ? {HttpHeaders.authorizationHeader: 'token $_resolvedToken'}
              : null,
        ),
        queryParameters: {'page': page, 'per_page': perPage},
      );
      if (response.statusCode == 403 && _hasGithubToken) {
        final anon = await _dioNoAuth.get<String>(
          'https://api.github.com/gists/$input/commits',
          options: Options(
            responseType: ResponseType.plain,
            headers: const {
              HttpHeaders.acceptHeader: 'application/vnd.github+json',
            },
          ),
          queryParameters: {'page': page, 'per_page': perPage},
        );
        return _parseCommitsList(anon);
      }

      return _parseCommitsList(response);
    } on ThermostatFetchException {
      rethrow;
    } on DioException catch (error) {
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.networkError,
        message: 'Failed to fetch Gist commit list.',
        cause: error,
      );
    } catch (error) {
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.networkError,
        message: 'Failed to load commit list from Gist.',
        cause: error,
      );
    }
  }

  List<GistCommit> _parseCommitsList(Response<String> response) {
    final statusCode = response.statusCode ?? 0;
    if (statusCode != 200) {
      String? reason;
      try {
        final data = jsonDecode(response.data ?? '{}') as Map<String, dynamic>;
        reason = data['message'] as String?;
      } catch (_) {
        reason = null;
      }
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.httpError,
        statusCode: statusCode,
        message: reason != null && reason.isNotEmpty
            ? 'Gist commits API failed: $reason (HTTP $statusCode)'
            : 'Gist commits API failed with status $statusCode.',
      );
    }
    final raw = response.data ?? '[]';
    final decoded = jsonDecode(raw) as List<dynamic>;
    final commits = <GistCommit>[];
    for (final entry in decoded) {
      if (entry is! Map<String, dynamic>) continue;
      final revisionId = entry['version'] as String?;
      final committedAtRaw = entry['committed_at'] as String?;
      if (revisionId == null || committedAtRaw == null) continue;
      DateTime observedAt;
      try {
        observedAt = DateTime.parse(committedAtRaw).toUtc();
      } catch (_) {
        continue;
      }
      commits.add(GistCommit(revisionId: revisionId, observedAt: observedAt));
    }
    return commits;
  }

  @override
  Future<double?> fetchRevisionValue(String gistId, String revisionId) {
    return _fetchRevisionValue(gistId, revisionId);
  }

  bool _looksLikeGistId(String input) {
    final re = RegExp(r'^[0-9a-fA-F]{32,40}$');
    return re.hasMatch(input);
  }

  Future<_SnapshotResult> _fetchSnapshot(String url) async {
    final authHeaders = <String, dynamic>{
      HttpHeaders.acceptHeader: 'application/vnd.github+json',
      HttpHeaders.userAgentHeader: 'farmctl/0.1',
      if (_resolvedToken != null && _resolvedToken.isNotEmpty)
        HttpHeaders.authorizationHeader: 'token $_resolvedToken',
    };
    final response = await _dio.get<String>(
      url,
      options: Options(
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
        headers: authHeaders,
      ),
    );
    if (response.statusCode == 403 && _hasGithubToken && _allowAnonFallback) {
      final anon = await _dioNoAuth.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: const {
            HttpHeaders.acceptHeader: 'application/vnd.github+json',
            HttpHeaders.userAgentHeader: 'farmctl/0.1',
          },
          validateStatus: (_) => true,
        ),
      );
      return _parseSnapshot(anon);
    }
    return _parseSnapshot(response);
  }

  Future<_SnapshotResult> _parseSnapshot(Response<String> response) async {
    final statusCode = response.statusCode ?? 0;
    if (statusCode != 200) {
      String? reason;
      try {
        final data = jsonDecode(response.data ?? '{}') as Map<String, dynamic>;
        reason = data['message'] as String?;
      } catch (_) {
        reason = null;
      }
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.httpError,
        statusCode: statusCode,
        message: reason != null && reason.isNotEmpty
            ? 'Gist API failed: $reason (HTTP $statusCode)'
            : 'Gist API failed with status $statusCode.',
      );
    }

    final raw = response.data ?? '';
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final files = (decoded['files'] as Map<String, dynamic>?) ?? {};
    if (files.isEmpty) {
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.parseError,
        message: 'Gist contains no files.',
      );
    }

    final chosen = _selectFile(files);
    final content = await _resolveFileContent(
      chosen.value as Map<String, dynamic>,
    );
    final value = parseCelsiusTemperature(content);
    if (value == null) {
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.parseError,
        message: 'Gist content did not include a Celsius temperature.',
      );
    }

    final etag = response.headers.value(HttpHeaders.etagHeader);
    return _SnapshotResult(value: value, etag: etag);
  }

  Future<double?> _fetchRevisionValue(String gistId, String revisionId) async {
    try {
      final snapshot = await _fetchSnapshot(
        'https://api.github.com/gists/$gistId/$revisionId',
      );
      return snapshot.value;
    } on ThermostatFetchException catch (error) {
      if (error.status == ThermostatReadingStatus.parseError ||
          error.status == ThermostatReadingStatus.httpError) {
        return null;
      }
      rethrow;
    }
  }

  MapEntry<String, dynamic> _selectFile(Map<String, dynamic> files) {
    MapEntry<String, dynamic> chosen = files.entries.first;
    for (final entry in files.entries) {
      final name = entry.key.toLowerCase();
      if (name.contains('thermostat') || name.endsWith('.txt')) {
        chosen = entry;
        break;
      }
    }
    return chosen;
  }

  Future<String> _resolveFileContent(Map<String, dynamic> fileObj) async {
    final bool truncated = (fileObj['truncated'] as bool?) ?? false;
    String? content = fileObj['content'] as String?;
    if (content != null && !truncated) {
      return content;
    }

    final rawUrl = fileObj['raw_url'] as String?;
    if (rawUrl == null || rawUrl.isEmpty) {
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.parseError,
        message: 'Gist file content unavailable.',
      );
    }

    try {
      final rawResp = await _dio.get<String>(
        rawUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: {
            HttpHeaders.acceptHeader: 'text/plain',
            if (_resolvedToken != null && _resolvedToken.isNotEmpty)
              HttpHeaders.authorizationHeader: 'token $_resolvedToken',
          },
        ),
      );
      if ((rawResp.statusCode ?? 0) == 403 && _hasGithubToken) {
        final anon = await _dioNoAuth.get<String>(
          rawUrl,
          options: Options(
            responseType: ResponseType.plain,
            headers: const {HttpHeaders.acceptHeader: 'text/plain'},
          ),
        );
        if ((anon.statusCode ?? 0) == 200) {
          return anon.data ?? '';
        }
        return anon.data ?? '';
      }
      if ((rawResp.statusCode ?? 0) != 200) {
        throw ThermostatFetchException(
          status: ThermostatReadingStatus.httpError,
          statusCode: rawResp.statusCode ?? 0,
          message: 'Raw fetch failed with status ${rawResp.statusCode}.',
        );
      }
      return rawResp.data ?? '';
    } on DioException catch (error) {
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.networkError,
        message: 'Failed to fetch raw gist content.',
        cause: error,
      );
    }
  }
}

class ThermostatFetchSuccess {
  const ThermostatFetchSuccess({
    required this.valueC,
    required this.fetchedAt,
    this.etag,
  });

  final double valueC;
  final DateTime fetchedAt;
  final String? etag;
}

class ThermostatFetchException implements Exception {
  const ThermostatFetchException({
    required this.status,
    required this.message,
    this.statusCode,
    this.cause,
  });

  final ThermostatReadingStatus status;
  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() =>
      'ThermostatFetchException(status: ${status.name}, message: $message, statusCode: $statusCode)';
}

class ThermostatHistorySample {
  const ThermostatHistorySample({
    required this.revisionId,
    required this.valueC,
    required this.observedAt,
  });

  final String revisionId;
  final double valueC;
  final DateTime observedAt;
}

class _SnapshotResult {
  const _SnapshotResult({required this.value, this.etag});

  final double value;
  final String? etag;
}

class GistCommit {
  const GistCommit({required this.revisionId, required this.observedAt});

  final String revisionId;
  final DateTime observedAt;
}
