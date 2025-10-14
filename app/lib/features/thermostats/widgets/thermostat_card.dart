import 'package:flutter/material.dart';

import '../models/thermostat_state.dart';

class _StatusPresentation {
  const _StatusPresentation({required this.text, required this.isError});

  final String text;
  final bool isError;
}

_StatusPresentation _describeStatus(ThermostatState? state) {
  if (state == null || state.lastFetchedAt == null) {
    return const _StatusPresentation(
      text: 'No successful readings yet.',
      isError: false,
    );
  }

  final fetchedAt = state.lastFetchedAt!;
  final value = state.lastValueC;
  final status = state.status;
  final message = state.statusMessage;
  final now = DateTime.now().toUtc();
  final difference = now.difference(fetchedAt);
  final relative = _formatRelativeDuration(difference);

  switch (status) {
    case ThermostatReadingStatus.ok:
      final base = value != null
          ? '${value.toStringAsFixed(2)}°C • Updated $relative'
          : 'Updated $relative';
      final text = message != null ? '$message • Updated $relative' : base;
      return _StatusPresentation(text: text, isError: false);
    case ThermostatReadingStatus.networkError:
      final base = message ?? 'Last attempt failed: network error';
      return _StatusPresentation(
        text: '$base • Checked $relative',
        isError: true,
      );
    case ThermostatReadingStatus.outOfRange:
      final base = message ?? 'Temperature outside configured range';
      final text = value != null
          ? '$base (${value.toStringAsFixed(2)}°C) • Updated $relative'
          : '$base • Updated $relative';
      return _StatusPresentation(text: text, isError: true);
    case ThermostatReadingStatus.httpError:
      final base = message ?? 'Last attempt failed: server error';
      return _StatusPresentation(
        text: '$base • Checked $relative',
        isError: true,
      );
    case ThermostatReadingStatus.parseError:
      final base = message ?? 'Last attempt failed: invalid payload';
      return _StatusPresentation(
        text: '$base • Checked $relative',
        isError: true,
      );
    case ThermostatReadingStatus.unknown:
      final text = message != null
          ? '$message • Checked $relative'
          : 'Last seen $relative';
      return _StatusPresentation(text: text, isError: true);
  }
}

String _formatRelativeDuration(Duration difference) {
  final seconds = difference.inSeconds.abs();
  if (seconds < 60) {
    return 'just now';
  }
  final minutes = difference.inMinutes;
  if (minutes.abs() < 60) {
    final value = minutes.abs();
    final unit = value == 1 ? 'min' : 'mins';
    return '$value $unit ago';
  }
  final hours = difference.inHours;
  if (hours.abs() < 24) {
    final value = hours.abs();
    final unit = value == 1 ? 'hour' : 'hours';
    return '$value $unit ago';
  }
  final days = difference.inDays;
  final unit = days.abs() == 1 ? 'day' : 'days';
  return '${days.abs()} $unit ago';
}

String _normalizeForSemantics(String input) {
  return input
      .replaceAll('°C', ' degrees Celsius')
      .replaceAll('•', '.')
      .replaceAll('  ', ' ')
      .trim();
}

class ThermostatCard extends StatelessWidget {
  const ThermostatCard({
    required this.summary,
    this.onEdit,
    this.onDelete,
    this.onRefresh,
    this.onTap,
    super.key,
  });

  final ThermostatSummary summary;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onRefresh;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final thermostat = summary.thermostat;
    final state = summary.state;
    final temperature = state?.lastValueC;
    final hasTemperature = temperature != null;
    final temperatureLabel = hasTemperature
        ? '${temperature.toStringAsFixed(1)}°C'
        : '--°C';
    final supportingLabel = hasTemperature
        ? 'Current temperature'
        : 'Awaiting first reading';

    final statusPresentation = _describeStatus(state);
    final semanticsValue = [
      if (hasTemperature)
        'Current ${_normalizeForSemantics(temperatureLabel)}.',
      _normalizeForSemantics(statusPresentation.text),
      'Target range ${thermostat.minC.toStringAsFixed(1)} to '
          '${thermostat.maxC.toStringAsFixed(1)} degrees Celsius.',
    ].join(' ');

    return MergeSemantics(
      child: Semantics(
        container: true,
        label: 'Thermostat ${thermostat.name}',
        value: semanticsValue,
        hint: onTap != null ? 'Tap to view details.' : null,
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(thermostat.name, style: textTheme.titleLarge),
                            const SizedBox(height: 6),
                            Text(
                              thermostat.rawUrl,
                              style: textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (onRefresh != null)
                        IconButton(
                          onPressed: onRefresh,
                          tooltip: 'Refresh',
                          icon: const Icon(Icons.refresh),
                        ),
                      if (onEdit != null || onDelete != null)
                        PopupMenuButton<_ThermostatMenuAction>(
                          onSelected: (value) {
                            switch (value) {
                              case _ThermostatMenuAction.edit:
                                onEdit?.call();
                                break;
                              case _ThermostatMenuAction.delete:
                                onDelete?.call();
                                break;
                            }
                          },
                          itemBuilder: (context) => [
                            if (onEdit != null)
                              const PopupMenuItem(
                                value: _ThermostatMenuAction.edit,
                                child: Text('Edit'),
                              ),
                            if (onDelete != null)
                              const PopupMenuItem(
                                value: _ThermostatMenuAction.delete,
                                child: Text('Delete'),
                              ),
                          ],
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(
                        colors: [
                          colorScheme.primaryContainer.withValues(alpha: 0.65),
                          colorScheme.surfaceContainerHighest.withValues(
                            alpha: 0.85,
                          ),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            temperatureLabel,
                            style: textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onPrimaryContainer,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            supportingLabel,
                            style: textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onPrimaryContainer.withValues(
                                alpha: 0.8,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Icon(Icons.thermostat, color: colorScheme.primary),
                      const SizedBox(width: 12),
                      Text(
                        '${thermostat.minC.toStringAsFixed(1)}°C – ${thermostat.maxC.toStringAsFixed(1)}°C',
                        style: textTheme.titleMedium,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Target range',
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _LastSeenStatus(presentation: statusPresentation),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _ThermostatMenuAction { edit, delete }

class _LastSeenStatus extends StatelessWidget {
  const _LastSeenStatus({required this.presentation});

  final _StatusPresentation presentation;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return Text(
      presentation.text,
      style: textTheme.bodyMedium?.copyWith(
        color: presentation.isError
            ? colorScheme.error
            : colorScheme.onSurfaceVariant,
      ),
    );
  }
}
