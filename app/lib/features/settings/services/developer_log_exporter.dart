import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../thermostats/data/thermostat_repository.dart';
import '../../thermostats/models/thermostat.dart';
import '../../thermostats/models/thermostat_state.dart';
import '../data/alert_config_repository.dart';
import '../models/alert_config.dart';

class DeveloperLogExporter {
  DeveloperLogExporter({
    required ThermostatRepository thermostatRepository,
    required AlertConfigRepository alertConfigRepository,
    Future<Directory> Function()? directoryProvider,
    DateTime Function()? clock,
  }) : _thermostatRepository = thermostatRepository,
       _alertConfigRepository = alertConfigRepository,
       _directoryProvider =
           directoryProvider ?? getApplicationDocumentsDirectory,
       _clock = clock ?? _defaultClock;

  final ThermostatRepository _thermostatRepository;
  final AlertConfigRepository _alertConfigRepository;
  final Future<Directory> Function() _directoryProvider;
  final DateTime Function() _clock;

  static DateTime _defaultClock() => DateTime.now().toUtc();

  Future<Uri> export() async {
    final now = _clock();
    final directory = await _directoryProvider();
    final fileName = 'farmctl-log-${_safeTimestamp(now)}.json';
    final file = File(p.join(directory.path, fileName));

    final config = await _alertConfigRepository.loadConfig();
    final thermostats = await _thermostatRepository.fetchThermostats();

    final payload = {
      'generatedAt': now.toIso8601String(),
      'settings': _serializeConfig(config),
      'thermostats': thermostats.map(_serializeThermostatSummary).toList(),
    };

    final encoder = const JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(payload));
    return file.uri;
  }

  Map<String, dynamic> _serializeConfig(AlertConfig config) {
    return {
      'pollIntervalMinutes': config.pollInterval.inMinutes,
      'exactAlarmsEnabled': config.exactAlarmsEnabled,
      'soundUri': config.soundUri,
      'vibrate': config.vibrate,
      'volumeBoost': config.volumeBoost,
      'pauseAllUntil': config.pauseAllUntil?.toIso8601String(),
    };
  }

  Map<String, dynamic> _serializeThermostatSummary(ThermostatSummary summary) {
    final thermostat = summary.thermostat;
    final state = summary.state;
    return {
      'thermostat': _serializeThermostat(thermostat),
      'state': state != null ? _serializeState(state) : null,
    };
  }

  Map<String, dynamic> _serializeThermostat(Thermostat thermostat) {
    return {
      'id': thermostat.id,
      'name': thermostat.name,
      'gistId': thermostat.rawUrl,
      'minC': thermostat.minC,
      'maxC': thermostat.maxC,
      'hysteresisEnabled': thermostat.hysteresisEnabled,
      'monitoringEnabled': thermostat.monitoringEnabled,
      'createdAt': thermostat.createdAt.toIso8601String(),
      'updatedAt': thermostat.updatedAt.toIso8601String(),
    };
  }

  Map<String, dynamic> _serializeState(ThermostatState state) {
    return {
      'status': state.status.name,
      'lastValueC': state.lastValueC,
      'lastFetchedAt': state.lastFetchedAt?.toIso8601String(),
      'statusMessage': state.statusMessage,
      'lastAlarmAt': state.lastAlarmAt?.toIso8601String(),
      'snoozedUntil': state.snoozedUntil?.toIso8601String(),
      'silenceUntilOk': state.silenceUntilOk,
      'updatedAt': state.updatedAt.toIso8601String(),
    };
  }

  String _safeTimestamp(DateTime value) {
    return value.toIso8601String().replaceAll(':', '-');
  }
}
