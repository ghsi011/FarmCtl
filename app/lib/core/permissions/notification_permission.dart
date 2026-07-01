import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

/// Requests the `POST_NOTIFICATIONS` runtime permission (Android 13+ / API 33+).
///
/// Without it the OS silently suppresses **both** the ongoing foreground-service
/// "monitoring" notification and every out-of-range alarm notification — so the
/// app's core safety alert would never reach the user on a fresh install where
/// the permission defaults to denied. The single OS permission covers both the
/// flutter_foreground_task and flutter_local_notifications channels.
///
/// Safe to call more than once: it only prompts when the permission is still
/// undecided, and no-ops on non-Android platforms.
Future<void> ensureNotificationPermission() async {
  if (kIsWeb || !Platform.isAndroid) {
    return;
  }
  try {
    final status = await Permission.notification.status;
    // Already decided (granted, or permanently denied where a request would be
    // a no-op the OS won't re-surface): nothing to prompt for.
    if (status.isGranted || status.isPermanentlyDenied) {
      return;
    }
    await Permission.notification.request();
  } catch (error, stackTrace) {
    debugPrint('Failed to request notification permission: $error');
    debugPrint('$stackTrace');
  }
}

/// App-level view of the `POST_NOTIFICATIONS` permission.
///
/// [denied] covers both the plain and the permanently denied OS states: in
/// either one every alarm notification is silently suppressed, so the UI
/// treats them identically ("alarms are blocked, fix it in system settings").
enum AlarmNotificationPermission { granted, denied, unknown }

/// Thin, injectable seam over permission_handler (mirrors how [SoundPicker]
/// wraps its platform channel) so widgets and providers never talk to the
/// plugin directly and tests can fake every platform interaction.
class NotificationPermissionChecker {
  NotificationPermissionChecker({
    @visibleForTesting Future<PermissionStatus> Function()? readStatus,
    @visibleForTesting Future<bool> Function()? openSettings,
    @visibleForTesting bool? isAndroid,
  }) : _readStatus = readStatus ?? (() => Permission.notification.status),
       _openSettings = openSettings ?? openAppSettings,
       _isAndroid = isAndroid ?? (!kIsWeb && Platform.isAndroid);

  final Future<PermissionStatus> Function() _readStatus;
  final Future<bool> Function() _openSettings;
  final bool _isAndroid;

  /// Current permission state. Non-Android platforms have no
  /// `POST_NOTIFICATIONS` runtime permission, so they always report granted.
  Future<AlarmNotificationPermission> status() async {
    if (!_isAndroid) {
      return AlarmNotificationPermission.granted;
    }
    try {
      final status = await _readStatus();
      if (status.isGranted || status.isLimited || status.isProvisional) {
        return AlarmNotificationPermission.granted;
      }
      if (status.isDenied ||
          status.isPermanentlyDenied ||
          status.isRestricted) {
        return AlarmNotificationPermission.denied;
      }
      return AlarmNotificationPermission.unknown;
    } catch (error, stackTrace) {
      debugPrint('Failed to read notification permission: $error');
      debugPrint('$stackTrace');
      return AlarmNotificationPermission.unknown;
    }
  }

  /// Opens the OS app-settings screen where the user can re-enable
  /// notifications (a denied permission cannot be re-requested in-app).
  Future<bool> openSettings() => _openSettings();
}

final notificationPermissionCheckerProvider =
    Provider<NotificationPermissionChecker>(
      (ref) => NotificationPermissionChecker(),
    );

/// Current notification-permission state, re-read every time the app returns
/// to the foreground so a revocation made in system settings while the app was
/// backgrounded is picked up without a restart (same resume-driven refresh
/// idea as [ForegroundRefresher]).
final notificationPermissionStatusProvider =
    FutureProvider<AlarmNotificationPermission>((ref) {
      final lifecycleListener = AppLifecycleListener(
        onResume: ref.invalidateSelf,
      );
      ref.onDispose(lifecycleListener.dispose);
      return ref.watch(notificationPermissionCheckerProvider).status();
    });
