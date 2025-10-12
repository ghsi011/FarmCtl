import 'package:flutter/material.dart';

import '../models/thermostat.dart';
import '../models/thermostat_state.dart';

class ThermostatCard extends StatelessWidget {
  const ThermostatCard({
    required this.summary,
    this.onEdit,
    this.onDelete,
    super.key,
  });

  final ThermostatSummary summary;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final thermostat = summary.thermostat;
    final state = summary.state;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
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
                      const SizedBox(height: 8),
                      Text(
                        thermostat.rawUrl,
                        style: textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
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
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.thermostat, color: colorScheme.primary),
                const SizedBox(width: 12),
                Text(
                  'Range: ${thermostat.minC.toStringAsFixed(1)}°C – ${thermostat.maxC.toStringAsFixed(1)}°C',
                  style: textTheme.bodyLarge,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _LastSeenStatus(state: state),
          ],
        ),
      ),
    );
  }
}

enum _ThermostatMenuAction { edit, delete }

class _LastSeenStatus extends StatelessWidget {
  const _LastSeenStatus({this.state});

  final ThermostatState? state;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    if (state == null || state!.lastFetchedAt == null) {
      return Text(
        'No successful readings yet.',
        style: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }

    final fetchedAt = state!.lastFetchedAt!;
    final value = state!.lastValueC;
    final status = state!.status;
    final now = DateTime.now().toUtc();
    final difference = now.difference(fetchedAt);
    final relative = _formatRelativeDuration(difference);

    final statusText = switch (status) {
      ThermostatReadingStatus.ok =>
        value != null
            ? '${value.toStringAsFixed(1)}°C • Updated $relative'
            : 'Updated $relative',
      ThermostatReadingStatus.networkError =>
        'Last attempt failed: network error',
      ThermostatReadingStatus.httpError => 'Last attempt failed: server error',
      ThermostatReadingStatus.parseError =>
        'Last attempt failed: invalid payload',
      ThermostatReadingStatus.unknown => 'Last seen $relative',
    };

    final isError = status != ThermostatReadingStatus.ok;

    return Text(
      statusText,
      style: textTheme.bodyMedium?.copyWith(
        color: isError ? colorScheme.error : colorScheme.onSurfaceVariant,
      ),
    );
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
}
