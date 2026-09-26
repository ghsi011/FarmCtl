import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/device_diagnostics.dart';

const int diagnosticsMaxResponseBytes = 262144;
const int diagnosticsMaxFileBytes = 65536;

class DeviceDiagnosticsException implements Exception {
  const DeviceDiagnosticsException(
    this.message, {
    this.kind = DeviceDiagnosticsErrorKind.unavailable,
  });

  final String message;
  final DeviceDiagnosticsErrorKind kind;

  @override
  String toString() => 'DeviceDiagnosticsException: $message';
}

enum DeviceDiagnosticsErrorKind {
  unavailable,
  invalidAssociation,
  redirect,
  oversized,
  malformed,
  unsupportedSchema,
  deviceReferenceMismatch,
  invalidFields,
  cancelled,
  timedOut,
}

/// A dedicated, read-only GitHub API path. It intentionally never follows a
/// `raw_url` (or any redirect), and only consumes the embedded diagnostics file.
class GitHubDeviceDiagnosticsClient {
  GitHubDeviceDiagnosticsClient({
    Dio? dio,
    required this.githubToken,
    DateTime Function()? clock,
    this.transactionTimeout = const Duration(seconds: 20),
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 5),
               receiveTimeout: const Duration(seconds: 10),
               sendTimeout: const Duration(seconds: 10),
             ),
           ),
       _clock = clock ?? _now;

  final Dio _dio;
  final String? githubToken;
  final DateTime Function() _clock;
  final Duration transactionTimeout;

  static DateTime _now() => DateTime.now().toUtc();

  Future<DeviceDiagnosticsSnapshot> fetch({
    required String gistId,
    required String deviceRef,
    CancelToken? cancelToken,
  }) async {
    if (!RegExp(r'^[0-9a-fA-F]{32,40}$').hasMatch(gistId) ||
        deviceRef.isEmpty ||
        deviceRef.length > 256) {
      throw const DeviceDiagnosticsException(
        'Invalid diagnostics association.',
        kind: DeviceDiagnosticsErrorKind.invalidAssociation,
      );
    }
    final token = cancelToken ?? CancelToken();
    try {
      return await _fetchSnapshot(
        gistId: gistId,
        deviceRef: deviceRef,
        cancelToken: token,
      ).timeout(
        transactionTimeout,
        onTimeout: () {
          if (!token.isCancelled) {
            token.cancel('Diagnostics transaction timed out.');
          }
          throw const DeviceDiagnosticsException(
            'Diagnostics request timed out.',
            kind: DeviceDiagnosticsErrorKind.timedOut,
          );
        },
      );
    } on DeviceDiagnosticsException {
      rethrow;
    } on DioException {
      throw const DeviceDiagnosticsException('Diagnostics fetch failed.');
    } on FormatException {
      throw const DeviceDiagnosticsException(
        'Diagnostics JSON is invalid.',
        kind: DeviceDiagnosticsErrorKind.malformed,
      );
    } on Object {
      throw const DeviceDiagnosticsException(
        'Diagnostics response is invalid.',
      );
    }
  }

  Future<DeviceDiagnosticsSnapshot> _fetchSnapshot({
    required String gistId,
    required String deviceRef,
    required CancelToken cancelToken,
  }) async {
    try {
      final response = await _dio.get<ResponseBody>(
        'https://api.github.com/gists/$gistId',
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          receiveDataWhenStatusError: true,
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 10),
          sendTimeout: const Duration(seconds: 10),
          headers: {
            HttpHeaders.acceptHeader: 'application/vnd.github+json',
            HttpHeaders.userAgentHeader: 'farmctl/0.1',
            'X-GitHub-Api-Version': '2022-11-28',
            if (githubToken != null && githubToken!.isNotEmpty)
              HttpHeaders.authorizationHeader: 'token $githubToken',
          },
        ),
        cancelToken: cancelToken,
      );
      if ((response.statusCode ?? 0) >= 300 &&
          (response.statusCode ?? 0) < 400) {
        await _cancelResponseBody(response, cancelToken);
        throw const DeviceDiagnosticsException(
          'Diagnostics redirect rejected.',
          kind: DeviceDiagnosticsErrorKind.redirect,
        );
      }
      if (response.statusCode != 200) {
        await _cancelResponseBody(response, cancelToken);
        throw const DeviceDiagnosticsException('Diagnostics request failed.');
      }
      final body = await _readBounded(
        response,
        diagnosticsMaxResponseBytes,
        cancelToken,
      );
      final decoded = _decodeObject(utf8.decode(body, allowMalformed: false));
      final files = decoded['files'];
      if (files is! Map<String, dynamic>) {
        throw const DeviceDiagnosticsException('Diagnostics file missing.');
      }
      final file = files['diagnostics.json'];
      if (file is! Map<String, dynamic> || file['truncated'] == true) {
        throw const DeviceDiagnosticsException('Diagnostics file unavailable.');
      }
      final content = file['content'];
      if (content is! String ||
          utf8.encode(content).length > diagnosticsMaxFileBytes) {
        throw const DeviceDiagnosticsException(
          'Diagnostics file exceeds limit.',
          kind: DeviceDiagnosticsErrorKind.oversized,
        );
      }
      final snapshotData = _decodeObject(content);
      if (snapshotData['schema_version'] != 1) {
        throw const DeviceDiagnosticsException(
          'Unsupported diagnostics schema.',
          kind: DeviceDiagnosticsErrorKind.unsupportedSchema,
        );
      }
      if (snapshotData['device_ref'] != deviceRef) {
        throw const DeviceDiagnosticsException(
          'Diagnostics device reference mismatch.',
          kind: DeviceDiagnosticsErrorKind.deviceReferenceMismatch,
        );
      }
      final firmware = snapshotData['firmware'];
      final firmwareRunning = firmware is Map<String, dynamic>
          ? firmware['running']
          : null;
      final sensor = snapshotData['sensor'];
      final sensorState = sensor is Map<String, dynamic>
          ? sensor['state']
          : null;
      final failures = sensor is Map<String, dynamic>
          ? sensor['consecutive_failures']
          : null;
      final heartbeat = snapshotData['heartbeat_seq'];
      final rawSampleRef = sensor is Map<String, dynamic>
          ? sensor['last_sample_ref']
          : null;
      final rawReportedAt = snapshotData['reported_at'];
      if (firmwareRunning is! String ||
          firmwareRunning.isEmpty ||
          firmwareRunning.length > 64 ||
          !RegExp(r'^[A-Za-z0-9._+-]+$').hasMatch(firmwareRunning) ||
          sensorState is! String ||
          !_allowedSensorStates.contains(sensorState) ||
          failures is! int ||
          failures < 0 ||
          failures > 2147483647 ||
          heartbeat is! int ||
          heartbeat < 0 ||
          heartbeat > 2147483647) {
        throw const DeviceDiagnosticsException(
          'Diagnostics fields are invalid.',
          kind: DeviceDiagnosticsErrorKind.invalidFields,
        );
      }
      final lastSampleRef = _optionalOpaque(rawSampleRef);
      if (sensor is! Map<String, dynamic> ||
          !sensor.containsKey('last_sample_ref') ||
          (rawSampleRef != null && lastSampleRef == null)) {
        throw const DeviceDiagnosticsException(
          'Diagnostics fields are invalid.',
          kind: DeviceDiagnosticsErrorKind.invalidFields,
        );
      }
      final reportedAt = _optionalTimestamp(rawReportedAt);
      if (!snapshotData.containsKey('reported_at') ||
          (rawReportedAt != null && reportedAt == null)) {
        throw const DeviceDiagnosticsException(
          'Diagnostics fields are invalid.',
          kind: DeviceDiagnosticsErrorKind.invalidFields,
        );
      }
      final events = _parseEvents(snapshotData['events']);
      final droppedEvents = snapshotData['dropped_events'] ?? 0;
      if (droppedEvents is! int ||
          droppedEvents < 0 ||
          droppedEvents > 2147483647) {
        throw const DeviceDiagnosticsException(
          'Diagnostics fields are invalid.',
          kind: DeviceDiagnosticsErrorKind.invalidFields,
        );
      }
      final gistUpdatedAt = _optionalTimestamp(decoded['updated_at']);
      return DeviceDiagnosticsSnapshot(
        deviceRef: deviceRef,
        firmwareRunning: firmwareRunning,
        sensorState: sensorState,
        consecutiveFailures: failures,
        heartbeatSeq: heartbeat,
        gistUpdatedAt: gistUpdatedAt,
        fetchedAt: _clock().toUtc(),
        lastSampleRef: lastSampleRef,
        reportedAt: reportedAt,
        events: events,
        droppedEvents: droppedEvents,
      );
    } on DeviceDiagnosticsException {
      rethrow;
    } on FormatException {
      throw const DeviceDiagnosticsException(
        'Diagnostics JSON is invalid.',
        kind: DeviceDiagnosticsErrorKind.malformed,
      );
    } on Object {
      // Avoid propagating decoder, transport, or implementation details: these
      // can contain response fragments, URLs, or credentials.
      throw const DeviceDiagnosticsException(
        'Diagnostics response is invalid.',
      );
    }
  }

  static const _allowedSensorStates = <String>{
    'ok',
    'healthy',
    'error',
    'fault',
    'offline',
    'unknown',
    'initializing',
  };

  static const _allowedEventCodes = <String>{
    'sensor_recovered',
    'sensor_failed',
    'temperature_publish_failed',
  };

  static List<DeviceDiagnosticsEvent> _parseEvents(Object? raw) {
    if (raw is! List || raw.length > 100) {
      throw const DeviceDiagnosticsException(
        'Diagnostics fields are invalid.',
        kind: DeviceDiagnosticsErrorKind.invalidFields,
      );
    }
    final result = <DeviceDiagnosticsEvent>[];
    final ids = <String>{};
    for (final value in raw) {
      if (value is! Map<String, dynamic>) {
        throw const DeviceDiagnosticsException(
          'Diagnostics fields are invalid.',
          kind: DeviceDiagnosticsErrorKind.invalidFields,
        );
      }
      final rawId = value['id'];
      // Pico supplies the origin boot ID as part of the event's immutable ID.
      // Do not use snapshot boot_id: old events remain in later snapshots.
      final id =
          rawId is String &&
              RegExp(r'^[A-Za-z0-9._-]{1,64}:[0-9]{1,10}$').hasMatch(rawId)
          ? rawId
          : null;
      final code = value['code'];
      final count = value['count'];
      final rawTime = value['occurred_at'];
      final occurredAt = rawTime == null ? null : _optionalTimestamp(rawTime);
      final uptime = value['uptime_s'];
      if (id == null ||
          !ids.add(id) ||
          code is! String ||
          !_allowedEventCodes.contains(code) ||
          count is! int ||
          count < 1 ||
          count > 2147483647 ||
          (rawTime != null && occurredAt == null) ||
          (uptime != null &&
              (uptime is! int || uptime < 0 || uptime > 2147483647))) {
        throw const DeviceDiagnosticsException(
          'Diagnostics fields are invalid.',
          kind: DeviceDiagnosticsErrorKind.invalidFields,
        );
      }
      result.add(
        DeviceDiagnosticsEvent(
          id: id,
          code: code,
          count: count,
          occurredAt: occurredAt,
          uptimeSeconds: uptime as int?,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  static Future<Uint8List> _readBounded(
    Response<ResponseBody> response,
    int limit,
    CancelToken cancelToken,
  ) async {
    final header = response.headers.value(HttpHeaders.contentLengthHeader);
    final declared = int.tryParse(header ?? '');
    final stream = response.data?.stream;
    if (declared != null && declared > limit) {
      cancelToken.cancel('Diagnostics response exceeds limit.');
      if (stream != null) {
        await stream.listen(null).cancel();
      }
      throw const DeviceDiagnosticsException(
        'Diagnostics response exceeds limit.',
        kind: DeviceDiagnosticsErrorKind.oversized,
      );
    }
    if (stream == null) {
      throw const DeviceDiagnosticsException(
        'Diagnostics response is invalid.',
        kind: DeviceDiagnosticsErrorKind.malformed,
      );
    }
    if (cancelToken.isCancelled) {
      throw const DeviceDiagnosticsException(
        'Diagnostics request was cancelled.',
        kind: DeviceDiagnosticsErrorKind.cancelled,
      );
    }
    final completer = Completer<Uint8List>();
    final bytes = BytesBuilder(copy: false);
    var totalBytes = 0;
    var finished = false;
    late StreamSubscription<Uint8List> subscription;

    void fail(DeviceDiagnosticsException error) {
      if (finished) return;
      finished = true;
      completer.completeError(error);
      unawaited(subscription.cancel());
    }

    subscription = stream.listen(
      (chunk) {
        totalBytes += chunk.length;
        if (totalBytes > limit) {
          cancelToken.cancel('Diagnostics response exceeds limit.');
          fail(
            const DeviceDiagnosticsException(
              'Diagnostics response exceeds limit.',
              kind: DeviceDiagnosticsErrorKind.oversized,
            ),
          );
          return;
        }
        bytes.add(chunk);
      },
      onError: (Object _, StackTrace stackTrace) => fail(
        const DeviceDiagnosticsException('Diagnostics response is invalid.'),
      ),
      onDone: () {
        if (finished) return;
        finished = true;
        completer.complete(bytes.takeBytes());
      },
      cancelOnError: true,
    );
    cancelToken.whenCancel.then((_) {
      fail(
        const DeviceDiagnosticsException(
          'Diagnostics request was cancelled.',
          kind: DeviceDiagnosticsErrorKind.cancelled,
        ),
      );
    });
    return completer.future;
  }

  static Future<void> _cancelResponseBody(
    Response<ResponseBody> response,
    CancelToken cancelToken,
  ) async {
    final stream = response.data?.stream;
    if (!cancelToken.isCancelled) {
      cancelToken.cancel('Diagnostics response was rejected.');
    }
    if (stream == null) return;
    try {
      await stream.listen(null).cancel();
    } on Object {
      // Deliberately discard transport details.
    }
  }

  static Map<String, dynamic> _decodeObject(String raw) {
    Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      throw const DeviceDiagnosticsException(
        'Diagnostics JSON is invalid.',
        kind: DeviceDiagnosticsErrorKind.malformed,
      );
    }
    if (value is! Map<String, dynamic>) {
      throw const DeviceDiagnosticsException(
        'Diagnostics JSON is invalid.',
        kind: DeviceDiagnosticsErrorKind.malformed,
      );
    }
    return value;
  }

  static String? _optionalOpaque(Object? value) =>
      value is String && value.isNotEmpty && value.length <= 256 ? value : null;

  static DateTime? _optionalTimestamp(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}
