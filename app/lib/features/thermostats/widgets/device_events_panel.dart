import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/thermostat_database.dart';
import '../providers/thermostat_providers.dart';

/// Local, read-only event history; intentionally separate from temperature samples.
class DeviceEventsPanel extends ConsumerWidget {
  const DeviceEventsPanel({required this.deviceRef, super.key});

  final String? deviceRef;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final configured = deviceRef != null && deviceRef!.isNotEmpty;
    final events = configured
        ? ref.watch(deviceEventsProvider(deviceRef!))
        : const AsyncValue<List<DeviceEvent>>.data([]);
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.event_note, color: colors.secondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Recent device activity',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Text(
                'LOCAL',
                semanticsLabel: 'Stored on this device',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            'Troubleshooting events, separate from temperature history.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          if (!configured)
            const _Message(
              icon: Icons.link_off,
              text: 'Link a device report to collect activity.',
            )
          else
            events.when(
              loading: () => const _Message(
                icon: Icons.sync,
                text: 'Loading saved activity…',
              ),
              error: (error, stack) => const _Message(
                icon: Icons.cloud_off,
                text: 'Saved activity is unavailable.',
              ),
              data: (items) => items.isEmpty
                  ? const _Message(
                      icon: Icons.history,
                      text:
                          'No stored events yet. Older reports may not include event history.',
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < items.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 18,
                              color: colors.outlineVariant.withValues(
                                alpha: .65,
                              ),
                            ),
                          _EventRow(event: items[i]),
                        ],
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});
  final DeviceEvent event;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (title, icon) = switch (event.code) {
      'sensor_recovered' => (
        'Temperature sensor recovered',
        Icons.check_circle_outline,
      ),
      'sensor_failed' => (
        'Temperature sensor could not be read',
        Icons.warning_amber_rounded,
      ),
      'temperature_publish_failed' => (
        'Temperature update could not be sent',
        Icons.cloud_upload_outlined,
      ),
      _ => ('Device activity', Icons.info_outline),
    };
    final occurred = event.occurredAt;
    final timestamp = occurred == null
        ? 'Occurrence time not recorded'
        : 'Occurred ${_dateTime(occurred)}';
    return Semantics(
      label:
          '$title. $timestamp. ${event.count > 1 ? 'Repeated ${event.count} times.' : ''}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 21,
            color: event.code == 'sensor_recovered'
                ? colors.primary
                : colors.secondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  timestamp,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (event.count > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Repeated ${event.count} times',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.secondary,
                      ),
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

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        icon,
        size: 19,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    ],
  );
}

String _dateTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour < 12 ? 'AM' : 'PM';
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} at $hour:$minute $period';
}
