package com.example.farmctl

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.media.RingtoneManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  companion object {
    private const val CHANNEL = "com.example.farmctl/sound_picker"
    private const val REQUEST_CODE_PICK_SOUND = 0xFA10
    private const val TAG = "SoundPicker"
  }

  private var pendingResult: MethodChannel.Result? = null

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

  private fun handleReleasePermission(uriValue: String?, result: MethodChannel.Result) {
    if (uriValue.isNullOrBlank()) {
      result.success(null)
      return
    }

    try {
      val uri = Uri.parse(uriValue)
      contentResolver.releasePersistableUriPermission(
        uri,
        Intent.FLAG_GRANT_READ_URI_PERMISSION
      )
    } catch (error: SecurityException) {
      Log.w(TAG, "Failed to release persisted permission for $uriValue", error)
    } catch (error: IllegalArgumentException) {
      Log.w(TAG, "Invalid URI when releasing permission: $uriValue", error)
    }

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
    val uri: Uri? = if (Build.VERSION.SDK_INT >= 33) {
      data.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI, Uri::class.java)
    } else {
      @Suppress("DEPRECATION")
      data.getParcelableExtra(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
    }
    if (uri == null) {
      result.success(null)
      return
    }

    // Attempt to persist read permission if granted via the picker
    val takeFlags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION)
    if (takeFlags != 0) {
      try {
        contentResolver.takePersistableUriPermission(
          uri,
          takeFlags
        )
      } catch (error: SecurityException) {
        Log.w(TAG, "Unable to persist permission for selected URI $uri", error)
      }
    }

    result.success(mapOf("uri" to uri.toString()))
  }
}
