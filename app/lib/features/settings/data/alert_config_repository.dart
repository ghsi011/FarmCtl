import 'package:drift/drift.dart';

import '../../thermostats/data/thermostat_database.dart';
import '../models/alert_config.dart';

class AlertConfigRepository {
  AlertConfigRepository(this._database, {DateTime Function()? clock})
    : _clock = clock ?? _defaultClock;

  final ThermostatDatabase _database;
  final DateTime Function() _clock;

  static DateTime _defaultClock() => DateTime.now().toUtc();

  Stream<AlertConfig> watchConfig() {
    return _database.watchAlertConfig().map(AlertConfig.fromEntry);
  }

  Future<AlertConfig> loadConfig() async {
    final entry = await _database.getAlertConfig();
    return AlertConfig.fromEntry(entry);
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
    await _database.updateAlertConfig(
      AlertConfigEntriesCompanion(githubToken: Value(token)),
    );
  }
}
