package com.example.farmctl

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

// flutter_foreground_task also auto-restarts the monitoring service on boot
// (ForegroundTaskOptions.autoRunOnBoot) via its own native receiver, and posts
// its own persistent notification once it does — this receiver is a second,
// independent path that additionally re-registers the WorkManager watchdog.
// A redundant start attempt from either path is a harmless no-op.
class BootCompletedReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent?) {
    val action = intent?.action ?: return
    if (action != Intent.ACTION_BOOT_COMPLETED &&
        action != Intent.ACTION_MY_PACKAGE_REPLACED) {
      return
    }

    try {
      val loader = FlutterInjector.instance().flutterLoader()
      loader.startInitialization(context)
      loader.ensureInitializationComplete(context, null)
      val appBundlePath = loader.findAppBundlePath()
      val engine = FlutterEngine(context)
      val entrypoint = DartExecutor.DartEntrypoint(appBundlePath, "initializeMonitoringOnBoot")
      engine.dartExecutor.executeDartEntrypoint(entrypoint)
    } catch (_: Throwable) {
      // Best-effort; flutter_foreground_task's own autoRunOnBoot should still
      // restore the service.
    }
  }
}


