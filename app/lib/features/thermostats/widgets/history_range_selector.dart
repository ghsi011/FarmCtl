import 'package:flutter/material.dart';

import '../models/history_range.dart';

/// A single, consistent control for picking the history time range, used by
/// both the detail page and the full-screen chart. Scrolls horizontally so the
/// six segments never overflow on narrow phones or at large text scales.
class HistoryRangeSelector extends StatelessWidget {
  const HistoryRangeSelector({
    required this.range,
    required this.onChanged,
    super.key,
  });

  final ThermostatHistoryRange range;
  final ValueChanged<ThermostatHistoryRange> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<ThermostatHistoryRange>(
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
          onChanged(selection.first);
        },
      ),
    );
  }
}
