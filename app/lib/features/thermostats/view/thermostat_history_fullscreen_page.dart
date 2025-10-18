import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/history_range.dart';
import '../models/temperature_sample.dart';
import '../providers/thermostat_providers.dart';
import '../widgets/thermostat_history_chart.dart';

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
  late ThermostatHistoryRange _range;

  @override
  void initState() {
    super.initState();
    _range = widget.initialRange;
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
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

    final thermostatName = summaryAsync.asData?.value?.thermostat.name;

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
            final controls = _HistoryControls(
              range: _range,
              onRangeChanged: (range) {
                setState(() => _range = range);
              },
            );

            final chart = _HistoryChartPane(
              historyAsync: historyAsync,
              refreshAsync: refreshAsync,
              range: _range,
            );

            if (orientation == Orientation.landscape) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: controls,
                    ),
                    const SizedBox(width: 24),
                    Expanded(child: chart),
                  ],
                ),
              );
            }

            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  controls,
                  const SizedBox(height: 16),
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

class _HistoryControls extends StatelessWidget {
  const _HistoryControls({required this.range, required this.onRangeChanged});

  final ThermostatHistoryRange range;
  final ValueChanged<ThermostatHistoryRange> onRangeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Range',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<ThermostatHistoryRange>(
              showSelectedIcon: false,
              segments: [
                for (final option in ThermostatHistoryRange.values)
                  ButtonSegment(
                    value: option,
                    label: Text(option.label),
                    tooltip: option.description,
                  ),
              ],
              selected: {range},
              onSelectionChanged: (selection) {
                if (selection.isEmpty) {
                  return;
                }
                onRangeChanged(selection.first);
              },
            ),
            const SizedBox(height: 16),
            Text(
              range.description,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Charts are optimised for horizontal space in this view. Pinch or drag across the graph to inspect temperature changes.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistoryChartPane extends StatelessWidget {
  const _HistoryChartPane({
    required this.historyAsync,
    required this.refreshAsync,
    required this.range,
  });

  final AsyncValue<List<TemperatureSample>> historyAsync;
  final AsyncValue<void> refreshAsync;
  final ThermostatHistoryRange range;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (refreshAsync.isLoading)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: historyAsync.when(
                data: (samples) => ThermostatHistoryChart(
                  samples: samples,
                  range: range,
                  expand: true,
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => _HistoryErrorView(error: error),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryErrorView extends StatelessWidget {
  const _HistoryErrorView({required this.error});

  final Object error;

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
            'Failed to load history.',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            '$error',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
