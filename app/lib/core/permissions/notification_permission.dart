import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
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
