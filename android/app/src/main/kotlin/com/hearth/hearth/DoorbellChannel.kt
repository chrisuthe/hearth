package com.hearth.hearth

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import com.hearth.hearth.apps.AppSessionService
import com.hearth.hearth.voice.HearthAudioService
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Host side of `com.hearth/doorbell`, for the doorbell call view.
 *
 * `begin` and `end` bracket an open call: the voice satellite stops
 * capturing, Sendspin is muted and the screen stays on. `summon` turns the
 * screen on for a ring and brings Hearth forward, or posts a notification
 * when it can't come forward. Main thread, as every channel call is.
 */
class DoorbellChannel(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.hearth/doorbell")
    private var active = false

    init {
        channel.setMethodCallHandler(this)
    }

    /** The engine is going: a call it opened must not keep the satellite paused. */
    fun dispose() {
        channel.setMethodCallHandler(null)
        end()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "begin" -> {
                begin()
                result.success(null)
            }
            "end" -> {
                end()
                result.success(null)
            }
            "summon" -> {
                summon(call.argument<String>("title").orEmpty())
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun begin() {
        Log.i(TAG, "Call hold taken: satellite capture paused, Sendspin muted, screen kept on")
        active = true
        HearthAudioService.setCallActive(true)
        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun end() {
        if (!active) return
        Log.i(TAG, "Call hold released")
        active = false
        HearthAudioService.setCallActive(false)
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun summon(title: String) {
        wakeScreen()
        if (MainActivity.visible) return
        if (Settings.canDrawOverlays(activity)) {
            activity.startActivity(AppSessionService.frontIntent(activity))
        } else {
            Log.w(TAG, "Hearth can't come forward: overlay permission not granted")
            notifyRing(title)
        }
    }

    /**
     * Lights the screen if it timed out. The window flags turn it on when the
     * activity next shows; the wake lock is what turns it on while the
     * activity is stopped behind a dark screen.
     */
    private fun wakeScreen() {
        activity.setTurnScreenOn(true)
        activity.setShowWhenLocked(true)
        val power = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (power.isInteractive) return
        @Suppress("DEPRECATION")
        power.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            "Hearth::DoorbellWake",
        ).acquire(WAKE_MS)
    }

    private fun notifyRing(title: String) {
        val manager = activity.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Doorbell", NotificationManager.IMPORTANCE_HIGH),
        )
        val open = PendingIntent.getActivity(
            activity,
            0,
            AppSessionService.frontIntent(activity),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(activity, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_voice_satellite)
            .setContentTitle(title.ifEmpty { "Doorbell" })
            .setCategory(Notification.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        // Without POST_NOTIFICATIONS this is dropped, and the card still shows.
        runCatching { manager.notify(NOTIFICATION_ID, notification) }
            .onFailure { Log.w(TAG, "Ring notification failed: ${it.message}") }
    }

    private companion object {
        const val TAG = "DoorbellChannel"
        const val CHANNEL_ID = "doorbell"
        const val NOTIFICATION_ID = 315
        const val WAKE_MS = 10_000L
    }
}
