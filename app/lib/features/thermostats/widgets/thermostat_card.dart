import 'package:flutter/material.dart';

enum ThermostatStatus { normal, warning, critical }

class ThermostatCard extends StatelessWidget {
  const ThermostatCard({
    required this.name,
    required this.temperature,
    required this.lastUpdated,
    this.status = ThermostatStatus.normal,
    super.key,
  });

  final String name;
  final String temperature;
  final String lastUpdated;
  final ThermostatStatus status;

  Color _statusColor(ColorScheme colorScheme) {
    switch (status) {
      case ThermostatStatus.normal:
        return colorScheme.primary;
      case ThermostatStatus.warning:
        return colorScheme.tertiary;
      case ThermostatStatus.critical:
        return colorScheme.error;
    }
  }

  IconData _statusIcon() {
    switch (status) {
      case ThermostatStatus.normal:
        return Icons.check_circle;
      case ThermostatStatus.warning:
        return Icons.error_outline;
      case ThermostatStatus.critical:
        return Icons.warning_amber;
    }
  }

  String _statusLabel() {
    switch (status) {
      case ThermostatStatus.normal:
        return 'Within range';
      case ThermostatStatus.warning:
        return 'Check soon';
      case ThermostatStatus.critical:
        return 'Out of range';
    }
  }

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
            Text(name, style: textTheme.titleLarge),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.thermostat, size: 36, color: colorScheme.primary),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      temperature,
                      style: textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      lastUpdated,
                      style: textTheme.bodyMedium?.copyWith(
                        color: colorScheme.outline,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Icon(_statusIcon(), color: _statusColor(colorScheme)),
                    const SizedBox(height: 4),
                    Text(
                      _statusLabel(),
                      style: textTheme.bodyMedium?.copyWith(
                        color: _statusColor(colorScheme),
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
    );
  }
}
