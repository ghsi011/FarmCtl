import 'package:flutter/material.dart';

import '../../../core/format/relative_time.dart';
import '../../../core/format/semantics_text.dart';
import '../models/thermostat_state.dart';
import '../models/thermostat_status_presentation.dart';

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

    final statusPresentation = ThermostatStatusPresentation.fromState(state);
    // Only an out-of-range *temperature* turns the hero panel red. Connectivity
    // problems leave it neutral — the shown value is the last known-good one.
    final isDanger = statusPresentation.isDanger;
    final highlightColor = isDanger
        ? colorScheme.errorContainer
        : colorScheme.primaryContainer;
    final highlightOnColor = isDanger
        ? colorScheme.onErrorContainer
        : colorScheme.onPrimaryContainer;

    final now = DateTime.now().toUtc();
    final lastFetchedAt = state?.lastFetchedAt;
    final isStale =
        lastFetchedAt != null &&
        now.difference(lastFetchedAt) > const Duration(minutes: 30);

    // Spoken status uses the short label word (not the detail line) so the
    // temperature isn't read twice at two precisions.
    final semanticsValue = [
      if (hasTemperature) spokenText('Current $temperatureLabel.'),
      'Status: ${statusPresentation.label}.',
      'Target range ${thermostat.minC.toStringAsFixed(1)} to '
          '${thermostat.maxC.toStringAsFixed(1)} degrees Celsius.',
    ].join(' ');

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Thermostat ${thermostat.name}',
      value: semanticsValue,
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
                        if (lastFetchedAt != null)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                isStale ? 'Last update (stale)' : 'Last update',
                                style: textTheme.labelMedium?.copyWith(
                                  color: highlightOnColor.withValues(
                                    alpha: 0.72,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isStale) ...[
                                    Icon(
                                      Icons.schedule,
                                      size: 14,
                                      color: highlightOnColor,
                                    ),
                                    const SizedBox(width: 4),
                                  ],
                                  Text(
                                    formatRelativeDuration(
                                      now.difference(lastFetchedAt),
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
                      statusPresentation.icon,
                      size: 20,
                      color: statusPresentation.color(colorScheme),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: statusPresentation.label,
                              style: textTheme.bodyMedium?.copyWith(
                                color: statusPresentation.color(colorScheme),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            TextSpan(
                              text: '  ${statusPresentation.detail}',
                              style: textTheme.bodyMedium?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
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
