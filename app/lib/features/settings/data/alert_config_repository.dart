import 'package:drift/drift.dart';

import '../../thermostats/data/thermostat_database.dart';
import '../models/alert_config.dart';
import 'secure_token_store.dart';

class AlertConfigRepository {
  AlertConfigRepository(
    this._database, {
    DateTime Function()? clock,
    SecureTokenStore? tokenStore,
  }) : _clock = clock ?? _defaultClock,
       _tokenStore = tokenStore ?? FlutterSecureTokenStore();

  final ThermostatDatabase _database;
  final DateTime Function() _clock;
  final SecureTokenStore _tokenStore;

  static DateTime _defaultClock() => DateTime.now().toUtc();

  Stream<AlertConfig> watchConfig() {
    return _database.watchAlertConfig().asyncMap((entry) async {
      final token = await _resolveToken(entry);
      return AlertConfig.fromEntry(entry).withToken(token);
    });
  }

  Future<AlertConfig> loadConfig() async {
    final entry = await _database.getAlertConfig();
    final token = await _resolveToken(entry);
    return AlertConfig.fromEntry(entry).withToken(token);
  }

  /// Resolves the GitHub token from secure storage, migrating any legacy
  /// plaintext token out of the database on first read. Falls back to the
  /// database value if secure storage is unavailable so a transient failure
  /// (e.g. before plugins are registered in a background isolate) never strips
  /// authentication mid-run.
  Future<String?> _resolveToken(AlertConfigEntry entry) async {
    String? secure;
    try {
      secure = await _tokenStore.readToken();
    } catch (_) {
      return entry.githubToken;
    }

    final legacy = entry.githubToken;
    if (secure != null) {
      if (legacy != null && legacy.isNotEmpty) {
        await _scrubLegacyToken();
      }
      return secure;
    }

    if (legacy != null && legacy.isNotEmpty) {
      // Migrate the plaintext token into secure storage, then scrub it.
      await _tokenStore.writeToken(legacy);
      await _scrubLegacyToken();
      return legacy;
    }

    return null;
  }

  Future<void> _scrubLegacyToken() async {
    await _database.updateAlertConfig(
      const AlertConfigEntriesCompanion(githubToken: Value(null)),
    );
  }

  Future<void> setPollInterval(Duration interval) async {
    final minutes = interval.inMinutes.clamp(1, 30);
    await _database.updateAlertConfig(
      AlertConfigEntriesCompanion(pollIntervalMin: Value(minutes)),
    );
  }

  Future<void> setExactAlarmsEnabled(bool enabled) async {
    await _database.updateAlertConfig(
      AlertConfigEntriesCompanion(exactAlarmsEnabled: Value(enabled)),
    );
  }

  Future<void> setSoundUri(String? uri) async {
    await _database.updateAlertConfig(
      AlertConfigEntriesCompanion(soundUri: Value(uri)),
    );
  }

  Future<void> setVibrate(bool enabled) async {
    await _database.updateAlertConfig(
      AlertConfigEntriesCompanion(vibrate: Value(enabled)),
    );
  }

  Future<void> setVolumeBoost(bool enabled) async {
    await _database.updateAlertConfig(
      AlertConfigEntriesCompanion(volumeBoost: Value(enabled)),
    );
  }

  Future<void> pauseFor(Duration duration) async {
    final until = _clock().add(duration);
    await _database.updateAlertConfig(
      AlertConfigEntriesCompanion(pauseAllUntil: Value(until)),
    );
  }

  Future<void> clearPause() async {
    await _database.updateAlertConfig(
      const AlertConfigEntriesCompanion(pauseAllUntil: Value(null)),
    );
  }

  Future<void> setGithubToken(String? token) async {
    await _tokenStore.writeToken(token);
    // Scrub any legacy plaintext value and nudge the config stream to re-emit
    // so listeners pick up the new token from secure storage.
    await _scrubLegacyToken();
  }
}
