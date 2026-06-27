import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/background/thermostat_monitor.dart';
import '../models/alert_config.dart';
import '../providers/settings_providers.dart';
import '../services/sound_picker.dart';
import '../../thermostats/data/thermostat_client.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  static const int _workManagerFloorMinutes = 15;
  double? _pollIntervalOverride;

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(alertConfigProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: configAsync.when(
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
            onPickSound: (value) {
              _showSoundPicker(value);
            },
            onUseDefaultSound: (value) {
              _useDefaultSound(value);
            },
            onTestAlarm: (value) {
              _testAlarm(value);
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
      final config = ref.read(alertConfigProvider).asData?.value;
      if (config != null &&
          !config.exactAlarmsEnabled &&
          minutes < _workManagerFloorMinutes &&
          mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Intervals under 15 minutes may be delayed unless exact alarms are allowed.',
            ),
          ),
        );
      }
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
    final repository = ref.read(alertConfigRepositoryProvider);
    try {
      if (value) {
        final granted = await _ensureExactAlarmPermission();
        if (!granted) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Exact alarm permission is required to enable precise scheduling.',
              ),
            ),
          );
          return;
        }
      }

      await repository.setExactAlarmsEnabled(value);
      await initializeBackgroundMonitoring();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value
                ? 'Exact alarms enabled. Monitoring will use precise scheduling.'
                : 'Exact alarms disabled. Monitoring falls back to flexible scheduling.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update exact alarms: $error')),
      );
    }
  }

  Future<bool> _ensureExactAlarmPermission() async {
    if (kIsWeb || !Platform.isAndroid) {
      return true;
    }

    var status = await Permission.scheduleExactAlarm.status;
    if (status.isGranted) {
      return true;
    }

    if (!mounted) {
      return false;
    }

    final shouldRequest =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Allow exact alarms'),
            content: const Text(
              'FarmCtl needs the exact alarm permission to wake reliably when the device is idle.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Not now'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Continue'),
              ),
            ],
          ),
        ) ??
        false;

    if (!shouldRequest) {
      return false;
    }

    status = await Permission.scheduleExactAlarm.request();
    if (status.isGranted) {
      return true;
    }

    if (!mounted) {
      return false;
    }

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enable exact alarms'),
        content: const Text(
          'Open system settings and enable "Allow exact alarms" for FarmCtl to improve scheduling reliability.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          if (status.isPermanentlyDenied || status.isRestricted)
            TextButton(
              onPressed: () async {
                final navigator = Navigator.of(context);
                await openAppSettings();
                navigator.pop();
              },
              child: const Text('Open settings'),
            ),
        ],
      ),
    );

    return false;
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
      await initializeBackgroundMonitoring();
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
      await initializeBackgroundMonitoring();
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
    SoundSelection? selection;
    try {
      selection = await ref
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

    if (selection == null) {
      return;
    }

    try {
      if (selection.useDefault) {
        await ref.read(alertConfigRepositoryProvider).setSoundUri(null);
        if (initialUri != null) {
          try {
            await ref.read(soundPickerProvider).releasePersistedUri(initialUri);
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
        return;
      }

      final pickedUri = selection.uri;
      if (pickedUri == null) {
        return;
      }

      final newValue = pickedUri.toString();
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
    try {
      final config = await ref.read(alertConfigRepositoryProvider).loadConfig();
      final client = ThermostatHttpClient(githubToken: config.githubToken);
      final String message;
      try {
        message = await client.testToken();
      } finally {
        client.close();
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to test GitHub token: $error')),
      );
    }
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
    // Rebuild on each keystroke so the suffix Clear (×) icon, which is rendered
    // conditionally on the field being non-empty, tracks the text.
    _tokenController.addListener(_onTokenChanged);
  }

  void _onTokenChanged() {
    if (mounted) {
      setState(() {});
    }
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
    _tokenController.removeListener(_onTokenChanged);
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
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      children: [
        _Section(
          title: 'Monitoring',
          description:
              'Configure background polling cadence and pause behaviour.',
          children: [
            _SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SettingsTileHeader(
                    title: 'Poll interval',
                    subtitle:
                        'Choose how often FarmCtl checks each thermostat for updates.',
                  ),
                  const SizedBox(height: 16),
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
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 20),
                  const _SettingsTileHeader(
                    title: 'Exact alarms',
                    subtitle:
                        'Improve reliability on Android 12+ by requesting the exact alarm permission.',
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    value: widget.config.exactAlarmsEnabled,
                    onChanged: widget.onExactAlarmsChanged,
                    title: const Text('Allow exact alarms'),
                    subtitle: const Text(
                      'FarmCtl may request the schedule exact alarm permission.',
                    ),
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.alarm_on),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SettingsTileHeader(
                    title: 'Pause monitoring',
                    subtitle:
                        'Temporarily stop background refreshes and notifications.',
                  ),
                  if (pauseMessage != null) ...[
                    const SizedBox(height: 12),
                    _InfoBanner(message: pauseMessage),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final option in _pauseOptions)
                        FilledButton.tonal(
                          onPressed: () => widget.onPauseFor(option.duration),
                          child: Text(option.label),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: widget.config.isPaused(now)
                          ? widget.onResumeNow
                          : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Resume monitoring'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        _Section(
          title: 'Alarm',
          description:
              'Tune how alarms sound and feel when a threshold is crossed.',
          children: [
            _SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SettingsTileHeader(
                    title: 'Alarm sound',
                    subtitle:
                        widget.config.soundUri ?? 'System default alarm sound',
                  ),
                  const SizedBox(height: 16),
                  Wrap(
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
                  const SizedBox(height: 20),
                  SwitchListTile.adaptive(
                    value: widget.config.vibrate,
                    onChanged: widget.onVibrateChanged,
                    title: const Text('Vibrate on alarm'),
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.vibration),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    value: widget.config.volumeBoost,
                    onChanged: widget.onVolumeBoostChanged,
                    title: const Text('Boost volume'),
                    subtitle: const Text(
                      'Keeps alarm volume at maximum while alarming.',
                    ),
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.volume_up),
                  ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: () => widget.onTestAlarm(widget.config),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Test alarm'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        _Section(
          title: 'API configuration',
          description:
              'Provide credentials to unlock higher GitHub API limits.',
          children: [
            _SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SettingsTileHeader(
                    title: 'GitHub personal access token',
                    subtitle:
                        'Optional token to increase API rate limits (60 → 5,000 requests/hour).',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _tokenController,
                    obscureText: _tokenObscured,
                    decoration: InputDecoration(
                      labelText: 'Personal access token',
                      hintText: 'ghp_...',
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
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Stored securely on-device and used only for GitHub API requests.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton(
                        onPressed: () {
                          widget.onGithubTokenChanged(
                            _tokenController.text.isEmpty
                                ? null
                                : _tokenController.text,
                          );
                        },
                        child: const Text('Save token'),
                      ),
                      OutlinedButton(
                        onPressed: widget.onTestGithubToken,
                        child: const Text('Test token'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        _Section(
          title: 'Developer tools',
          description:
              'Utilities intended for diagnostics and troubleshooting.',
          children: [
            _SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SettingsTileHeader(
                    title: 'Export developer log',
                    subtitle:
                        'Writes a JSON snapshot of thermostats and their current state.',
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: widget.onExportLogs,
                    icon: const Icon(Icons.output),
                    label: const Text('Export log'),
                  ),
                ],
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
  const _Section({
    required this.title,
    required this.children,
    this.description,
  });

  final String title;
  final String? description;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.headlineSmall),
        if (description != null) ...[
          const SizedBox(height: 6),
          Text(
            description!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 18),
        ...children,
      ],
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: const EdgeInsets.all(20), child: child),
    );
  }
}

class _SettingsTileHeader extends StatelessWidget {
  const _SettingsTileHeader({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 6),
          Text(
            subtitle!,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.pause_circle_filled, color: colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
        ],
      ),
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
