import 'dart:io';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:farmctl_parsing/temperature_parser.dart';

import '../models/thermostat_state.dart';

abstract class ThermostatNetworkDataSource {
  Future<ThermostatFetchSuccess> fetchCurrent(String gistId);
}

class ThermostatHttpClient implements ThermostatNetworkDataSource {
  ThermostatHttpClient({Dio? dio}) : _dio = dio ?? _createDio();

  final Dio _dio;

  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
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
      return _fetchFromGistApi(input);
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

  bool _looksLikeGistId(String input) {
    // Gist IDs are hex, typically 32 or 40 chars depending on legacy/full length.
    final re = RegExp(r'^[0-9a-fA-F]{32,40}$');
    return re.hasMatch(input);
  }

  Future<ThermostatFetchSuccess> _fetchFromGistApi(String gistId) async {
    try {
      final response = await _dio.get<String>(
        'https://api.github.com/gists/$gistId',
        options: Options(
          responseType: ResponseType.plain,
          headers: const {
            HttpHeaders.acceptHeader: 'application/vnd.github+json',
            HttpHeaders.userAgentHeader: 'farmctl/0.1',
          },
        ),
      );

      final statusCode = response.statusCode ?? 0;
      if (statusCode != 200) {
        throw ThermostatFetchException(
          status: ThermostatReadingStatus.httpError,
          statusCode: statusCode,
          message: 'Gist API failed with status $statusCode.',
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

      // Choose a file: prefer names containing 'thermostat' or '.txt', else first.
      MapEntry<String, dynamic> chosen = files.entries.first;
      for (final entry in files.entries) {
        final name = entry.key.toLowerCase();
        if (name.contains('thermostat') || name.endsWith('.txt')) {
          chosen = entry;
          break;
        }
      }

      final fileObj = chosen.value as Map<String, dynamic>;
      final bool truncated = (fileObj['truncated'] as bool?) ?? false;
      String? content = fileObj['content'] as String?;
      if (content == null || truncated) {
        final rawUrl = fileObj['raw_url'] as String?;
        if (rawUrl == null || rawUrl.isEmpty) {
          throw ThermostatFetchException(
            status: ThermostatReadingStatus.parseError,
            message: 'Gist file content unavailable.',
          );
        }
        // Fallback: fetch the raw content.
        final rawResp = await _dio.get<String>(
          rawUrl,
          options: Options(
            responseType: ResponseType.plain,
            headers: const {HttpHeaders.acceptHeader: 'text/plain'},
          ),
        );
        if ((rawResp.statusCode ?? 0) != 200) {
          throw ThermostatFetchException(
            status: ThermostatReadingStatus.httpError,
            statusCode: rawResp.statusCode ?? 0,
            message: 'Raw fetch failed with status ${rawResp.statusCode}.',
          );
        }
        content = rawResp.data ?? '';
      }

      final value = parseCelsiusTemperature(content);
      if (value == null) {
        throw ThermostatFetchException(
          status: ThermostatReadingStatus.parseError,
          message: 'Gist content did not include a Celsius temperature.',
        );
      }

      final fetchedAt = DateTime.now().toUtc();
      // ETag may be present on raw fetch; GitHub API ETag is not stable for parsing here.
      final etag = response.headers.value(HttpHeaders.etagHeader);
      return ThermostatFetchSuccess(
        valueC: value,
        fetchedAt: fetchedAt,
        etag: etag,
      );
    } on ThermostatFetchException {
      rethrow;
    } on DioException catch (error) {
      if (error.type == DioExceptionType.badResponse) {
        final statusCode = error.response?.statusCode ?? 0;
        throw ThermostatFetchException(
          status: ThermostatReadingStatus.httpError,
          statusCode: statusCode,
          message: 'Gist API failed with status $statusCode.',
          cause: error,
        );
      }
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
}

// Removed URL normalization: we accept only Gist IDs now.

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
