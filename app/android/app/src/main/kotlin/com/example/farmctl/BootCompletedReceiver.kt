package com.example.farmctl

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

class BootCompletedReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent?) {
    val action = intent?.action ?: return
    if (action != Intent.ACTION_BOOT_COMPLETED &&
        action != Intent.ACTION_MY_PACKAGE_REPLACED) {
      return
    }

    val channelId = "farmctl_monitoring"
    val channelName = "Thermostat monitoring"
    val channelDescription =
      "Shows when FarmCtl is checking thermostats in the background."

    val manager =
      context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val channel = NotificationChannel(
        channelId,
        channelName,
        NotificationManager.IMPORTANCE_LOW,
      )
      channel.description = channelDescription
      manager.createNotificationChannel(channel)
    }

    val notification = NotificationCompat.Builder(context, channelId)
      .setSmallIcon(context.applicationInfo.icon)
      .setContentTitle("FarmCtl monitoring")
      .setContentText("Monitoring active")
      .setOngoing(true)
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .setCategory(NotificationCompat.CATEGORY_SERVICE)
      .setAutoCancel(false)
      .build()

    // Re-post the persistent monitoring notification after boot/update
    manager.notify(1001, notification)

    // Also restore WorkManager/Alarm schedule by invoking the Dart entrypoint.
    try {
      val loader = FlutterInjector.instance().flutterLoader()
      loader.startInitialization(context)
      loader.ensureInitializationComplete(context, null)
      val appBundlePath = loader.findAppBundlePath()
      val engine = FlutterEngine(context)
      val entrypoint = DartExecutor.DartEntrypoint(appBundlePath, "initializeMonitoringOnBoot")
      engine.dartExecutor.executeDartEntrypoint(entrypoint)
    } catch (_: Throwable) {
      // Best-effort; WorkManager should still restore its periodic task.
    }
  }
}


