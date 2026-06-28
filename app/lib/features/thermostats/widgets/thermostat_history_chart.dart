import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/history_range.dart';
import '../models/temperature_sample.dart';

class ThermostatHistoryChart extends StatelessWidget {
  const ThermostatHistoryChart({
    required this.samples,
    required this.range,
    this.minC,
    this.maxC,
    this.expand = false,
    super.key,
  });

  final List<TemperatureSample> samples;
  final ThermostatHistoryRange range;

  /// The configured safe range; when provided, the chart draws threshold lines
  /// and a shaded safe-zone band so excursions are obvious at a glance.
  final double? minC;
  final double? maxC;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return SizedBox(
        height: 240,
        child: Center(
          child: Text(
            'No history available for this range yet.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final sorted = [...samples]
      ..sort((a, b) => a.observedAt.compareTo(b.observedAt));
    final base = sorted.first.observedAt;
    final spots = sorted
        .map(
          (sample) => FlSpot(
            sample.observedAt.difference(base).inSeconds.toDouble(),
            sample.valueC,
          ),
        )
        .toList();

    // Render continuous line; do not break segments (avoid visual gaps)
    final segmentedSpots = <List<FlSpot>>[spots];

    final scheme = Theme.of(context).colorScheme;
    final dataMin = sorted.map((s) => s.valueC).reduce(min);
    final dataMax = sorted.map((s) => s.valueC).reduce(max);
    final padding = max(0.5, (dataMax - dataMin).abs() * 0.1);
    final dataSpan = max(dataMax - dataMin, 0.5);

    // Pull the safe-range bounds into view when they're close enough to the
    // data that the trace's relationship to them matters — a very wide
    // configured range must not squash the trace flat.
    final lo = minC;
    final hi = maxC;
    var viewMin = dataMin - padding;
    var viewMax = dataMax + padding;
    if (lo != null &&
        lo >= dataMin - dataSpan * 1.5 &&
        lo - padding < viewMin) {
      viewMin = lo - padding;
    }
    if (hi != null &&
        hi <= dataMax + dataSpan * 1.5 &&
        hi + padding > viewMax) {
      viewMax = hi + padding;
    }
    final yInterval = _suggestedYInterval(viewMin, viewMax);
    final tickDecimals = yInterval < 1 ? 1 : 0;

    final minX = spots.first.x;
    final maxX = spots.last.x;
    final interval = _suggestedInterval(maxX - minX);

    final semanticsFormatter = DateFormat.yMMMd().add_Hm();
    final semanticsValue =
        'From ${semanticsFormatter.format(sorted.first.observedAt.toLocal())} '
        'to ${semanticsFormatter.format(sorted.last.observedAt.toLocal())}. '
        'Temperatures ranged from ${dataMin.toStringAsFixed(1)} to '
        '${dataMax.toStringAsFixed(1)} degrees Celsius.'
        '${lo != null && hi != null ? ' Safe range ${lo.toStringAsFixed(1)} to ${hi.toStringAsFixed(1)} degrees Celsius.' : ''}';

    HorizontalLine boundLine(double y, String label) => HorizontalLine(
      y: y,
      color: scheme.error.withValues(alpha: 0.7),
      strokeWidth: 1.5,
      dashArray: const [6, 4],
      label: HorizontalLineLabel(
        show: true,
        alignment: Alignment.topRight,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.error),
        labelResolver: (_) => label,
      ),
    );

    final chart = LineChart(
      LineChartData(
        minX: minX,
        maxX: maxX == minX ? maxX + 1 : maxX,
        minY: viewMin,
        maxY: viewMax,
        clipData: const FlClipData.all(),
        rangeAnnotations: RangeAnnotations(
          horizontalRangeAnnotations: [
            if (lo != null && hi != null)
              HorizontalRangeAnnotation(
                y1: lo,
                y2: hi,
                color: scheme.primary.withValues(alpha: 0.06),
              ),
          ],
        ),
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            if (lo != null) boundLine(lo, 'Min'),
            if (hi != null) boundLine(hi, 'Max'),
          ],
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            axisNameSize: 18,
            axisNameWidget: Text(
              '°C',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: yInterval,
              getTitlesWidget: (value, meta) => Text(
                value.toStringAsFixed(tickDecimals),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: interval,
              reservedSize: 36,
              getTitlesWidget: (value, meta) {
                final date = base.add(Duration(seconds: value.toInt()));
                final formatter = _formatterForRange(range);
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    formatter.format(date.toLocal()),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                );
              },
            ),
          ),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => scheme.surfaceContainerHighest,
            getTooltipItems: (touchedSpots) {
              final formatter = _detailedFormatterForRange(range);
              final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w600,
              );
              return touchedSpots.map((spot) {
                final timestamp = base.add(Duration(seconds: spot.x.toInt()));
                return LineTooltipItem(
                  '${spot.y.toStringAsFixed(1)}°C\n${formatter.format(timestamp.toLocal())}',
                  style ?? const TextStyle(),
                );
              }).toList();
            },
          ),
        ),
        lineBarsData: [
          for (final seg in segmentedSpots)
            LineChartBarData(
              spots: seg,
              isCurved: false,
              barWidth: 3,
              color: Theme.of(context).colorScheme.primary,
              belowBarData: BarAreaData(
                show: true,
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.12),
              ),
              dotData: const FlDotData(show: false),
            ),
        ],
      ),
    );

    return Semantics(
      container: true,
      label: 'Temperature history for ${range.label}',
      value: semanticsValue,
      child: expand
          ? SizedBox.expand(child: chart)
          : SizedBox(height: 240, child: chart),
    );
  }

  double _suggestedInterval(double span) {
    if (span <= 0) {
      return 1;
    }
    const intervals = <double>[
      1,
      300,
      900,
      1800,
      3600,
      7200,
      14400,
      28800,
      43200,
      86400,
    ];
    for (final candidate in intervals) {
      if (span / candidate <= 5) {
        return candidate;
      }
    }
    return (span / 5).ceilToDouble();
  }

  double _suggestedYInterval(double minY, double maxY) {
    final span = (maxY - minY).abs();
    if (span == 0) {
      return 1;
    }
    const steps = <double>[0.5, 1, 2, 5, 10];
    for (final step in steps) {
      if (span / step <= 5) {
        return step;
      }
    }
    return span / 5;
  }

  DateFormat _formatterForRange(ThermostatHistoryRange range) {
    switch (range) {
      case ThermostatHistoryRange.hour:
        return DateFormat.Hm();
      case ThermostatHistoryRange.day:
        return DateFormat.Hm();
      case ThermostatHistoryRange.week:
        return DateFormat.Md();
      case ThermostatHistoryRange.month:
        return DateFormat.Md();
      case ThermostatHistoryRange.year:
        return DateFormat.MMMd();
      case ThermostatHistoryRange.all:
        return DateFormat.yMMM();
    }
  }

  DateFormat _detailedFormatterForRange(ThermostatHistoryRange range) {
    switch (range) {
      case ThermostatHistoryRange.hour:
      case ThermostatHistoryRange.day:
        return DateFormat('MMM d • HH:mm');
      case ThermostatHistoryRange.week:
      case ThermostatHistoryRange.month:
        return DateFormat('MMM d • HH:mm');
      case ThermostatHistoryRange.year:
      case ThermostatHistoryRange.all:
        return DateFormat('MMM d, yyyy • HH:mm');
    }
  }

  // Gap threshold removed; chart is continuous based on aggregated samples
}
