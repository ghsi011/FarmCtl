import 'package:flutter/services.dart';

/// Bridge to the Android lock-screen handling for the full-screen alarm
/// (see `MainActivity.kt`).
///
/// When an alarm notification launches the app, the activity latches
/// `setShowWhenLocked`/`setTurnScreenOn` so the alarm page can appear over the
/// keyguard. Those flags must be dropped once the alarm has been dealt with —
/// otherwise the whole app stays showable over the lock screen (and activity
/// recreation would re-apply the flags from the persisted launch intent).
class AlarmScreenChannel {
  AlarmScreenChannel({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('com.example.farmctl/alarm_screen');

  final MethodChannel _channel;

  /// Clears the show-when-locked/turn-screen-on flags and neutralizes the
  /// alarm launch intent. Best-effort: failures are swallowed because the
  /// channel only exists on Android (not in tests or on other platforms) and
  /// the flags are also cleared on the next non-alarm launch.
  Future<void> clearLockScreenFlags() async {
    try {
      await _channel.invokeMethod<void>('clearAlarmLockScreenFlags');
    } on MissingPluginException {
      // Not running on Android (tests, desktop) — nothing to clear.
    } on PlatformException {
      // Best-effort: the native side also clears on the next normal launch.
    }
  }
}
