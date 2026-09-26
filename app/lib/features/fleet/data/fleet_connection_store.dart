import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/widgets.dart';

import '../models/fleet_configuration.dart';
import 'fleet_configuration_service.dart';
import 'fleet_contents_client.dart';

abstract interface class FleetConnectionStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterFleetConnectionStorage implements FleetConnectionStorage {
  FlutterFleetConnectionStorage([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Coordinates and phone writer token only; never stores fleet contents.
class FleetConnection {
  const FleetConnection({
    required this.owner,
    required this.repo,
    required this.branch,
    required this.path,
    required this.writerToken,
  });

  final String owner, repo, branch, path, writerToken;

  @override
  String toString() => 'FleetConnection(<redacted>)';
}

typedef FleetClientFactory =
    FleetContentsClient Function(FleetConnection connection);
typedef FleetClock = DateTime Function();

/// Phone-side private fleet connection and short-lived in-memory edit seam.
class FleetConnectionStore with WidgetsBindingObserver {
  FleetConnectionStore({
    FleetConnectionStorage? storage,
    FleetClientFactory? clientFactory,
    FleetClock? clock,
    this.sessionLifetime = const Duration(minutes: 5),
    bool observeLifecycle = true,
  }) : _storage = storage ?? FlutterFleetConnectionStorage(),
       _clientFactory = clientFactory ?? defaultClientFactory,
       _clock = clock ?? DateTime.now,
       _observeLifecycle = observeLifecycle {
    if (_observeLifecycle) WidgetsBinding.instance.addObserver(this);
  }

  static const _prefix = 'fleet_connection_v1_';
  final FleetConnectionStorage _storage;
  final FleetClientFactory _clientFactory;
  final FleetClock _clock;
  final Duration sessionLifetime;
  final bool _observeLifecycle;
  FleetEditSession? _session;
  bool _disposed = false;
  int _generation = 0;

  static FleetContentsClient defaultClientFactory(FleetConnection connection) =>
      FleetContentsClient(
        owner: connection.owner,
        repository: connection.repo,
        branch: connection.branch,
        path: connection.path,
        token: connection.writerToken,
      );

  Future<void> saveConnection(
    String owner,
    String repo,
    String branch,
    String path,
    String writerToken,
  ) async {
    _ensureOpen();
    final connection = _validated(owner, repo, branch, path, writerToken);
    try {
      await _storage.write('${_prefix}owner', connection.owner);
      await _storage.write('${_prefix}repo', connection.repo);
      await _storage.write('${_prefix}branch', connection.branch);
      await _storage.write('${_prefix}path', connection.path);
      await _storage.write('${_prefix}writer_token', connection.writerToken);
    } catch (_) {
      throw const FleetConnectionException('Unable to save connection.');
    }
  }

  Future<FleetConnection?> loadConnection() async {
    _ensureOpen();
    try {
      final values = await Future.wait([
        _storage.read('${_prefix}owner'),
        _storage.read('${_prefix}repo'),
        _storage.read('${_prefix}branch'),
        _storage.read('${_prefix}path'),
        _storage.read('${_prefix}writer_token'),
      ]);
      if (values.every((value) => value == null)) return null;
      if (values.any((value) => value == null)) {
        throw const FleetConnectionException('Saved connection is incomplete.');
      }
      return _validated(
        values[0]!,
        values[1]!,
        values[2]!,
        values[3]!,
        values[4]!,
      );
    } on FleetConnectionException {
      rethrow;
    } catch (_) {
      throw const FleetConnectionException('Unable to load saved connection.');
    }
  }

  Future<void> clearConnection() async {
    _ensureOpen();
    closeSession();
    try {
      for (final field in const [
        'owner',
        'repo',
        'branch',
        'path',
        'writer_token',
      ]) {
        await _storage.delete('$_prefix$field');
      }
    } catch (_) {
      throw const FleetConnectionException('Unable to clear saved connection.');
    }
  }

  Future<FleetEditSession> openEditSession() async {
    _ensureOpen();
    closeSession();
    final generation = _generation;
    final connection = await loadConnection();
    _ensureCurrent(generation);
    if (connection == null) {
      throw const FleetConnectionException('No saved connection.');
    }
    _ensureCurrent(generation);
    final client = _clientFactory(connection);
    final session = FleetEditSession._(
      client: client,
      expiresAt: _clock().add(sessionLifetime),
      clock: _clock,
      onClose: _sessionClosed,
    );
    _session = session;
    try {
      final snapshot = await client.fetch();
      _ensureCurrent(generation);
      session._installSnapshot(snapshot);
      return session;
    } catch (_) {
      session.close();
      throw const FleetConnectionException(
        'Unable to open fleet edit session.',
      );
    }
  }

  void _sessionClosed(FleetEditSession session) {
    if (identical(_session, session)) _session = null;
  }

  void closeSession() {
    _generation++;
    _session?.close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) closeSession();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    closeSession();
    if (_observeLifecycle) WidgetsBinding.instance.removeObserver(this);
  }

  void _ensureOpen() {
    if (_disposed) {
      throw const FleetConnectionException('Connection store is closed.');
    }
  }

  void _ensureCurrent(int generation) {
    _ensureOpen();
    if (_generation != generation) {
      throw const FleetConnectionException(
        'Fleet edit session was interrupted.',
      );
    }
  }

  static FleetConnection _validated(
    String owner,
    String repo,
    String branch,
    String path,
    String token,
  ) {
    final segment = RegExp(r'^[A-Za-z0-9_.-]{1,100}$');
    bool safeSegment(String value) =>
        segment.hasMatch(value) && value != '.' && value != '..';
    if (!safeSegment(owner) ||
        !safeSegment(repo) ||
        !safeSegment(branch) ||
        path.split('/').any((part) => !safeSegment(part)) ||
        token.isEmpty ||
        token.length > 512 ||
        !RegExp(r'^[!-~]+$').hasMatch(token)) {
      throw const FleetConnectionException('Invalid repository connection.');
    }
    return FleetConnection(
      owner: owner,
      repo: repo,
      branch: branch,
      path: path.split('/').join('/'),
      writerToken: token,
    );
  }
}

class FleetEditSession {
  FleetEditSession._({
    required FleetContentsClient client,
    required DateTime expiresAt,
    required FleetClock clock,
    required void Function(FleetEditSession) onClose,
  }) : _client = client,
       _expiresAt = expiresAt,
       _clock = clock,
       _onClose = onClose {
    _expiry = Timer(
      expiresAt.difference(clock()).isNegative
          ? Duration.zero
          : expiresAt.difference(clock()),
      close,
    );
  }

  final FleetContentsClient _client;
  final DateTime _expiresAt;
  final FleetClock _clock;
  final void Function(FleetEditSession) _onClose;
  late final Timer _expiry;
  FleetContentsSnapshot? _snapshot;
  bool _closed = false;

  FleetConfiguration get configuration {
    _ensureActive();
    return FleetConfiguration.parse(_snapshot!.content);
  }

  bool get isActive => !_closed && _clock().isBefore(_expiresAt);

  void _installSnapshot(FleetContentsSnapshot snapshot) {
    if (!isActive) {
      close();
      throw const FleetConnectionException(
        'Fleet edit session is closed or expired.',
      );
    }
    _snapshot = snapshot;
  }

  Future<FleetSubmissionStatus> submitChange({
    required String deviceRef,
    required FleetDeviceConfiguration editedDeviceConfig,
    String Function()? uuidV4,
  }) async {
    _ensureActive();
    final service = FleetConfigurationService(_client, uuidV4: uuidV4);
    final result = await service.submit(
      baseSnapshot: _snapshot!,
      deviceRef: deviceRef,
      editedDeviceConfig: editedDeviceConfig,
    );
    _ensureActive();
    return result.status;
  }

  void _ensureActive() {
    if (!isActive) {
      close();
      throw const FleetConnectionException(
        'Fleet edit session is closed or expired.',
      );
    }
    if (_snapshot == null) {
      throw const FleetConnectionException('Fleet edit session is not ready.');
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _expiry.cancel();
    _snapshot = null;
    _client.close();
    _onClose(this);
  }

  @override
  String toString() => 'FleetEditSession(<redacted>)';
}

class FleetConnectionException implements Exception {
  const FleetConnectionException(this.message);
  final String message;
  @override
  String toString() => 'FleetConnectionException: $message';
}
