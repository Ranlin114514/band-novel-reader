package com.ritualcollapse.wristnovel

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME = "com.ritualcollapse.wristnovel/notifications"
        private const val REQUEST_POST_NOTIFICATIONS = 6107

        private val wearableManagerPackages = mapOf(
            "xiaomi" to listOf(
                "com.xiaomi.wearable",
                "com.xiaomi.hm.health",
            ),
            "huawei" to listOf("com.huawei.health"),
            "honor" to listOf("com.hihonor.health"),
            "oppo" to listOf(
                "com.heytap.health.international",
                "com.heytap.health",
            ),
            "vivo" to listOf(
                "com.vivo.exhealth",
                "com.vivo.health",
            ),
        )
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
            "openBatteryOptimizationSettings" -> openBatteryOptimizationSettings(result)
            "openHuaweiAppLaunchSettings" -> openHuaweiAppLaunchSettings(result)
            "launchWearableManager" -> launchWearableManager(call, result)
            "openDownloadedApk" -> openDownloadedApk(call, result)
            else -> result.notImplemented()
        }
    }

    private fun openBatteryOptimizationSettings(result: MethodChannel.Result) {
        try {
            val directIntent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(directIntent)
            result.success(true)
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                result.success(true)
            } catch (error: Exception) {
                result.error("battery_settings_unavailable", "无法打开电池优化设置：${error.message}", null)
            }
        }
    }

    private fun openHuaweiAppLaunchSettings(result: MethodChannel.Result) {
        val candidates = listOf(
            Intent().setClassName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            ),
            Intent("huawei.intent.action.HSM_PROTECTED_APPS"),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
            },
        )
        for (intent in candidates) {
            try {
                startActivity(intent)
                result.success(true)
                return
            } catch (_: Exception) {
                // Try the next Huawei/system setting entry point.
            }
        }
        result.error("huawei_launch_settings_unavailable", "无法打开华为应用启动管理，请在设置中搜索“应用启动管理”。", null)
    }

    private fun launchWearableManager(call: MethodCall, result: MethodChannel.Result) {
        val brand = call.argument<String>("brand")?.lowercase()
        val candidates = wearableManagerPackages[brand]
        if (candidates == null) {
            result.error("unsupported_wearable_brand", "不支持的手环品牌。", null)
            return
        }

        for (packageId in candidates) {
            val launchIntent = packageManager.getLaunchIntentForPackage(packageId)
            if (launchIntent != null) {
                startActivity(launchIntent)
                result.success(mapOf("status" to "launched", "packageId" to packageId))
                return
            }
        }

        val preferredPackage = candidates.first()
        val storeIntent = Intent(
            Intent.ACTION_VIEW,
            Uri.parse("market://details?id=$preferredPackage"),
        )
        try {
            startActivity(storeIntent)
            result.success(mapOf("status" to "store", "packageId" to preferredPackage))
        } catch (_: Exception) {
            val webStoreIntent = Intent(
                Intent.ACTION_VIEW,
                Uri.parse("https://play.google.com/store/apps/details?id=$preferredPackage"),
            )
            try {
                startActivity(webStoreIntent)
                result.success(mapOf("status" to "store", "packageId" to preferredPackage))
            } catch (error: Exception) {
                result.error(
                    "wearable_manager_unavailable",
                    "未找到对应的手环管理软件，也无法打开应用商店：${error.message}",
                    null,
                )
            }
        }
    }

    private fun openDownloadedApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("missing_update_path", "未找到已下载的更新包。", null)
            return
        }
        val apk = File(path)
        if (!apk.exists() || !apk.isFile || apk.length() <= 0L) {
            result.error("invalid_update_file", "更新包文件不存在或为空。", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    ),
                )
                result.success(mapOf("status" to "permission_required"))
            } catch (error: Exception) {
                result.error("install_permission_settings_unavailable", "无法打开“允许安装未知应用”设置：${error.message}", null)
            }
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(mapOf("status" to "installer_opened"))
        } catch (error: Exception) {
            result.error("installer_unavailable", "无法打开系统安装界面：${error.message}", null)
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
