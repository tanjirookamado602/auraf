package com.auraf.benchmark

import com.auraf.telemetry.StateCollectorPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // AURAF State Collector channel (com.auraf/state_collector).
        flutterEngine.plugins.add(StateCollectorPlugin())
    }
}
