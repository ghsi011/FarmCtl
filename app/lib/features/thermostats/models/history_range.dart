enum ThermostatHistoryRange { hour, day, week, month, year, all }

extension ThermostatHistoryRangeX on ThermostatHistoryRange {
  Duration? get window {
    switch (this) {
      case ThermostatHistoryRange.hour:
        return const Duration(hours: 1);
      case ThermostatHistoryRange.day:
        return const Duration(days: 1);
      case ThermostatHistoryRange.week:
        return const Duration(days: 7);
      case ThermostatHistoryRange.month:
        return const Duration(days: 30);
      case ThermostatHistoryRange.year:
        return const Duration(days: 365);
      case ThermostatHistoryRange.all:
        return null;
    }
  }

  String get label {
    switch (this) {
      case ThermostatHistoryRange.hour:
        return '1H';
      case ThermostatHistoryRange.day:
        return '24H';
      case ThermostatHistoryRange.week:
        return '7D';
      case ThermostatHistoryRange.month:
        return '30D';
      case ThermostatHistoryRange.year:
        return '1Y';
      case ThermostatHistoryRange.all:
        return 'All';
    }
  }
}
