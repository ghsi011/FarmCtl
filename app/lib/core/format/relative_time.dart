/// Formats a duration as a relative "… ago" phrase for last-seen timestamps.
String formatRelativeDuration(Duration difference) {
  final seconds = difference.inSeconds.abs();
  if (seconds < 60) {
    return 'just now';
  }
  final minutes = difference.inMinutes;
  if (minutes.abs() < 60) {
    final value = minutes.abs();
    final unit = value == 1 ? 'min' : 'mins';
    return '$value $unit ago';
  }
  final hours = difference.inHours;
  if (hours.abs() < 24) {
    final value = hours.abs();
    final unit = value == 1 ? 'hour' : 'hours';
    return '$value $unit ago';
  }
  final days = difference.inDays;
  final unit = days.abs() == 1 ? 'day' : 'days';
  return '${days.abs()} $unit ago';
}

/// Formats a duration as an elapsed span ("2 hours 14 min") without the "ago"
/// suffix — used to convey how long an alarm condition has persisted.
String formatElapsed(Duration duration) {
  final totalSeconds = duration.inSeconds.abs();
  if (totalSeconds < 60) {
    return 'less than a minute';
  }
  final totalMinutes = duration.inMinutes.abs();
  if (totalMinutes < 60) {
    return '$totalMinutes ${totalMinutes == 1 ? 'minute' : 'minutes'}';
  }
  final totalHours = duration.inHours.abs();
  if (totalHours < 24) {
    final mins = totalMinutes - totalHours * 60;
    final hourPart = '$totalHours ${totalHours == 1 ? 'hour' : 'hours'}';
    return mins == 0 ? hourPart : '$hourPart $mins min';
  }
  final totalDays = duration.inDays.abs();
  final hours = totalHours - totalDays * 24;
  final dayPart = '$totalDays ${totalDays == 1 ? 'day' : 'days'}';
  return hours == 0 ? dayPart : '$dayPart $hours h';
}
