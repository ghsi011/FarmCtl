import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:farmctl_parsing/temperature_parser.dart';

import '../models/thermostat_state.dart';

abstract class ThermostatNetworkDataSource {
  Future<ThermostatFetchSuccess> fetchCurrent(String url);
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
  Future<ThermostatFetchSuccess> fetchCurrent(String url) async {
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          headers: const {HttpHeaders.acceptHeader: 'text/plain'},
        ),
      );

      final statusCode = response.statusCode ?? 0;
      if (statusCode != 200) {
        throw ThermostatFetchException(
          status: ThermostatReadingStatus.httpError,
          statusCode: statusCode,
          message: 'Request failed with status $statusCode.',
        );
      }

      final body = response.data ?? '';
      final value = parseCelsiusTemperature(body);
      if (value == null) {
        throw ThermostatFetchException(
          status: ThermostatReadingStatus.parseError,
          message: 'Response did not include a Celsius temperature.',
        );
      }

      final fetchedAt = DateTime.now().toUtc();
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
          message: 'Request failed with status $statusCode.',
          cause: error,
        );
      }
      final isTimeout =
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout;
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.networkError,
        message: isTimeout
            ? 'Request timed out. Check the URL and try again.'
            : 'Failed to reach the thermostat source.',
        cause: error,
      );
    } catch (error) {
      throw ThermostatFetchException(
        status: ThermostatReadingStatus.networkError,
        message: 'Failed to fetch thermostat data.',
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
