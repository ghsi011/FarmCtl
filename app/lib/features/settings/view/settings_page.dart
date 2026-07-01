import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/background/thermostat_monitor.dart';
import '../../../core/format/error_messages.dart';
import '../../../core/format/relative_time.dart';
import '../../../core/permissions/notification_permission.dart';
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
            onRequestBatteryExemption: _requestIgnoreBatteryOptimizations,
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
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Checking every $minutes minute${minutes == 1 ? '' : 's'}',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(humanizeError(error))));
    } finally {
      if (mounted) {
        setState(() {
          _pollIntervalOverride = null;
        });
      }
    }
  }

  /// Requests the OS exemption from battery optimisation (Doze / app standby).
  /// The foreground service is itself exempt from deferral while running, but
  /// this still helps the OS start/keep it alive promptly (e.g. after boot).
  Future<void> _requestIgnoreBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) {
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    try {
      var status = await Permission.ignoreBatteryOptimizations.status;
      if (status.isGranted) {
        if (!mounted) return;
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Background activity is already allowed.'),
          ),
        );
        return;
      }

      status = await Permission.ignoreBatteryOptimizations.request();
      if (!mounted) return;

      if (status.isGranted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Background activity allowed. Monitoring can run reliably while '
              'the app is closed.',
            ),
          ),
        );
        return;
      }

      messenger.showSnackBar(
        SnackBar(
          content: const Text(
            'Background activity not allowed. Checks may be delayed by battery '
            'optimisation.',
          ),
          action: SnackBarAction(
            label: 'Open settings',
            onPressed: openAppSettings,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(humanizeError(error))));
    }
  }

  Future<void> _setVibrateEnabled(bool value) async {
    try {
      await ref.read(alertConfigRepositoryProvider).setVibrate(value);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(humanizeError(error))));
    }
  }

  Future<void> _setVolumeBoostEnabled(bool value) async {
    try {
      await ref.read(alertConfigRepositoryProvider).setVolumeBoost(value);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(humanizeError(error))));
    }
  }

  Future<void> _pauseFor(Duration duration) async {
    try {
      await ref.read(alertConfigRepositoryProvider).pauseFor(duration);
      await initializeBackgroundMonitoring();
      if (!mounted) return;
      final resumeTime = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(DateTime.now().add(duration)));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Monitoring paused until $resumeTime')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(humanizeError(error))));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(humanizeError(error))));
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
      ).showSnackBar(SnackBar(content: Text(humanizeError(error))));
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
      ).showSnackBar(SnackBar(content: Text(humanizeError(error))));
    }
  }

  Future<void> _testAlarm(AlertConfig config) async {
    try {
      await showTestAlarmNotification(config: config);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Test alarm sent — check your notifications'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(humanizeError(error))));
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
      ).showSnackBar(SnackBar(content: Text(humanizeError(error))));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(humanizeError(error))));
    }
  }

  Future<void> _testGithubToken() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Testing GitHub token…')),
    );
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
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(humanizeError(error))));
    }
  }
}

class _SettingsContent extends StatefulWidget {
  const _SettingsContent({
    required this.config,
    required this.pollIntervalOverride,
    required this.onPollIntervalChanged,
    required this.onPollIntervalChangeEnd,
    required this.onRequestBatteryExemption,
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
  final Future<void> Function() onRequestBatteryExemption;
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
                    semanticFormatterCallback: (value) =>
                        '${value.round()} minutes',
                    onChanged: widget.onPollIntervalChanged,
                    onChangeEnd: widget.onPollIntervalChangeEnd,
                  ),
                  Text(
                    '${sliderValue.round()} minute${sliderValue.round() == 1 ? '' : 's'}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  _LastCheckRow(
                    lastRunAt: widget.config.lastMonitorRunAt,
                    pollInterval: widget.config.pollInterval,
                    now: now,
                  ),
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 20),
                  const _SettingsTileHeader(
                    title: 'Alarm notifications',
                    subtitle:
                        'Alarms are delivered as notifications; when '
                        'notifications are turned off, no alarm can reach you.',
                  ),
                  const SizedBox(height: 12),
                  const _NotificationPermissionTile(),
                  if (!kIsWeb && Platform.isAndroid) ...[
                    const SizedBox(height: 20),
                    const Divider(),
                    const SizedBox(height: 20),
                    const _SettingsTileHeader(
                      title: 'Background activity',
                      subtitle:
                          'Exempt FarmCtl from battery optimisation so checks '
                          'keep running while the app is closed.',
                    ),
                    const SizedBox(height: 12),
                    _BatteryOptimizationTile(
                      onRequest: widget.onRequestBatteryExemption,
                    ),
                  ],
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
                        'Optional — most setups work without one. Add a token '
                        'only if monitoring fails with rate-limit errors; it '
                        'raises the GitHub limit from 60 to 5,000 requests/hour.',
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
                    'Stored securely on-device and used only for GitHub API '
                    'requests. Press Save to apply changes. Create a token at '
                    'github.com/settings/tokens (no scopes required).',
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

/// When the background monitor last started a run, as relative time ('2 mins
/// ago') or 'Never' when it has not run yet. Rendered in an error style once
/// the reading is older than twice the poll interval — at that point a check
/// has been missed and alarm delivery can no longer be trusted.
class _LastCheckRow extends StatelessWidget {
  const _LastCheckRow({
    required this.lastRunAt,
    required this.pollInterval,
    required this.now,
  });

  final DateTime? lastRunAt;
  final Duration pollInterval;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = lastRunAt;
    final stale = last != null && now.difference(last) > pollInterval * 2;
    final value = last == null
        ? 'Never'
        : formatRelativeDuration(now.difference(last));

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        stale ? Icons.warning_amber : Icons.schedule,
        color: stale ? theme.colorScheme.error : null,
      ),
      title: const Text('Last check'),
      subtitle: stale
          ? Text(
              'Overdue — checks may be delayed or blocked.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            )
          : null,
      trailing: Text(
        value,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: stale
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
          fontWeight: stale ? FontWeight.w600 : null,
        ),
      ),
    );
  }
}

/// Reflects the notification-permission state surfaced by
/// [notificationPermissionStatusProvider]: alarms are delivered as
/// notifications, so a denied permission means every alarm is silently
/// suppressed. Offers the same "Open settings" escape hatch as the banner on
/// the thermostats page.
class _NotificationPermissionTile extends ConsumerWidget {
  const _NotificationPermissionTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = ref
        .watch(notificationPermissionStatusProvider)
        .asData
        ?.value;

    return switch (status) {
      AlarmNotificationPermission.denied => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.notifications_off, color: theme.colorScheme.error),
        title: const Text('Notifications are turned off'),
        subtitle: const Text(
          'Alarms are blocked until notifications are allowed.',
        ),
        trailing: FilledButton.tonal(
          onPressed: () {
            ref.read(notificationPermissionCheckerProvider).openSettings();
          },
          child: const Text('Open settings'),
        ),
      ),
      AlarmNotificationPermission.granted => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.check_circle, color: theme.colorScheme.primary),
        title: const Text('Notifications allowed'),
        subtitle: const Text('Alarm notifications can reach you.'),
      ),
      // Still loading, or the status could not be read.
      _ => const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.notifications_none),
        title: Text('Notification status unavailable'),
      ),
    };
  }
}

/// Shows whether FarmCtl is currently exempt from battery optimisation and lets
/// the user request the exemption. Loads its own live status so it reflects the
/// grant immediately after the system dialog returns. Only rendered on Android.
class _BatteryOptimizationTile extends StatefulWidget {
  const _BatteryOptimizationTile({required this.onRequest});

  final Future<void> Function() onRequest;

  @override
  State<_BatteryOptimizationTile> createState() =>
      _BatteryOptimizationTileState();
}

class _BatteryOptimizationTileState extends State<_BatteryOptimizationTile> {
  bool? _granted;
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    // Re-read on resume so the tile reflects a grant made from the system
    // Settings app (via the "Open settings" fallback) once the user returns.
    _lifecycleListener = AppLifecycleListener(onResume: _loadStatus);
    _loadStatus();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (mounted) {
      setState(() => _granted = status.isGranted);
    }
  }

  Future<void> _handleRequest() async {
    await widget.onRequest();
    // Re-read so the tile reflects the new state once the system dialog closes.
    await _loadStatus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_granted == true) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.check_circle, color: theme.colorScheme.primary),
        title: const Text('Background activity allowed'),
        subtitle: const Text('FarmCtl is exempt from battery optimisation.'),
      );
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.battery_saver),
      title: const Text('Allow background activity'),
      subtitle: const Text(
        'Recommended so background checks are not delayed while the app is '
        'closed.',
      ),
      trailing: FilledButton.tonal(
        onPressed: _handleRequest,
        child: const Text('Allow'),
      ),
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
  final parts = <String>[];
  if (hours > 0) {
    parts.add('$hours hour${hours == 1 ? '' : 's'}');
  }
  if (minutes > 0) {
    parts.add('$minutes minute${minutes == 1 ? '' : 's'}');
  }
  if (parts.isNotEmpty) {
    return parts.join(' ');
  }
  final seconds = duration.inSeconds;
  return '$seconds second${seconds == 1 ? '' : 's'}';
}
