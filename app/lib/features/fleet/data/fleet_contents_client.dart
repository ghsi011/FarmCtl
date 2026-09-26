import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/fleet_configuration.dart';

class FleetContentsSnapshot {
  const FleetContentsSnapshot({required this.content, required this.blobSha});
  final String content;
  final String blobSha;
}

/// Reads a single provisioned file from GitHub's fixed Contents API endpoint.
/// This deliberately has no retry interceptor and never follows redirects.
class FleetContentsClient {
  FleetContentsClient({
    required String owner,
    required String repository,
    required String branch,
    required String path,
    required String token,
    Dio? dio,
  }) : _owner = _segment(owner),
       _repository = _segment(repository),
       _branch = _segment(branch),
       _path = _validatePath(path),
       _token = token,
       _dio = dio ?? _createDio() {
    if (token.isEmpty || token.length > 512) {
      throw ArgumentError.value(token.length, 'token', 'Invalid token.');
    }
  }

  static const maxResponseBytes = 262144;
  static const maxContentBytes = 65536;
  static const _totalTimeout = Duration(seconds: 20);
  static const _origin = 'https://api.github.com';
  final String _owner, _repository, _branch, _path, _token;
  final Dio _dio;
  Future<void> _mutationTail = Future<void>.value();

  static Dio _createDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      followRedirects: false,
      maxRedirects: 0,
      headers: const {
        HttpHeaders.acceptHeader: 'application/vnd.github+json',
        HttpHeaders.userAgentHeader: 'FarmCtl',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    ),
  );

  static String _segment(String value) {
    if (!RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(value) ||
        value == '.' ||
        value == '..') {
      throw ArgumentError('Invalid repository configuration.');
    }
    return value;
  }

  static String _validatePath(String value) {
    final parts = value.split('/');
    if (parts.isEmpty ||
        parts.any(
          (part) =>
              part.isEmpty ||
              part == '.' ||
              part == '..' ||
              !RegExp(r'^[A-Za-z0-9_.-]{1,100}$').hasMatch(part),
        )) {
      throw ArgumentError('Invalid repository configuration.');
    }
    return parts.join('/');
  }

  Future<FleetContentsSnapshot> fetch() async {
    final uri = _contentsUri();
    final cancellation = CancelToken();
    final deadline = Stopwatch()..start();
    try {
      final response = await _dio
          .get<ResponseBody>(
            uri.toString(),
            cancelToken: cancellation,
            options: Options(
              responseType: ResponseType.stream,
              validateStatus: (_) => true,
              followRedirects: false,
              maxRedirects: 0,
              headers: {HttpHeaders.authorizationHeader: 'Bearer $_token'},
            ),
          )
          .timeout(
            _remaining(deadline),
            onTimeout: () {
              cancellation.cancel('Request deadline exceeded.');
              throw const FleetContentsException(
                'Repository request timed out.',
              );
            },
          );
      final status = response.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        cancellation.cancel('Repository redirect refused.');
        await response.data?.stream.listen((_) {}).cancel();
        throw const FleetContentsException('Repository redirect refused.');
      }
      if (status != 200) {
        cancellation.cancel('Repository request failed.');
        await response.data?.stream.listen((_) {}).cancel();
        throw FleetContentsException('Repository request failed ($status).');
      }
      final body = response.data;
      if (body == null) {
        cancellation.cancel('Repository response is empty.');
        throw const FleetContentsException('Repository response is empty.');
      }
      final declaredLength = int.tryParse(
        response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      if (declaredLength != null && declaredLength > maxResponseBytes) {
        cancellation.cancel('Repository response exceeds size limit.');
        await body.stream.listen((_) {}).cancel();
        throw const FleetContentsException(
          'Repository response exceeds size limit.',
        );
      }
      final responseBytes = await _readBounded(body.stream, cancellation)
          .timeout(
            _remaining(deadline),
            onTimeout: () {
              cancellation.cancel('Request deadline exceeded.');
              throw const FleetContentsException(
                'Repository request timed out.',
              );
            },
          );
      final raw = utf8.decode(responseBytes, allowMalformed: false);
      final Object? payload;
      try {
        payload = jsonDecode(raw);
      } on FormatException {
        throw const FleetContentsException('Repository response is malformed.');
      }
      if (payload is! Map<String, dynamic> ||
          payload['type'] != 'file' ||
          payload['encoding'] != 'base64' ||
          payload['sha'] is! String ||
          !RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(payload['sha'] as String) ||
          payload['content'] is! String) {
        throw const FleetContentsException(
          'Repository response is not a valid file.',
        );
      }
      // Never use download_url: private download links and redirects are outside
      // the authenticated api.github.com trust boundary.
      final encoded = (payload['content'] as String).replaceAll(
        RegExp(r'\s'),
        '',
      );
      final List<int> bytes;
      try {
        bytes = base64Decode(encoded);
      } on FormatException {
        throw const FleetContentsException('Repository content is malformed.');
      }
      if (bytes.length > maxContentBytes) {
        throw const FleetContentsException('Fleet file exceeds size limit.');
      }
      final content = utf8.decode(bytes, allowMalformed: false);
      if (content.trim().isEmpty) {
        throw const FleetContentsException('Fleet file is empty.');
      }
      FleetConfiguration.parse(content);
      return FleetContentsSnapshot(
        content: content,
        blobSha: payload['sha'] as String,
      );
    } on FleetContentsException {
      rethrow;
    } on DioException {
      // Do not attach the underlying error: request metadata may contain auth.
      throw const FleetContentsException('Repository request failed.');
    } on FormatException {
      throw const FleetContentsException('Repository content is malformed.');
    }
  }

  /// Sends one Contents API update using the saved file blob SHA. Callers must
  /// never retry this request automatically; an exception may mean GitHub
  /// accepted the write but the response was lost.
  Future<FleetContentsPutResult> putFile({
    required String content,
    required String blobSha,
  }) => _serializeMutation(() => _putFile(content: content, blobSha: blobSha));

  Future<FleetContentsPutResult> _putFile({
    required String content,
    required String blobSha,
  }) async {
    final bytes = utf8.encode(content);
    if (bytes.length > maxContentBytes ||
        !RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(blobSha)) {
      throw const FleetContentsException('Invalid fleet update.');
    }
    try {
      FleetConfiguration.parse(content);
    } on FormatException {
      throw const FleetContentsException('Fleet update is invalid.');
    }
    final uri = _contentsUri();
    final requestBody = jsonEncode({
      'message': 'Update fleet configuration',
      'content': base64Encode(bytes),
      'sha': blobSha,
      'branch': _branch,
    });
    final cancellation = CancelToken();
    final deadline = Stopwatch()..start();
    try {
      final response = await _dio
          .put<ResponseBody>(
            uri.toString(),
            data: requestBody,
            cancelToken: cancellation,
            options: Options(
              contentType: Headers.jsonContentType,
              responseType: ResponseType.stream,
              validateStatus: (_) => true,
              followRedirects: false,
              maxRedirects: 0,
              headers: {HttpHeaders.authorizationHeader: 'Bearer $_token'},
            ),
          )
          .timeout(
            _remaining(deadline),
            onTimeout: () {
              cancellation.cancel('Request deadline exceeded.');
              throw const FleetContentsException(
                'Repository request timed out.',
              );
            },
          );
      final status = response.statusCode ?? 0;
      if (status >= 300 && status < 400) {
        cancellation.cancel('Repository redirect refused.');
        await response.data?.stream.listen((_) {}).cancel();
        return FleetContentsPutResult(statusCode: status);
      }
      final body = response.data;
      if (body == null) return FleetContentsPutResult(statusCode: status);
      final declaredLength = int.tryParse(
        response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      if (declaredLength != null && declaredLength > maxResponseBytes) {
        cancellation.cancel('Repository response exceeds size limit.');
        await body.stream.listen((_) {}).cancel();
        throw const FleetContentsException(
          'Repository response exceeds size limit.',
        );
      }
      final responseBytes = await _readBounded(body.stream, cancellation)
          .timeout(
            _remaining(deadline),
            onTimeout: () {
              cancellation.cancel('Request deadline exceeded.');
              throw const FleetContentsException(
                'Repository request timed out.',
              );
            },
          );
      String? commitSha;
      try {
        final decoded = jsonDecode(
          utf8.decode(responseBytes, allowMalformed: false),
        );
        if (decoded is Map<String, dynamic> &&
            decoded['commit'] is Map<String, dynamic>) {
          final candidate = (decoded['commit'] as Map<String, dynamic>)['sha'];
          if (candidate is String &&
              RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(candidate)) {
            commitSha = candidate;
          }
        }
      } on FormatException {
        // Status remains authoritative; an unavailable commit SHA is optional.
      }
      return FleetContentsPutResult(statusCode: status, commitSha: commitSha);
    } on FleetContentsException {
      rethrow;
    } on DioException {
      // Do not attach request/response objects: they may contain credentials.
      throw const FleetContentsException(
        'Repository update response was unavailable.',
      );
    } on FormatException {
      throw const FleetContentsException('Repository response is malformed.');
    }
  }

  Future<T> _serializeMutation<T>(Future<T> Function() action) async {
    final previous = _mutationTail;
    final release = Completer<void>();
    _mutationTail = release.future;
    await previous;
    try {
      return await action();
    } finally {
      release.complete();
    }
  }

  Uri _contentsUri() {
    final encodedPath = _path.split('/').map(Uri.encodeComponent).join('/');
    final uri = Uri.parse(
      '$_origin/repos/${Uri.encodeComponent(_owner)}/${Uri.encodeComponent(_repository)}/contents/$encodedPath',
    ).replace(queryParameters: {'ref': _branch});
    if (uri.scheme != 'https' ||
        uri.host != 'api.github.com' ||
        uri.port != 443) {
      throw const FleetContentsException('Unsafe repository endpoint.');
    }
    return uri;
  }

  static Duration _remaining(Stopwatch stopwatch) {
    final remaining = _totalTimeout - stopwatch.elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  static Future<Uint8List> _readBounded(
    Stream<Uint8List> stream,
    CancelToken cancellation,
  ) async {
    final chunks = <Uint8List>[];
    var length = 0;
    try {
      await for (final chunk in stream) {
        length += chunk.length;
        if (length > maxResponseBytes) {
          cancellation.cancel('Repository response exceeds size limit.');
          throw const FleetContentsException(
            'Repository response exceeds size limit.',
          );
        }
        chunks.add(chunk);
      }
    } on FleetContentsException {
      rethrow;
    } catch (_) {
      // Stream errors can carry a private request URI or other transport data.
      // Cancel the request and expose only the fixed safe error message.
      cancellation.cancel('Repository response stream failed.');
      throw const FleetContentsException(
        'Repository response was unavailable.',
      );
    }
    final result = Uint8List(length);
    var offset = 0;
    for (final chunk in chunks) {
      result.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return result;
  }

  void close() => _dio.close(force: true);
}

class FleetContentsPutResult {
  const FleetContentsPutResult({required this.statusCode, this.commitSha});
  final int statusCode;
  final String? commitSha;
}

class FleetContentsException implements Exception {
  const FleetContentsException(this.message);
  final String message;
  @override
  String toString() => 'FleetContentsException: $message';
}
