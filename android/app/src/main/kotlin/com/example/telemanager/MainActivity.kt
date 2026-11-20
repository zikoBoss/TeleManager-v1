package com.example.telemanager

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Task 05: register the native TDLib bridge (MethodChannel
        // "telemanager.tdlib"). The bridge lives in
        // android/native/tdlib_bridge/ (see build.gradle.kts sourceSets).
        flutterEngine.plugins.add(TdlibBridge())
    }
}
