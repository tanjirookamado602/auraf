package com.auraf.telemetry

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.abs

/**
 * State Collector channel (`com.auraf/state_collector`).
 *
 * Kept separate from AurafTelemetryPlugin so the two can evolve
 * independently. Host apps register it in MainActivity:
 *   flutterEngine.plugins.add(StateCollectorPlugin())
 */
class StateCollectorPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ctx = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "sampleState" -> result.success(StateCollectorSampler.sample(ctx))
                        "describeDevice" -> result.success(StateCollectorSampler.describeDevice())
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("TELEMETRY_ERROR", e.message, null)
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    companion object {
        const val CHANNEL = "com.auraf/state_collector"
    }
}

/**
 * Native half of the AURAF State Collector (M2, task 5).
 *
 * Unlike `readDeviceSensors`, this sampler never invents values: when a sensor
 * is not exposed by the device (common on emulators), it reports the matching
 * `*_available` flag as false so the Dart side can record that honestly.
 *
 * It is designed to be called at >= 10 Hz during a benchmark run, so it only
 * uses cheap reads (sticky battery intent, BatteryManager properties,
 * /proc/self/status) and avoids Debug.getPss(), which can take tens of ms.
 */
object StateCollectorSampler {

    fun sample(ctx: Context): Map<String, Any?> {
        val batteryIntent = ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val batteryManager = ctx.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager

        val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val batteryPercent = if (level >= 0 && scale > 0) level * 100 / scale else -1

        val status = batteryIntent?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val isCharging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        val tempTenths = batteryIntent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
            ?: Int.MIN_VALUE
        val voltageMv = batteryIntent?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1) ?: -1

        // CURRENT_NOW is specified in microamperes, but several OEMs report mA.
        // Values this large can only be uA; smaller ones are treated as mA.
        val rawCurrent = batteryManager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
            ?: Int.MIN_VALUE
        val currentAvailable = rawCurrent != Int.MIN_VALUE && rawCurrent != 0
        var currentMa = when {
            !currentAvailable -> 0.0
            abs(rawCurrent) > 10_000 -> rawCurrent / 1000.0
            else -> rawCurrent.toDouble()
        }
        // Shared contract: negative while discharging, positive while charging.
        currentMa = if (isCharging) abs(currentMa) else -abs(currentMa)

        val chargeCounter = batteryManager?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
            ?: Int.MIN_VALUE
        val chargeCounterAvailable = chargeCounter != Int.MIN_VALUE && chargeCounter > 0

        val activityManager = ctx.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val memoryInfo = ActivityManager.MemoryInfo()
        activityManager?.getMemoryInfo(memoryInfo)
        val proc = readProcStatusKb("VmRSS", "VmHWM")
        val rssMb = (proc["VmRSS"] ?: 0L) / 1024.0
        val peakRssMb = (proc["VmHWM"] ?: 0L) / 1024.0

        val thermalStatus = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            (ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager)?.currentThermalStatus ?: -1
        } else {
            -1
        }

        return mapOf(
            "timestamp" to System.currentTimeMillis(),
            "battery_level_percent" to batteryPercent,
            "battery_current_ma" to currentMa,
            "battery_current_available" to currentAvailable,
            "battery_voltage_mv" to voltageMv,
            "charge_counter_uah" to if (chargeCounterAvailable) chargeCounter else null,
            "is_charging" to isCharging,
            "temperature_celsius" to if (tempTenths == Int.MIN_VALUE) 0.0 else tempTenths / 10.0,
            "temperature_available" to (tempTenths != Int.MIN_VALUE),
            "thermal_status" to thermalStatus,
            "available_ram_mb" to memoryInfo.availMem / (1024.0 * 1024.0),
            "total_ram_mb" to memoryInfo.totalMem / (1024.0 * 1024.0),
            "low_memory" to memoryInfo.lowMemory,
            "rss_mb" to rssMb,
            "peak_memory_mb" to peakRssMb,
            "network_condition" to classifyNetwork(ctx),
        )
    }

    fun describeDevice(): Map<String, Any> {
        val manufacturer = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
        val model = "${manufacturer}_${Build.MODEL}_Android_${Build.VERSION.RELEASE}"
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
        val fingerprint = Build.FINGERPRINT.lowercase()
        val isEmulator = fingerprint.contains("generic") ||
            fingerprint.contains("emulator") ||
            Build.HARDWARE.contains("goldfish") ||
            Build.HARDWARE.contains("ranchu") ||
            Build.PRODUCT.contains("sdk")
        return mapOf(
            "device_model" to model,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "android_release" to Build.VERSION.RELEASE,
            "sdk_int" to Build.VERSION.SDK_INT,
            "hardware" to Build.HARDWARE,
            "cpu_cores" to Runtime.getRuntime().availableProcessors(),
            "is_emulator" to isEmulator,
        )
    }

    private fun classifyNetwork(ctx: Context): String {
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return "offline"
        val network = cm.activeNetwork ?: return "offline"
        val caps = cm.getNetworkCapabilities(network) ?: return "offline"
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return "offline"
        // Connected but Android could not validate internet reachability.
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return "intermittent"
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
            val downKbps = caps.linkDownstreamBandwidthKbps
            if (downKbps in 1..2000) return "high_latency"
        }
        return "stable"
    }

    private fun readProcStatusKb(vararg keys: String): Map<String, Long> {
        val out = HashMap<String, Long>()
        try {
            File("/proc/self/status").forEachLine { line ->
                for (key in keys) {
                    if (line.startsWith("$key:")) {
                        line.substringAfter(':').trim().split(Regex("\\s+")).firstOrNull()
                            ?.toLongOrNull()?.let { out[key] = it }
                    }
                }
            }
        } catch (_: Exception) {
            // /proc is always readable for our own process; keep the sampler total anyway.
        }
        return out
    }
}
