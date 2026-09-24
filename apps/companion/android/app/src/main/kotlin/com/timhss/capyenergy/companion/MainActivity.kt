package com.timhss.capyenergy.companion

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import com.google.firebase.appdistribution.FirebaseAppDistribution
import com.google.firebase.appdistribution.InterruptionLevel
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        applyThemeWindowBackground()
        super.onCreate(savedInstanceState)
    }

    override fun onResume() {
        super.onResume()
        applyThemeWindowBackground()
        try {
            FirebaseAppDistribution.getInstance().showFeedbackNotification(
                "Tire um print ou toque aqui para enviar feedback",
                InterruptionLevel.HIGH
            )
        } catch (_: Exception) {
            // Ignored when running outside Firebase App Distribution tester context
        }
    }

    private fun applyThemeWindowBackground() {
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val colorHex = prefs.getString("flutter.launch_bg_color", null)
            if (colorHex != null) {
                val color = Color.parseColor(colorHex)
                window.setBackgroundDrawable(ColorDrawable(color))
                window.decorView.setBackgroundColor(color)
            }
        } catch (_: Exception) {
            // Ignored when prefs are unavailable or parsing fails
        }
    }
}
