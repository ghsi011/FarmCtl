import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../core/background/thermostat_monitor.dart';
import '../models/alert_config.dart';
import '../providers/settings_providers.dart';
import '../../thermostats/data/thermostat_client.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  double? _pollIntervalOverride;

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(alertConfigProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: configAsync.when(
        data: (config) => _SettingsContent(
          config: config,
          pollIntervalOverride: _pollIntervalOverride,
          onPollIntervalChanged: _handlePollIntervalChanged,
          onPollIntervalChangeEnd: (value) {
            _commitPollInterval(value);
          },
          onExactAlarmsChanged: (value) {
            _setExactAlarmsEnabled(value);
          },
          onVibrateChanged: (value) {
            _setVibrateEnabled(value);
          },
          onVolumeBoostChanged: (value) {
            _setVolumeBoostEnabled(value);
          },
          onPauseFor: (duration) {
            _pauseFor(duration);
          },
          onResumeNow: _resumeMonitoring,
          onPickSound: (config) {
            _showSoundPicker(config);
          },
          onUseDefaultSound: (config) {
            _useDefaultSound(config);
          },
          onTestAlarm: (config) {
            _testAlarm(config);
          },
          onExportLogs: _exportLogs,
          onGithubTokenChanged: (token) {
            _setGithubToken(token);
          },
          onTestGithubToken: _testGithubToken,
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => _ErrorContent(error: error),
      ),
    );
  }

  void _handlePollIntervalChanged(double value) {
    setState(() {
      _pollIntervalOverride = value;
    });
  }

  Future<void> _commitPollInterval(double value) async {
    final minutes = value.round().clamp(1, 30);
    try {
      await ref
          .read(alertConfigRepositoryProvider)
          .setPollInterval(Duration(minutes: minutes));
      await initializeBackgroundMonitoring(
        pollFrequency: Duration(minutes: minutes),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update poll interval: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _pollIntervalOverride = null;
        });
      }
    }
  }

  Future<void> _setExactAlarmsEnabled(bool value) async {
    try {
      await ref
          .read(alertConfigRepositoryProvider)
          .setExactAlarmsEnabled(value);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update exact alarms: $error')),
      );
    }
  }

  Future<void> _setVibrateEnabled(bool value) async {
    try {
      await ref.read(alertConfigRepositoryProvider).setVibrate(value);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update vibrate setting: $error')),
      );
    }
  }

  Future<void> _setVolumeBoostEnabled(bool value) async {
    try {
      await ref.read(alertConfigRepositoryProvider).setVolumeBoost(value);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update volume boost: $error')),
      );
    }
  }

  Future<void> _pauseFor(Duration duration) async {
    try {
      await ref.read(alertConfigRepositoryProvider).pauseFor(duration);
      if (!mounted) return;
      final formatted = _formatDuration(duration);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Monitoring paused for $formatted')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to pause monitoring: $error')),
      );
    }
  }

  Future<void> _resumeMonitoring() async {
    try {
      await ref.read(alertConfigRepositoryProvider).clearPause();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Monitoring resumed')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to resume monitoring: $error')),
      );
    }
  }

  Future<void> _showSoundPicker(AlertConfig config) async {
    final previous = config.soundUri;
    final initialUri = previous != null ? Uri.tryParse(previous) : null;
    Uri? picked;
    try {
      picked = await ref
          .read(soundPickerProvider)
          .pickSound(initialUri: initialUri);
    } on PlatformException catch (error, stackTrace) {
      debugPrint('Failed to launch sound picker: $error\n$stackTrace');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Unable to open sound picker: ${error.message ?? error.code}',
          ),
        ),
      );
      return;
    }

    if (picked == null) {
      return;
    }

    final newValue = picked.toString();
    try {
      await ref.read(alertConfigRepositoryProvider).setSoundUri(newValue);

      if (initialUri != null && initialUri.toString() != newValue) {
        try {
          await ref.read(soundPickerProvider).releasePersistedUri(initialUri);
        } catch (error, stackTrace) {
          debugPrint(
            'Failed to release previous sound URI permission: $error\n$stackTrace',
          );
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Custom alarm sound saved')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to update sound: $error')));
    }
  }

  Future<void> _useDefaultSound(AlertConfig config) async {
    final previous = config.soundUri;
    if (previous == null) {
      return;
    }

    final previousUri = Uri.tryParse(previous);
    try {
      await ref.read(alertConfigRepositoryProvider).setSoundUri(null);

      if (previousUri != null) {
        try {
          await ref.read(soundPickerProvider).releasePersistedUri(previousUri);
        } catch (error, stackTrace) {
          debugPrint(
            'Failed to release previous sound URI permission: $error\n$stackTrace',
          );
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Alarm sound reset to system default')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to update sound: $error')));
    }
  }

  Future<void> _testAlarm(AlertConfig config) async {
    try {
      await showTestAlarmNotification(config: config);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to trigger test alarm: $error')),
      );
    }
  }

  Future<void> _exportLogs() async {
    try {
      final uri = await ref.read(developerLogExporterProvider).export();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported log to ${uri.toFilePath()}')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to export logs: $error')));
    }
  }

  Future<void> _setGithubToken(String? token) async {
    try {
      final trimmed = token?.trim();
      final finalToken = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
      await ref.read(alertConfigRepositoryProvider).setGithubToken(finalToken);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            finalToken == null ? 'GitHub token cleared' : 'GitHub token saved',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save GitHub token: $error')),
      );
    }
  }

  Future<void> _testGithubToken() async {
    final config = await ref.read(alertConfigRepositoryProvider).loadConfig();
    final client = ThermostatHttpClient(githubToken: config.githubToken);
    final message = await client.testToken();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SettingsContent extends StatefulWidget {
  const _SettingsContent({
    required this.config,
    required this.pollIntervalOverride,
    required this.onPollIntervalChanged,
    required this.onPollIntervalChangeEnd,
    required this.onExactAlarmsChanged,
    required this.onVibrateChanged,
    required this.onVolumeBoostChanged,
    required this.onPauseFor,
    required this.onResumeNow,
    required this.onPickSound,
    required this.onUseDefaultSound,
    required this.onTestAlarm,
    required this.onExportLogs,
    required this.onGithubTokenChanged,
    required this.onTestGithubToken,
  });

  final AlertConfig config;
  final double? pollIntervalOverride;
  final ValueChanged<double> onPollIntervalChanged;
  final ValueChanged<double> onPollIntervalChangeEnd;
  final ValueChanged<bool> onExactAlarmsChanged;
  final ValueChanged<bool> onVibrateChanged;
  final ValueChanged<bool> onVolumeBoostChanged;
  final ValueChanged<Duration> onPauseFor;
  final VoidCallback onResumeNow;
  final ValueChanged<AlertConfig> onPickSound;
  final ValueChanged<AlertConfig> onUseDefaultSound;
  final ValueChanged<AlertConfig> onTestAlarm;
  final VoidCallback onExportLogs;
  final ValueChanged<String?> onGithubTokenChanged;
  final VoidCallback onTestGithubToken;

  @override
  State<_SettingsContent> createState() => _SettingsContentState();
}

class _SettingsContentState extends State<_SettingsContent> {
  late TextEditingController _tokenController;
  bool _tokenObscured = true;

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController(text: widget.config.githubToken);
  }

  @override
  void didUpdateWidget(_SettingsContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.config.githubToken != oldWidget.config.githubToken) {
      _tokenController.text = widget.config.githubToken ?? '';
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  static const _pauseOptions = <_PauseOption>[
    _PauseOption(Duration(minutes: 15), '15 minutes'),
    _PauseOption(Duration(hours: 1), '1 hour'),
    _PauseOption(Duration(hours: 4), '4 hours'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now().toUtc();
    final sliderValue =
        widget.pollIntervalOverride ??
        widget.config.pollInterval.inMinutes.toDouble();
    final pauseMessage = _pauseMessage(context, widget.config, now);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(
          title: 'Monitoring',
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Poll interval', style: theme.textTheme.titleMedium),
                    Slider(
                      min: 1,
                      max: 30,
                      divisions: 29,
                      value: sliderValue,
                      label: '${sliderValue.round()} min',
                      onChanged: widget.onPollIntervalChanged,
                      onChangeEnd: widget.onPollIntervalChangeEnd,
                    ),
                    Text(
                      '${sliderValue.round()} minute${sliderValue.round() == 1 ? '' : 's'}',
                      style: theme.textTheme.bodySmall,
                    ),
                    const Divider(height: 24),
                    SwitchListTile.adaptive(
                      value: widget.config.exactAlarmsEnabled,
                      onChanged: widget.onExactAlarmsChanged,
                      title: const Text('Allow exact alarms'),
                      subtitle: const Text(
                        'Improve reliability on Android 12+ by requesting '
                        'the exact alarm permission.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pause all monitoring',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if (pauseMessage != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          pauseMessage,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _pauseOptions
                          .map(
                            (option) => FilledButton.tonal(
                              onPressed: () =>
                                  widget.onPauseFor(option.duration),
                              child: Text(option.label),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: widget.config.isPaused(now)
                            ? widget.onResumeNow
                            : null,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Resume now'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Section(
          title: 'Alarm',
          children: [
            Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    title: const Text('Alarm sound'),
                    subtitle: Text(
                      widget.config.soundUri ?? 'System default alarm sound',
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.tonal(
                          onPressed: () => widget.onPickSound(widget.config),
                          child: const Text('Choose sound'),
                        ),
                        TextButton(
                          onPressed: widget.config.soundUri == null
                              ? null
                              : () => widget.onUseDefaultSound(widget.config),
                          child: const Text('Use system default'),
                        ),
                      ],
                    ),
                  ),
                  SwitchListTile.adaptive(
                    value: widget.config.vibrate,
                    onChanged: widget.onVibrateChanged,
                    title: const Text('Vibrate on alarm'),
                  ),
                  SwitchListTile.adaptive(
                    value: widget.config.volumeBoost,
                    onChanged: widget.onVolumeBoostChanged,
                    title: const Text('Boost volume'),
                    subtitle: const Text(
                      'Keeps alarm volume at maximum while alarming.',
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: () => widget.onTestAlarm(widget.config),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Test alarm'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Section(
          title: 'API Configuration',
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'GitHub Personal Access Token',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Optional token to increase GitHub API rate limits (60 → 5,000 requests/hour).',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _tokenController,
                      obscureText: _tokenObscured,
                      decoration: InputDecoration(
                        labelText: 'Personal Access Token',
                        hintText: 'ghp_...',
                        border: const OutlineInputBorder(),
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                _tokenObscured
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                              onPressed: () {
                                setState(() {
                                  _tokenObscured = !_tokenObscured;
                                });
                              },
                              tooltip: _tokenObscured ? 'Show' : 'Hide',
                            ),
                            if (_tokenController.text.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () {
                                  _tokenController.clear();
                                  widget.onGithubTokenChanged(null);
                                },
                                tooltip: 'Clear',
                              ),
                          ],
                        ),
                      ),
                      onSubmitted: widget.onGithubTokenChanged,
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 12,
                        children: [
                          FilledButton(
                            onPressed: () {
                              widget.onGithubTokenChanged(
                                _tokenController.text,
                              );
                            },
                            child: const Text('Save Token'),
                          ),
                          OutlinedButton(
                            onPressed: widget.onTestGithubToken,
                            child: const Text('Test Token'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _Section(
          title: 'Developer tools',
          children: [
            Card(
              child: ListTile(
                title: const Text('Export developer log'),
                subtitle: const Text(
                  'Writes a JSON snapshot of thermostats and current state.',
                ),
                trailing: FilledButton(
                  onPressed: widget.onExportLogs,
                  child: const Text('Export'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String? _pauseMessage(
    BuildContext context,
    AlertConfig config,
    DateTime now,
  ) {
    if (!config.isPaused(now)) {
      return null;
    }
    final until = config.pauseAllUntil!;
    final remaining = config.remainingPause(now)!;
    final local = until.toLocal();
    final formatter = DateFormat.yMMMd().add_jm();
    return 'Paused for another ${_formatDuration(remaining)} '
        '• resumes ${formatter.format(local)}';
  }
}

class _PauseOption {
  const _PauseOption(this.duration, this.label);

  final Duration duration;
  final String label;
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }
}

class _ErrorContent extends StatelessWidget {
  const _ErrorContent({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text(
              'Failed to load settings',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(error.toString(), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0 && minutes > 0) {
    return '$hours h $minutes m';
  }
  if (hours > 0) {
    return '$hours hour${hours == 1 ? '' : 's'}';
  }
  final mins = duration.inMinutes;
  if (mins >= 1) {
    return '$mins minute${mins == 1 ? '' : 's'}';
  }
  final seconds = duration.inSeconds;
  return '$seconds second${seconds == 1 ? '' : 's'}';
}
