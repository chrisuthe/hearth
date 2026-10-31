package com.hearth.hearth

import android.content.Intent
import android.os.Bundle
import com.hearth.hearth.apps.AppSessionService
import com.hearth.hearth.apps.AppsChannel
import com.hearth.hearth.capture.CaptureChannel
import com.hearth.hearth.capture.ScreenCaptureService
import com.hearth.hearth.sendspin.SendspinChannel
import com.hearth.hearth.voice.HearthAudioService
import com.hearth.hearth.voice.VoiceChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var voice: VoiceChannel? = null
    private var sendspin: SendspinChannel? = null
    private var appUpdate: AppUpdateChannel? = null
    private var capture: CaptureChannel? = null
    private var wifi: WifiChannel? = null
    private var apps: AppsChannel? = null
    private var sounds: SoundsChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        live++
        super.onCreate(savedInstanceState)
    }

    override fun onDestroy() {
        super.onDestroy()
        live--
    }

    override fun onStart() {
        super.onStart()
        started++
        AppSessionService.onHearthVisibilityChanged()
    }

    override fun onStop() {
        started--
        AppSessionService.onHearthVisibilityChanged()
        super.onStop()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        voice = VoiceChannel(this, messenger)
        sendspin = SendspinChannel(this, messenger)
        appUpdate = AppUpdateChannel(this, messenger)
        capture = CaptureChannel(this, messenger)
        wifi = WifiChannel(this, messenger)
        apps = AppsChannel(this, messenger)
        sounds = SoundsChannel(this, messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        voice?.dispose()
        voice = null
        sendspin?.dispose()
        sendspin = null
        appUpdate?.dispose()
        appUpdate = null
        capture?.dispose()
        capture = null
        wifi?.dispose()
        wifi = null
        apps?.dispose()
        apps = null
        sounds?.dispose()
        sounds = null
        // Dart owns the satellite and Sendspin; without it nothing could
        // configure, mute or stop them. A newer instance (a relaunch with
        // CLEAR_TASK) already owns them.
        if (isFinishing && live == 1) {
            stopService(Intent(this, HearthAudioService::class.java))
            // Consent lasts one session; the next launch asks again.
            stopService(Intent(this, ScreenCaptureService::class.java))
            // Nothing left to keep alive, nothing to come back to.
            stopService(Intent(this, AppSessionService::class.java))
        }
        super.cleanUpFlutterEngine(flutterEngine)
    }

    @Deprecated("FlutterActivity still routes results through here")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (capture?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        voice?.onRequestPermissionsResult(requestCode)
    }

    companion object {
        /** Instances between onStart and onStop. Main thread. */
        private var started = 0

        /**
         * Hearth is on screen: full screen, in a split half (focused or not),
         * or under a translucent dialog it opened. Main thread.
         */
        val visible: Boolean
            get() = started > 0

        /** Instances between onCreate and onDestroy, for the service stop. */
        private var live = 0
    }
}
