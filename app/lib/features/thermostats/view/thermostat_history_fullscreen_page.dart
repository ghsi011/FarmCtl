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
                    value: _range,
                    isExpanded: true,
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _range = value);
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
              refreshAsync: refreshAsync,
              range: _range,
              fullBleed: orientation == Orientation.landscape,
            );

            if (orientation == Orientation.landscape) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Controls moved to AppBar in landscape to maximise chart space
                    Expanded(child: chart),
                  ],
                ),
              );
            }

            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _HistoryControls(
                    range: _range,
                    onRangeChanged: (range) {
                      setState(() => _range = range);
                    },
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

// Legacy landscape controls removed; controls now live in the AppBar.

class _HistoryControls extends StatelessWidget {
  const _HistoryControls({required this.range, required this.onRangeChanged});

  final ThermostatHistoryRange range;
  final ValueChanged<ThermostatHistoryRange> onRangeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Compact, single-row controls to maximise vertical space for the chart
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Range',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<ThermostatHistoryRange>(
                  value: range,
                  isExpanded: true,
                  onChanged: (value) {
                    if (value != null) {
                      onRangeChanged(value);
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
          ],
        ),
        const SizedBox(height: 4),
        Text(
          range.description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _HistoryChartPane extends StatelessWidget {
  const _HistoryChartPane({
    required this.historyAsync,
    required this.refreshAsync,
    required this.range,
    this.fullBleed = false,
  });

  final AsyncValue<List<TemperatureSample>> historyAsync;
  final AsyncValue<void> refreshAsync;
  final ThermostatHistoryRange range;
  final bool fullBleed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chartContent = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (refreshAsync.isLoading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
