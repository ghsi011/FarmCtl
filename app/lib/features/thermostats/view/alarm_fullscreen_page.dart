import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../core/background/thermostat_monitor.dart';
import '../../../core/format/error_messages.dart';
import '../../../core/format/relative_time.dart';
import '../../../core/format/semantics_text.dart';
import '../models/thermostat_state.dart';
import '../providers/thermostat_providers.dart';

class AlarmFullScreenPage extends ConsumerStatefulWidget {
  const AlarmFullScreenPage({required this.thermostatId, super.key});

  final String thermostatId;

  @override
  ConsumerState<AlarmFullScreenPage> createState() =>
      _AlarmFullScreenPageState();
}

class _AlarmFullScreenPageState extends ConsumerState<AlarmFullScreenPage> {
  @override
  void initState() {
    super.initState();
    // Keep the screen awake while an alarm is showing. Best-effort: ignore
    // platform failures (and the unsupported test environment).
    unawaited(WakelockPlus.enable().catchError((Object _) {}));
  }

  @override
  void dispose() {
    unawaited(WakelockPlus.disable().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thermostatId = widget.thermostatId;
    final summaryAsync = ref.watch(thermostatSummaryProvider(thermostatId));

    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = colorScheme.surfaceContainerHighest;

    // The alarm screen is the primary surface for acknowledging an out-of-range
    // alert. A hardware/predictive back gesture must route through the same
    // cancellation path as the in-page actions so the audible alarm and its
    // notification are always silenced when the page leaves the stack.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) {
          return;
        }
        await cancelAlarmNotification(thermostatId);
        if (context.mounted) {
          Navigator.of(context).pop(result);
        }
      },
      child: Scaffold(
        backgroundColor: backgroundColor,
        body: SafeArea(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  backgroundColor,
                  Color.alphaBlend(
                    colorScheme.primary.withValues(alpha: 0.05),
                    backgroundColor,
                  ),
                ],
              ),
            ),
            child: summaryAsync.when(
              data: (summary) {
                if (summary == null) {
                  return _MissingThermostat(thermostatId: thermostatId);
                }

                final thermostat = summary.thermostat;
                final state = summary.state;
                return _AlarmContent(
                  thermostatId: thermostat.id,
                  thermostatName: thermostat.name,
                  currentValue: state?.lastValueC,
                  minC: thermostat.minC,
                  maxC: thermostat.maxC,
                  status: state?.status,
                  statusMessage: state?.statusMessage,
                  snoozedUntil: state?.snoozedUntil,
                  silenceUntilOk: state?.silenceUntilOk ?? false,
                  lastAlarmAt: state?.lastAlarmAt,
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stackTrace) => _AlarmError(error: error),
            ),
          ),
        ),
      ),
    );
  }
}

class _AlarmContent extends ConsumerStatefulWidget {
  const _AlarmContent({
    required this.thermostatId,
    required this.thermostatName,
    required this.currentValue,
    required this.minC,
    required this.maxC,
    required this.status,
    required this.statusMessage,
    required this.snoozedUntil,
    required this.silenceUntilOk,
    required this.lastAlarmAt,
  });

  final String thermostatId;
  final String thermostatName;
  final double? currentValue;
  final double minC;
  final double maxC;
  final ThermostatReadingStatus? status;
  final String? statusMessage;
  final DateTime? snoozedUntil;
  final bool silenceUntilOk;
  final DateTime? lastAlarmAt;

  @override
  ConsumerState<_AlarmContent> createState() => _AlarmContentState();
}

class _AlarmContentState extends ConsumerState<_AlarmContent> {
  String get _valueText => widget.currentValue != null
      ? '${widget.currentValue!.toStringAsFixed(1)}°C'
      : 'Unavailable';

  String? get _elapsedText {
    final since = widget.lastAlarmAt;
    if (since == null) {
      return null;
    }
    return 'Out of range for ${formatElapsed(DateTime.now().toUtc().difference(since))}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final statusDetails = _buildStatusDetails(context, textTheme, colorScheme);
    final elapsed = _elapsedText;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.sizeOf(context).height - 48,
        ),
        child: IntrinsicHeight(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Semantics(
                liveRegion: true,
                container: true,
                label: spokenText(
                  'Alarm. ${widget.thermostatName}. Current $_valueText. '
                  'Safe range ${widget.minC.toStringAsFixed(1)}°C to '
                  '${widget.maxC.toStringAsFixed(1)}°C.'
                  '${elapsed != null ? ' $elapsed.' : ''}',
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 24),
                    // Decorative — the danger is already in the live-region
                    // label above, so don't announce "Warning" separately.
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 96,
                      color: colorScheme.error,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      widget.thermostatName,
                      style: textTheme.headlineMedium?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _valueText,
                      style: textTheme.displayMedium?.copyWith(
                        color: colorScheme.error,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Target range ${widget.minC.toStringAsFixed(1)}°C – ${widget.maxC.toStringAsFixed(1)}°C',
                      style: textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (elapsed != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        elapsed,
                        style: textTheme.titleMedium?.copyWith(
                          color: colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 24),
                    statusDetails,
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _AlarmActions(
                thermostatId: widget.thermostatId,
                silenceUntilOk: widget.silenceUntilOk,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusDetails(
    BuildContext context,
    TextTheme textTheme,
    ColorScheme colorScheme,
  ) {
    final buffer = <String>[];
    if (widget.statusMessage != null && widget.statusMessage!.isNotEmpty) {
      buffer.add(widget.statusMessage!);
    }
    if (widget.snoozedUntil != null) {
      final formattedTime = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(widget.snoozedUntil!.toLocal()));
      buffer.add('Snoozed until $formattedTime');
    }
    if (widget.silenceUntilOk) {
      buffer.add('Silenced until the reading returns to range.');
    }
    if (buffer.isEmpty && widget.status == ThermostatReadingStatus.outOfRange) {
      buffer.add('Temperature is outside the configured range.');
    }

    return Column(
      children: buffer
          .map(
            (line) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                line,
                style: textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          )
          .toList(),
    );
  }
}

class _AlarmActions extends ConsumerWidget {
  const _AlarmActions({
    required this.thermostatId,
    required this.silenceUntilOk,
  });

  final String thermostatId;
  final bool silenceUntilOk;

  Future<void> _setSnooze(
    BuildContext context,
    WidgetRef ref,
    Duration duration,
  ) async {
    final repository = ref.read(thermostatRepositoryProvider);
    final until = DateTime.now().toUtc().add(duration);
    await repository.updateSnoozedUntil(thermostatId, until);
    await cancelAlarmNotification(thermostatId);
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _setSilence(BuildContext context, WidgetRef ref) async {
    final repository = ref.read(thermostatRepositoryProvider);
    await repository.updateSilenceUntilOk(thermostatId, true);
    await repository.updateSnoozedUntil(thermostatId, null);
    await cancelAlarmNotification(thermostatId);
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _acknowledge(BuildContext context, WidgetRef ref) async {
    // Stop the current alert but leave monitoring armed — the next out-of-range
    // run will alert again. No snooze/silence flag is set.
    await cancelAlarmNotification(thermostatId);
    if (context.mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Primary, safest action: stop the noise, stay armed.
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          onPressed: () => _acknowledge(context, ref),
          child: const Text('Acknowledge'),
        ),
        const SizedBox(height: 6),
        Text(
          "Stops the alarm now. You'll be alerted again if it stays out of range.",
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        FilledButton.tonal(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => _setSnooze(context, ref, const Duration(minutes: 5)),
          child: const Text('Snooze 5 minutes'),
        ),
        const SizedBox(height: 12),
        FilledButton.tonal(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () =>
              _setSnooze(context, ref, const Duration(minutes: 10)),
          child: const Text('Snooze 10 minutes'),
        ),
        const SizedBox(height: 12),
        FilledButton.tonal(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () =>
              _setSnooze(context, ref, const Duration(minutes: 30)),
          child: const Text('Snooze 30 minutes'),
        ),
        const SizedBox(height: 12),
        // Most-suppressing action, visually separated and clearly labelled.
        Tooltip(
          message: silenceUntilOk
              ? 'Already silenced until the reading returns to range'
              : 'Mutes alerts until the temperature is back in range',
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: silenceUntilOk ? null : () => _setSilence(context, ref),
            icon: const Icon(Icons.notifications_off_outlined),
            label: const Text('Silence until back in range'),
          ),
        ),
      ],
    );
  }
}

class _MissingThermostat extends StatelessWidget {
  const _MissingThermostat({required this.thermostatId});

  final String thermostatId;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Thermostat not found. It may have been removed.',
              style: textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: () async {
                await cancelAlarmNotification(thermostatId);
                if (context.mounted) {
                  Navigator.of(context).pop();
                }
              },
              child: const Text('Dismiss'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlarmError extends StatelessWidget {
  const _AlarmError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          humanizeError(error),
          textAlign: TextAlign.center,
          style: textTheme.titleMedium?.copyWith(color: colorScheme.onSurface),
        ),
      ),
    );
  }
}
