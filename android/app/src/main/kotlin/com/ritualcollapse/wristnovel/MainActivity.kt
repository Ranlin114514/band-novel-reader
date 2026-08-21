package com.ritualcollapse.wristnovel

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME = "com.ritualcollapse.wristnovel/notifications"
        private const val REQUEST_POST_NOTIFICATIONS = 6107
    }

    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result -> handleNotificationMethod(call, result) }
    }

    private fun handleNotificationMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermission" -> requestNotificationPermission(result)
            "areNotificationsEnabled" -> result.success(areNotificationsEnabled())
            "openNotificationSettings" -> {
                val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                    putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                }
                startActivity(intent)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(areNotificationsEnabled())
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.error("permission_request_in_progress", "通知权限请求正在进行。", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_POST_NOTIFICATIONS,
        )
    }

    private fun areNotificationsEnabled(): Boolean =
        NotificationManagerCompat.from(this).areNotificationsEnabled()

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_POST_NOTIFICATIONS) {
            return
        }
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(granted)
        pendingPermissionResult = null
    }
}
