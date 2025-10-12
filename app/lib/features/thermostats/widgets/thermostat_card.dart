import 'package:flutter/material.dart';

import '../models/thermostat.dart';

class ThermostatCard extends StatelessWidget {
  const ThermostatCard({
    required this.thermostat,
    this.onEdit,
    this.onDelete,
    super.key,
  });

  final Thermostat thermostat;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

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
          ],
        ),
      ),
    );
  }
}

enum _ThermostatMenuAction { edit, delete }
