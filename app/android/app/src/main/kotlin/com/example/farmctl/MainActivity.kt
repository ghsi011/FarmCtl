package com.example.farmctl

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
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

    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
      addCategory(Intent.CATEGORY_OPENABLE)
      type = "audio/*"
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
      if (!initialUri.isNullOrBlank()) {
        try {
          val uri = Uri.parse(initialUri)
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            putExtra(DocumentsContract.EXTRA_INITIAL_URI, uri)
          }
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
        "No installed app can provide an audio picker.",
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

    val uri = data.data
    if (uri == null) {
      result.success(null)
      return
    }

    val takeFlags = data.flags and
      (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    try {
      contentResolver.takePersistableUriPermission(
        uri,
        takeFlags or Intent.FLAG_GRANT_READ_URI_PERMISSION
      )
    } catch (error: SecurityException) {
      Log.w(TAG, "Unable to persist permission for selected URI $uri", error)
    }

    result.success(mapOf("uri" to uri.toString()))
  }
}
