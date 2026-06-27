import 'package:flutter/material.dart';

import '../models/thermostat_state.dart';

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
    final isAlert = statusPresentation.isError;
    final highlightColor = isAlert
        ? colorScheme.errorContainer
        : colorScheme.primaryContainer;
    final highlightOnColor = isAlert
        ? colorScheme.onErrorContainer
        : colorScheme.onPrimaryContainer;

    final semanticsValue = [
      if (hasTemperature)
        'Current ${_normalizeForSemantics(temperatureLabel)}.',
      _normalizeForSemantics(statusPresentation.text),
      'Target range ${thermostat.minC.toStringAsFixed(1)} to '
          '${thermostat.maxC.toStringAsFixed(1)} degrees Celsius.',
    ].join(' ');

    return Semantics(
      container: true,
      button: onTap != null,
      label: 'Thermostat ${thermostat.name}',
      value: semanticsValue,
      hint: onTap != null ? 'Tap to open thermostat details.' : null,
      child: Card(
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: colorScheme.primaryContainer,
                      foregroundColor: colorScheme.onPrimaryContainer,
                      child: const Icon(Icons.thermostat),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            thermostat.name,
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            thermostat.rawUrl,
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (onRefresh != null)
                      IconButton(
                        onPressed: onRefresh,
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Refresh thermostat',
                      ),
                    if (onEdit != null || onDelete != null)
                      PopupMenuButton<_ThermostatMenuAction>(
                        tooltip: 'More actions',
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
                              child: Text('Edit details'),
                            ),
                          if (onDelete != null)
                            const PopupMenuItem(
                              value: _ThermostatMenuAction.delete,
                              child: Text('Delete thermostat'),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: highlightColor,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 220),
                                child: Text(
                                  temperatureLabel,
                                  key: ValueKey(temperatureLabel),
                                  style: textTheme.displaySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: highlightOnColor,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                supportingLabel,
                                style: textTheme.bodyMedium?.copyWith(
                                  color: highlightOnColor.withValues(
                                    alpha: 0.85,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (state?.lastFetchedAt != null)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                'Last update',
                                style: textTheme.labelMedium?.copyWith(
                                  color: highlightOnColor.withValues(
                                    alpha: 0.72,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _formatRelativeDuration(
                                  DateTime.now().toUtc().difference(
                                    state!.lastFetchedAt!,
                                  ),
                                ),
                                style: textTheme.bodyMedium?.copyWith(
                                  color: highlightOnColor,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _MetaChip(
                      icon: Icons.straighten,
                      label:
                          '${thermostat.minC.toStringAsFixed(1)}°C – ${thermostat.maxC.toStringAsFixed(1)}°C',
                      supportingLabel: 'Target range',
                    ),
                    _MetaChip(
                      icon: Icons.tag,
                      label: thermostat.id,
                      supportingLabel: 'Identifier',
                    ),
                    if (state?.statusMessage != null &&
                        state!.statusMessage!.isNotEmpty)
                      _MetaChip(
                        icon: Icons.info_outline,
                        label: state.statusMessage!,
                        supportingLabel: 'Last message',
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      statusPresentation.isError
                          ? Icons.warning_rounded
                          : Icons.check_circle,
                      size: 20,
                      color: statusPresentation.isError
                          ? colorScheme.error
                          : colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        statusPresentation.text,
                        style: textTheme.bodyMedium?.copyWith(
                          color: statusPresentation.isError
                              ? colorScheme.error
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _ThermostatMenuAction { edit, delete }

class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.icon,
    required this.label,
    required this.supportingLabel,
  });

  final IconData icon;
  final String label;
  final String supportingLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      constraints: const BoxConstraints(minWidth: 160),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  supportingLabel,
                  style: textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
      final text = message != null && message.isNotEmpty
          ? '$message • Updated $relative'
          : base;
      return _StatusPresentation(text: text, isError: false);
    case ThermostatReadingStatus.networkError:
      final base = (message != null && message.isNotEmpty)
          ? message
          : 'Last attempt failed: network error';
      return _StatusPresentation(
        text: '$base • Checked $relative',
        isError: true,
      );
    case ThermostatReadingStatus.outOfRange:
      final base = (message != null && message.isNotEmpty)
          ? message
          : 'Temperature outside configured range';
      final text = value != null
          ? '$base (${value.toStringAsFixed(2)}°C) • Updated $relative'
          : '$base • Updated $relative';
      return _StatusPresentation(text: text, isError: true);
    case ThermostatReadingStatus.httpError:
      final base = (message != null && message.isNotEmpty)
          ? message
          : 'Last attempt failed: server error';
      return _StatusPresentation(
        text: '$base • Checked $relative',
        isError: true,
      );
    case ThermostatReadingStatus.parseError:
      final base = (message != null && message.isNotEmpty)
          ? message
          : 'Last attempt failed: invalid payload';
      return _StatusPresentation(
        text: '$base • Checked $relative',
        isError: true,
      );
    case ThermostatReadingStatus.unknown:
      final text = (message != null && message.isNotEmpty)
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
