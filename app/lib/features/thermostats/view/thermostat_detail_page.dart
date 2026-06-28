import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/thermostat_providers.dart';
import '../widgets/history_range_selector.dart';
import '../widgets/thermostat_card.dart';
import '../widgets/thermostat_history_chart.dart';
import '../../../core/format/error_messages.dart';
import '../../../core/router/app_router.dart';

class ThermostatDetailPage extends ConsumerStatefulWidget {
  const ThermostatDetailPage({required this.thermostatId, super.key});

  final String thermostatId;

  @override
  ConsumerState<ThermostatDetailPage> createState() =>
      _ThermostatDetailPageState();
}

class _ThermostatDetailPageState extends ConsumerState<ThermostatDetailPage> {
  void _refreshHistory() {
    ref.invalidate(
      thermostatHistoryRefreshProvider((
        thermostatId: widget.thermostatId,
        prioritizeLastHour: true,
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final summaryAsync = ref.watch(
      thermostatSummaryProvider(widget.thermostatId),
    );
    final range = ref.watch(selectedHistoryRangeProvider(widget.thermostatId));
    final historyAsync = ref.watch(
      thermostatHistoryProvider((
        thermostatId: widget.thermostatId,
        range: range,
      )),
    );
    final refreshAsync = ref.watch(
      thermostatHistoryRefreshProvider((
        thermostatId: widget.thermostatId,
        prioritizeLastHour: true,
      )),
    );

    final title = summaryAsync.asData?.value?.thermostat.name ?? 'Thermostat';
    // A missing thermostat (deleted/removed) has data that is explicitly null.
    final isMissing = summaryAsync.hasValue && summaryAsync.value == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (!isMissing)
            IconButton(
              onPressed: refreshAsync.isLoading ? null : _refreshHistory,
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
            return _DetailNotFound(
              onBack: () => context.canPop()
                  ? context.pop()
                  : context.goNamed(ThermostatsRoute.name),
            );
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
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'History',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Visualise previous readings and compare trends across different time frames.',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  icon: const Icon(Icons.fullscreen),
                                  tooltip: 'Open full-screen chart',
                                  onPressed: () {
                                    context.pushNamed(
                                      ThermostatHistoryFullscreenRoute.name,
                                      pathParameters: {
                                        'id': widget.thermostatId,
                                      },
                                      queryParameters: {'range': range.name},
                                    );
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            HistoryRangeSelector(
                              range: range,
                              onChanged: (value) =>
                                  ref
                                          .read(
                                            selectedHistoryRangeProvider(
                                              widget.thermostatId,
                                            ).notifier,
                                          )
                                          .state =
                                      value,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: historyAsync.when(
                          data: (samples) => ThermostatHistoryChart(
                            samples: samples,
                            range: range,
                            minC: summary.thermostat.minC,
                            maxC: summary.thermostat.maxC,
                          ),
                          loading: () => const SizedBox(
                            height: 240,
                            child: Center(child: CircularProgressIndicator()),
                          ),
                          error: (error, _) => _HistoryError(
                            error: error,
                            onRetry: _refreshHistory,
                          ),
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
              'Failed to load thermostat',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              humanizeError(error),
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
  const _DetailNotFound({required this.onBack});

  final VoidCallback onBack;

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
              'Thermostat not found',
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
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back to thermostats'),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.history, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 8),
        Text(
          'Unable to load history',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        Text(
          humanizeError(error),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
        ),
      ],
    );
  }
}
