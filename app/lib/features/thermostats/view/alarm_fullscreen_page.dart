import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/background/thermostat_monitor.dart';
import '../models/thermostat_state.dart';
import '../providers/thermostat_providers.dart';

class AlarmFullScreenPage extends ConsumerWidget {
  const AlarmFullScreenPage({required this.thermostatId, super.key});

  final String thermostatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summaryAsync = ref.watch(thermostatSummaryProvider(thermostatId));

    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = colorScheme.surfaceContainerHighest;

    return Scaffold(
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
                return const _MissingThermostat();
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
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => _AlarmError(error: error),
          ),
        ),
      ),
    );
  }
}

class _AlarmContent extends ConsumerWidget {
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final valueText = currentValue != null
        ? '${currentValue!.toStringAsFixed(1)}°C'
        : 'Unavailable';

    final statusDetails = _buildStatusDetails(context, textTheme, colorScheme);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 24),
              Icon(
                Icons.warning_amber_rounded,
                size: 96,
                color: colorScheme.error,
              ),
              const SizedBox(height: 24),
              Text(
                thermostatName,
                style: textTheme.headlineMedium?.copyWith(
                  color: colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                valueText,
                style: textTheme.displayMedium?.copyWith(
                  color: colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Target range ${minC.toStringAsFixed(1)}°C – ${maxC.toStringAsFixed(1)}°C',
                style: textTheme.titleMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              statusDetails,
            ],
          ),
          _AlarmActions(
            thermostatId: thermostatId,
            silenceUntilOk: silenceUntilOk,
          ),
        ],
      ),
    );
  }

  Widget _buildStatusDetails(
    BuildContext context,
    TextTheme textTheme,
    ColorScheme colorScheme,
  ) {
    final buffer = <String>[];
    if (statusMessage != null && statusMessage!.isNotEmpty) {
      buffer.add(statusMessage!);
    }
    if (snoozedUntil != null) {
      final formattedTime = MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(snoozedUntil!.toLocal()));
      buffer.add('Snoozed until $formattedTime');
    }
    if (silenceUntilOk) {
      buffer.add('Silenced until reading returns to range.');
    }
    if (buffer.isEmpty) {
      switch (status) {
        case ThermostatReadingStatus.outOfRange:
          buffer.add('Temperature is outside the configured range.');
          break;
        case ThermostatReadingStatus.networkError:
        case ThermostatReadingStatus.httpError:
        case ThermostatReadingStatus.parseError:
        case ThermostatReadingStatus.unknown:
        case ThermostatReadingStatus.ok:
        case null:
          break;
      }
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton(
              onPressed: () =>
                  _setSnooze(context, ref, const Duration(minutes: 5)),
              child: const Text('Snooze 5 min'),
            ),
            FilledButton.tonal(
              onPressed: () =>
                  _setSnooze(context, ref, const Duration(minutes: 10)),
              child: const Text('Snooze 10 min'),
            ),
            FilledButton.tonal(
              onPressed: () =>
                  _setSnooze(context, ref, const Duration(minutes: 30)),
              child: const Text('Snooze 30 min'),
            ),
            OutlinedButton(
              onPressed: silenceUntilOk
                  ? null
                  : () => _setSilence(context, ref),
              child: const Text('Silence until OK'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        TextButton(
          onPressed: () async {
            await cancelAlarmNotification(thermostatId);
            if (!context.mounted) {
              return;
            }
            Navigator.of(context).pop();
          },
          child: Text('Dismiss', style: textTheme.titleMedium),
        ),
      ],
    );
  }
}

class _MissingThermostat extends StatelessWidget {
  const _MissingThermostat();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Text(
        'Thermostat not found.',
        style: textTheme.titleMedium?.copyWith(color: colorScheme.onSurface),
        textAlign: TextAlign.center,
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
          'Failed to load alarm details: $error',
          textAlign: TextAlign.center,
          style: textTheme.titleMedium?.copyWith(color: colorScheme.onSurface),
        ),
      ),
    );
  }
}
