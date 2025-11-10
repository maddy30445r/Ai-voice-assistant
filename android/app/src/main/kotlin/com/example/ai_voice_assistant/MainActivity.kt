package com.example.ai_voice_assistant

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri

class MainActivity: FlutterActivity() {
    private val CHANNEL = "app_launcher"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
            call, result ->
            if (call.method == "openApp") {
                val packageName = call.argument<String>("package")
                if (packageName != null) {
                    openApp(packageName, result)
                } else {
                    result.error("INVALID_PACKAGE", "Package name required", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun openApp(packageName: String, result: MethodChannel.Result) {
        val pm: PackageManager = context.packageManager
        val launchIntent: Intent? = pm.getLaunchIntentForPackage(packageName)

        if (launchIntent != null) {
            context.startActivity(launchIntent)
            result.success(null)
        } else {
            // Fallback → open Play Store
            val playStoreIntent = Intent(Intent.ACTION_VIEW,
                Uri.parse("https://play.google.com/store/apps/details?id=$packageName"))
            context.startActivity(playStoreIntent)
            result.success(null)
        }
    }
}