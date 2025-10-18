import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/history_range.dart';
import '../providers/thermostat_providers.dart';
import '../widgets/thermostat_card.dart';
import '../widgets/thermostat_history_chart.dart';

class ThermostatDetailPage extends ConsumerStatefulWidget {
  const ThermostatDetailPage({required this.thermostatId, super.key});

  final String thermostatId;

  @override
  ConsumerState<ThermostatDetailPage> createState() =>
      _ThermostatDetailPageState();
}

class _ThermostatDetailPageState extends ConsumerState<ThermostatDetailPage> {
  ThermostatHistoryRange _range = ThermostatHistoryRange.day;

  @override
  Widget build(BuildContext context) {
    final summaryAsync = ref.watch(
      thermostatSummaryProvider(widget.thermostatId),
    );
    final historyAsync = ref.watch(
      thermostatHistoryProvider((
        thermostatId: widget.thermostatId,
        range: _range,
      )),
    );
    final refreshAsync = ref.watch(
      thermostatHistoryRefreshProvider((
        thermostatId: widget.thermostatId,
        prioritizeLastHour: true,
      )),
    );

    final title = summaryAsync.asData?.value?.thermostat.name ?? 'Thermostat';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            onPressed: refreshAsync.isLoading
                ? null
                : () {
                    ref.invalidate(
                      thermostatHistoryRefreshProvider((
                        thermostatId: widget.thermostatId,
                        prioritizeLastHour: true,
                      )),
                    );
                  },
            icon: refreshAsync.isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: 'Refresh history',
          ),
        ],
      ),
      body: summaryAsync.when(
        data: (summary) {
          if (summary == null) {
            return const _DetailNotFound();
          }
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(
                thermostatHistoryRefreshProvider((
                  thermostatId: widget.thermostatId,
                  prioritizeLastHour: true,
                )),
              );
              await ref.read(
                thermostatHistoryRefreshProvider((
                  thermostatId: widget.thermostatId,
                  prioritizeLastHour: true,
                )).future,
              );
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                ThermostatCard(summary: summary),
                const SizedBox(height: 24),
                Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'History',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Visualise previous readings and compare trends across different time frames.',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 16),
                            SegmentedButton<ThermostatHistoryRange>(
                              showSelectedIcon: false,
                              segments: [
                                for (final range
                                    in ThermostatHistoryRange.values)
                                  ButtonSegment(
                                    value: range,
                                    label: Text(range.label),
                                    tooltip: range.description,
                                  ),
                              ],
                              selected: {_range},
                              onSelectionChanged: (selection) {
                                if (selection.isEmpty) {
                                  return;
                                }
                                setState(() => _range = selection.first);
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (refreshAsync.isLoading)
                        const LinearProgressIndicator(minHeight: 2),
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: historyAsync.when(
                          data: (samples) => ThermostatHistoryChart(
                            samples: samples,
                            range: _range,
                          ),
                          loading: () => const SizedBox(
                            height: 180,
                            child: Center(child: CircularProgressIndicator()),
                          ),
                          error: (error, _) => _HistoryError(error: error),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => _DetailError(error: error),
      ),
    );
  }
}

class _DetailError extends StatelessWidget {
  const _DetailError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              'Failed to load thermostat.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '$error',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailNotFound extends StatelessWidget {
  const _DetailNotFound();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.device_thermostat,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              'Thermostat not found.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'It may have been removed or is no longer available.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.history, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 8),
        Text(
          'Unable to load history.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        Text(
          '$error',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
