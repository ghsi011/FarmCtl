package com.example.farmctl

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  companion object {
    private const val CHANNEL = "com.example.farmctl/sound_picker"
    private const val ALARM_SCREEN_CHANNEL = "com.example.farmctl/alarm_screen"
    private const val REQUEST_CODE_PICK_SOUND = 0xFA10
    private const val TAG = "SoundPicker"

    // Action set by flutter_local_notifications on the launch intent it uses
    // for both the notification's fullScreenIntent and body taps. The only
    // notifications this app posts through that plugin are thermostat alarms,
    // so this action reliably identifies an alarm launch.
    private const val ALARM_NOTIFICATION_ACTION = "SELECT_NOTIFICATION"
  }

  private var pendingResult: MethodChannel.Result? = null

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    applyAlarmLockScreenFlags(intent)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    applyAlarmLockScreenFlags(intent)
  }

  /**
   * Shows this activity over the keyguard and turns the screen on, but only
   * when the activity was launched by an alarm notification (its full-screen
   * intent firing on a locked device, or the user tapping it). For every other
   * launch the flags are cleared, so the app is never exposed over the lock
   * screen during normal use.
   */
  @Suppress("DEPRECATION")
  private fun applyAlarmLockScreenFlags(intent: Intent?) {
    // A relaunch from recents after process death redelivers the original
    // alarm intent with FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY set; treat it as
    // a normal launch so an already-handled alarm cannot re-expose the app
    // over the lock screen. This mirrors flutter_local_notifications' own
    // launchedActivityFromHistory filter, keeping Kotlin and Dart aligned.
    // PendingIntent-driven alarm launches (full-screen intent, notification
    // tap) never carry this flag.
    val isAlarmLaunch = intent?.action == ALARM_NOTIFICATION_ACTION &&
      (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) == 0
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
      setShowWhenLocked(isAlarmLaunch)
      setTurnScreenOn(isAlarmLaunch)
    } else {
      // API 26: setShowWhenLocked/setTurnScreenOn require O_MR1 (27), so fall
      // back to the window flags they replaced.
      val lockScreenFlags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
        WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
      if (isAlarmLaunch) {
        window.addFlags(lockScreenFlags)
      } else {
        window.clearFlags(lockScreenFlags)
      }
    }
  }

  /**
   * Drops the lock-screen exposure once the alarm has been dealt with. Called
   * over [ALARM_SCREEN_CHANNEL] when the Flutter alarm page is dismissed
   * (acknowledged, snoozed, or silenced). Deliberately NOT called from
   * onPause/onStop — those fire when the keyguard engages, which would defeat
   * the full-screen alarm itself.
   */
  @Suppress("DEPRECATION")
  private fun clearAlarmLockScreenFlags() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
      setShowWhenLocked(false)
      setTurnScreenOn(false)
    } else {
      window.clearFlags(
        WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
          WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
      )
    }
    // Neutralize the stored launch intent so in-process activity recreation
    // (a config change) does not re-apply the flags via onCreate for an alarm
    // that was already handled. History relaunches after process death are
    // covered by the FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY filter in
    // applyAlarmLockScreenFlags. Safe with respect to
    // flutter_local_notifications: getNotificationAppLaunchDetails() inspects
    // this intent's action, but the app queries it exactly once during startup
    // (handleNotificationLaunch in main.dart) — always before the alarm page
    // can be dismissed and this method invoked.
    intent?.takeIf { it.action == ALARM_NOTIFICATION_ACTION }?.let { launchIntent ->
      launchIntent.action = Intent.ACTION_MAIN
      setIntent(launchIntent)
    }
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "pickSound" -> handlePickSound(call.argument("initialUri"), result)
          "releasePersistablePermission" -> handleReleasePermission(call.argument("uri"), result)
          else -> result.notImplemented()
        }
      }
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ALARM_SCREEN_CHANNEL)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "clearAlarmLockScreenFlags" -> {
            clearAlarmLockScreenFlags()
            result.success(null)
          }
          else -> result.notImplemented()
        }
      }
  }

  private fun handlePickSound(initialUri: String?, result: MethodChannel.Result) {
    if (pendingResult != null) {
      result.error("ALREADY_ACTIVE", "A sound picker request is already active.", null)
      return
    }

    // Use the platform ringtone picker for alarm sounds, which matches the Clock app UI.
    val intent = Intent(RingtoneManager.ACTION_RINGTONE_PICKER).apply {
      putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, RingtoneManager.TYPE_ALARM)
      putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
      putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, false)
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      putExtra(RingtoneManager.EXTRA_RINGTONE_TITLE, "Alarm sound")
      if (!initialUri.isNullOrBlank()) {
        try {
          val uri = Uri.parse(initialUri)
          putExtra(RingtoneManager.EXTRA_RINGTONE_EXISTING_URI, uri)
        } catch (ex: IllegalArgumentException) {
          Log.w(TAG, "Ignoring invalid initial URI: $initialUri", ex)
        }
      }
    }

    pendingResult = result
    try {
      @Suppress("DEPRECATION")
      startActivityForResult(intent, REQUEST_CODE_PICK_SOUND)
    } catch (error: ActivityNotFoundException) {
      pendingResult = null
      result.error(
        "NO_PICKER",
        "No installed app can provide a ringtone picker.",
        error.localizedMessage
      )
    }
  }

  private fun handleReleasePermission(@Suppress("UNUSED_PARAMETER") uriValue: String?, result: MethodChannel.Result) {
    result.success(null)
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    super.onActivityResult(requestCode, resultCode, data)

    if (requestCode != REQUEST_CODE_PICK_SOUND) {
      return
    }

    val result = pendingResult ?: return
    pendingResult = null

    if (resultCode != Activity.RESULT_OK || data == null) {
      result.success(null)
      return
    }

    // Ringtone picker returns the selection in EXTRA_RINGTONE_PICKED_URI
    val pickedUri: Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      data.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI, Uri::class.java)
    } else {
      @Suppress("DEPRECATION")
      data.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
    }

    // If user chose Default, picker may return null; map to system default
    val finalUri: Uri = pickedUri
      ?: (RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
        ?: Settings.System.DEFAULT_ALARM_ALERT_URI)
        ?: run {
          result.success(null)
          return
        }

    // Attempt to persist read permission if granted via the picker
    val takeFlags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION)
    if (takeFlags != 0) {
      try {
        contentResolver.takePersistableUriPermission(
          finalUri,
          takeFlags
        )
      } catch (error: SecurityException) {
        Log.w(TAG, "Unable to persist permission for selected URI $finalUri", error)
      }
    }

    result.success(mapOf("uri" to finalUri.toString()))
  }
}
