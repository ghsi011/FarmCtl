import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/history_range.dart';
import '../models/temperature_sample.dart';
import '../providers/thermostat_providers.dart';
import '../widgets/history_range_selector.dart';
import '../widgets/thermostat_history_chart.dart';
import '../../../core/format/error_messages.dart';

class ThermostatHistoryFullscreenPage extends ConsumerStatefulWidget {
  const ThermostatHistoryFullscreenPage({
    required this.thermostatId,
    required this.initialRange,
    super.key,
  });

  final String thermostatId;
  final ThermostatHistoryRange initialRange;

  @override
  ConsumerState<ThermostatHistoryFullscreenPage> createState() =>
      _ThermostatHistoryFullscreenPageState();
}

class _ThermostatHistoryFullscreenPageState
    extends ConsumerState<ThermostatHistoryFullscreenPage> {
  @override
  void initState() {
    super.initState();
    // Honour a deep-linked range without forcing device orientation — the
    // chart is responsive in both portrait and landscape.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
              .read(selectedHistoryRangeProvider(widget.thermostatId).notifier)
              .state =
          widget.initialRange;
    });
  }

  void _setRange(ThermostatHistoryRange range) {
    ref.read(selectedHistoryRangeProvider(widget.thermostatId).notifier).state =
        range;
  }

  Future<void> _refreshHistory() async {
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

    final thermostat = summaryAsync.asData?.value?.thermostat;
    final thermostatName = thermostat?.name;
    final orientation = MediaQuery.of(context).orientation;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close full-screen chart',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          thermostatName != null
              ? '$thermostatName history'
              : 'Thermostat history',
        ),
        actions: [
          if (orientation == Orientation.landscape)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<ThermostatHistoryRange>(
                    value: range,
                    isExpanded: true,
                    onChanged: (value) {
                      if (value != null) {
                        _setRange(value);
                      }
                    },
                    items: [
                      for (final option in ThermostatHistoryRange.values)
                        DropdownMenuItem(
                          value: option,
                          child: Text(option.label),
                        ),
                    ],
                  ),
                ),
              ),
            ),
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
      body: SafeArea(
        child: OrientationBuilder(
          builder: (context, orientation) {
            final chart = _HistoryChartPane(
              historyAsync: historyAsync,
              range: range,
              minC: thermostat?.minC,
              maxC: thermostat?.maxC,
              onRetry: _refreshHistory,
              fullBleed: orientation == Orientation.landscape,
            );

            if (orientation == Orientation.landscape) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  // Range control lives in the AppBar in landscape to maximise
                  // chart space.
                  children: [Expanded(child: chart)],
                ),
              );
            }

            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HistoryRangeSelector(range: range, onChanged: _setRange),
                  const SizedBox(height: 4),
                  Text(
                    range.description,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(child: chart),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HistoryChartPane extends StatelessWidget {
  const _HistoryChartPane({
    required this.historyAsync,
    required this.range,
    required this.minC,
    required this.maxC,
    required this.onRetry,
    this.fullBleed = false,
  });

  final AsyncValue<List<TemperatureSample>> historyAsync;
  final ThermostatHistoryRange range;
  final double? minC;
  final double? maxC;
  final VoidCallback onRetry;
  final bool fullBleed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chartContent = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: historyAsync.when(
        data: (samples) => ThermostatHistoryChart(
          samples: samples,
          range: range,
          minC: minC,
          maxC: maxC,
          expand: true,
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _HistoryErrorView(error: error, onRetry: onRetry),
      ),
    );

    if (fullBleed) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: chartContent,
        ),
      );
    }

    return Card(clipBehavior: Clip.antiAlias, child: chartContent);
  }
}

class _HistoryErrorView extends StatelessWidget {
  const _HistoryErrorView({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
          const SizedBox(height: 12),
          Text(
            'Failed to load history',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            humanizeError(error),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
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
      ),
    );
  }
}
