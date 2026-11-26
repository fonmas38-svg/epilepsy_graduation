package com.epilepsy.monitor.epilepsy_monitor

import android.app.NotificationManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "neuroshield/background"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        applyLockScreenPolicy(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        applyLockScreenPolicy(intent)
    }

    /**
     * Only a seizure-alert notification (payload `alert:<id>`, sent on the
     * full-screen channel) may show the app over the lock screen. Any other
     * launch keeps the normal keyguard, so patient data is never exposed on a
     * locked phone just because the app was open.
     */
    private fun applyLockScreenPolicy(intent: Intent?) {
        val payload = intent?.getStringExtra("payload")
        val isAlert = intent?.action == "SELECT_NOTIFICATION" &&
            payload?.startsWith("alert:") == true
        setOverLockScreen(isAlert)
    }

    private fun setOverLockScreen(enabled: Boolean) {
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(enabled)
            setTurnScreenOn(enabled)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "startMonitoringService" -> {
                            val i = Intent(this, MonitoringForegroundService::class.java)
                                .putExtra(
                                    MonitoringForegroundService.EXTRA_TITLE,
                                    call.argument<String>("title"),
                                )
                                .putExtra(
                                    MonitoringForegroundService.EXTRA_TEXT,
                                    call.argument<String>("text"),
                                )
                            if (Build.VERSION.SDK_INT >= 26) {
                                startForegroundService(i)
                            } else {
                                startService(i)
                            }
                            result.success(true)
                        }
                        "stopMonitoringService" -> {
                            // stopService (not startService(ACTION_STOP)): Android 8+
                            // refuses startService from the background, which would
                            // leave a notification claiming monitoring still runs.
                            stopService(Intent(this, MonitoringForegroundService::class.java))
                            result.success(true)
                        }
                        "isIgnoringBatteryOptimizations" -> {
                            val pm = getSystemService(PowerManager::class.java)
                            result.success(
                                Build.VERSION.SDK_INT < 23 ||
                                    pm?.isIgnoringBatteryOptimizations(packageName) == true,
                            )
                        }
                        "requestIgnoreBatteryOptimizations" -> {
                            result.success(requestBatteryExemption())
                        }
                        "canUseFullScreenIntent" -> {
                            val nm = getSystemService(NotificationManager::class.java)
                            result.success(
                                Build.VERSION.SDK_INT < 34 ||
                                    nm?.canUseFullScreenIntent() == true,
                            )
                        }
                        "openFullScreenIntentSettings" -> {
                            if (Build.VERSION.SDK_INT >= 34) {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                                        Uri.parse("package:$packageName"),
                                    ),
                                )
                                result.success(true)
                            } else {
                                result.success(false)
                            }
                        }
                        "releaseLockScreen" -> {
                            setOverLockScreen(false)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("background_error", e.message, null)
                }
            }
    }

    /** Direct system prompt; falls back to the general list if unavailable. */
    private fun requestBatteryExemption(): Boolean {
        if (Build.VERSION.SDK_INT < 23) return true
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                ),
            )
            true
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                true
            } catch (_: Exception) {
                false
            }
        }
    }
}
