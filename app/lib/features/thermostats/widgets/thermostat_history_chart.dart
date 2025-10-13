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
    super.key,
  });

  final List<TemperatureSample> samples;
  final ThermostatHistoryRange range;

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return SizedBox(
        height: 180,
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

    final minY = sorted.map((s) => s.valueC).reduce(min);
    final maxY = sorted.map((s) => s.valueC).reduce(max);
    final padding = max(0.5, (maxY - minY).abs() * 0.1);

    final minX = spots.first.x;
    final maxX = spots.last.x;
    final interval = _suggestedInterval(maxX - minX);

    return SizedBox(
      height: 240,
      child: LineChart(
        LineChartData(
          minX: minX,
          maxX: maxX == minX ? maxX + 1 : maxX,
          minY: minY - padding,
          maxY: maxY + padding,
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
                interval: _suggestedYInterval(minY, maxY),
                getTitlesWidget: (value, meta) => Text(
                  value.toStringAsFixed(1),
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
            horizontalInterval: _suggestedYInterval(minY, maxY),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) =>
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              getTooltipItems: (touchedSpots) {
                final formatter = _detailedFormatterForRange(range);
                return touchedSpots.map((spot) {
                  final timestamp = base.add(Duration(seconds: spot.x.toInt()));
                  return LineTooltipItem(
                    '${spot.y.toStringAsFixed(1)}°C\n${formatter.format(timestamp.toLocal())}',
                    Theme.of(context).textTheme.bodyMedium!,
                  );
                }).toList();
              },
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
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
      ),
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
}
