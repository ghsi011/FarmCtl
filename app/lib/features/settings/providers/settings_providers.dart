import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../thermostats/providers/thermostat_providers.dart';
import '../data/alert_config_repository.dart';
import '../models/alert_config.dart';
import '../services/developer_log_exporter.dart';
import '../services/github_token_tester.dart';
import '../services/sound_picker.dart';

final alertConfigRepositoryProvider = Provider<AlertConfigRepository>((ref) {
  final database = ref.watch(thermostatDatabaseProvider);
  return AlertConfigRepository(database);
});

final alertConfigProvider = StreamProvider<AlertConfig>((ref) {
  final repository = ref.watch(alertConfigRepositoryProvider);
  return repository.watchConfig();
});

final developerLogExporterProvider = Provider<DeveloperLogExporter>((ref) {
  final thermostatRepository = ref.watch(thermostatRepositoryProvider);
  final alertRepository = ref.watch(alertConfigRepositoryProvider);
  return DeveloperLogExporter(
    thermostatRepository: thermostatRepository,
    alertConfigRepository: alertRepository,
  );
});

final soundPickerProvider = Provider<SoundPicker>((ref) {
  return SoundPicker();
});

final githubTokenTesterProvider = Provider<GithubTokenTester>((ref) {
  return GithubTokenTester();
});
