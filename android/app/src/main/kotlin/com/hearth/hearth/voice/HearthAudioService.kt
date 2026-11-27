package com.hearth.hearth.voice

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import com.example.ava.esphome.Connected
import com.example.ava.esphome.EspHomeDevice
import com.example.ava.esphome.EspHomeState
import com.example.ava.esphome.ServerError
import com.example.ava.esphome.voiceassistant.Listening
import com.example.ava.esphome.voiceassistant.Processing
import com.example.ava.esphome.voiceassistant.Responding
import com.example.ava.esphome.voiceassistant.VoiceError
import com.example.ava.nsd.NsdRegistration
import com.example.ava.nsd.registerVoiceSatelliteNsd
import com.hearth.hearth.MainActivity
import com.hearth.hearth.R
import com.hearth.hearth.sendspin.SendspinConfig
import com.hearth.hearth.sendspin.SendspinPlayer
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.plus
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import timber.log.Timber

/**
 * Hearth's background audio: the voice satellite (the ESPHome server Home
 * Assistant connects to, wake-word capture and voice output) and the
 * Sendspin player. Runs while either is wanted and stops when neither is.
 *
 * Dart drives each feature over its own channel, always while the activity
 * is visible, which Android 14+ requires for a microphone foreground
 * service: `start`/`stop` on `com.hearth/voice`, `configure` on
 * `com.hearth/sendspin`. Each request carries the feature's full
 * configuration and rebuilds that feature alone, so a settings change is
 * just another request and leaves the other feature playing.
 */
class HearthAudioService : LifecycleService() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private val lifecycleMutex = Mutex()
    private var device: EspHomeDevice? = null
    private var deviceJob: Job? = null
    private var settings: SatelliteSettings? = null
    private var nsd: NsdRegistration? = null
    private var ring: TimerRing? = null
    private val audio = AudioCoordinator()
    private var sendspin: SendspinPlayer? = null

    // What Dart last asked for. Updated on the main thread as each request
    // arrives, before the work it starts runs, so the last job to run sees
    // the final word on whether the service is still needed.
    private var wantedVoice: VoiceConfig? = null
    private var wantedSendspin: SendspinConfig? = null

    private var voiceStatus: String? = null
    private var sendspinStatus: String? = null
    private var lastStartId = 0

    /** The foreground types last granted, 0 before the first. */
    private var currentType = 0

    override fun onCreate() {
        super.onCreate()
        instance = this
        val debuggable = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        if (debuggable && Timber.forest().isEmpty()) Timber.plant(Timber.DebugTree())
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)
        lastStartId = startId
        // startForegroundService() obliges us to go foreground even on the
        // way out; apply() does so before anything else.
        apply(fromStart = true)
        // A restart without the activity could not open the microphone, and
        // the configuration lives in Dart. Hearth's next launch starts it.
        return START_NOT_STICKY
    }

    /** Takes the pending requests and brings each feature in line with them. Main thread. */
    private fun apply(fromStart: Boolean = false) {
        val voiceChange = pendingVoice
        val sendspinChange = pendingSendspin
        pendingVoice = null
        pendingSendspin = null
        voiceChange?.let { wantedVoice = it.config }
        sendspinChange?.let { wantedSendspin = it.config?.takeIf(SendspinConfig::active) }

        if (voiceChange?.config != null && !micGranted()) {
            VoiceEvents.health(VoiceEvents.PERMISSION_MISSING, "RECORD_AUDIO is not granted")
            wantedVoice = null
        }
        var rebuildVoice = voiceChange != null
        // Asked again only when the types change: a Sendspin change made while
        // Hearth is in the background must not risk the microphone type.
        if ((fromStart || foregroundType() != currentType) && !goForeground()) {
            if (wantedVoice != null) {
                wantedVoice = null
                rebuildVoice = true
            }
            // Media playback alone, which Sendspin needs and a start obliges.
            if (!goForeground()) wantedSendspin = null
        }

        lifecycleScope.launch {
            lifecycleMutex.withLock {
                if (rebuildVoice) {
                    tearDownVoice()
                    wantedVoice?.let(::bringUpVoice)
                }
                if (sendspinChange != null) {
                    sendspin?.close()
                    sendspin = null
                    sendspinStatus = null
                    wantedSendspin?.let(::startSendspin)
                }
                settle()
            }
        }
    }

    /**
     * Foreground with the types the wanted features need: media playback
     * always, the microphone only for voice, so Sendspin alone needs no
     * microphone permission. False if Android refused.
     */
    private fun goForeground(): Boolean {
        val voice = wantedVoice != null
        val type = foregroundType()
        return try {
            ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(), type)
            currentType = type
            true
        } catch (e: Exception) {
            Timber.e(e, "Foreground start refused")
            if (voice) {
                VoiceEvents.health(
                    VoiceEvents.MIC_OPEN_FAILED,
                    "Foreground service start refused: ${e.message}",
                )
            }
            false
        }
    }

    private fun foregroundType() = if (wantedVoice != null) {
        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
    } else {
        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
    }

    private fun micGranted() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED

    /** Under [lifecycleMutex]: the locks follow what runs, and the service stops when nothing is wanted. */
    private fun settle() {
        if (wantedVoice == null && wantedSendspin == null) {
            releaseLocks()
            shutDown()
            return
        }
        if (device != null || sendspin?.running == true) acquireLocks() else releaseLocks()
        updateNotification()
    }

    private fun startSendspin(config: SendspinConfig) {
        val version = runCatching { packageManager.getPackageInfo(packageName, 0).versionName }
            .getOrNull().orEmpty()
        sendspin = SendspinPlayer(this, config, version) { status ->
            sendspinStatus = status
            updateNotification()
        }.also {
            // A Sendspin started during a doorbell call starts muted.
            it.setCallMuted(callActive.value)
            it.start()
        }
    }

    /** The Sendspin player, for the channel. Null while Sendspin is off. */
    val sendspinPlayer: SendspinPlayer? get() = sendspin

    @SuppressLint("MissingPermission")
    private fun bringUpVoice(config: VoiceConfig) {
        val failed = CoroutineExceptionHandler { _, error -> onDeviceFailed(error) }
        val job = SupervisorJob(lifecycleScope.coroutineContext.job)
        val context = lifecycleScope.coroutineContext + job + failed
        val settings = SatelliteSettings(config)

        val device = SatelliteBuilder(this).build(context, config, settings, audio) { id, error ->
            Timber.e(error, "Wake word model failed to load: $id")
            VoiceEvents.health(VoiceEvents.MODEL_LOAD_FAILED, "$id: ${error.message}")
        }
        this.device = device
        this.deviceJob = job
        this.settings = settings
        val ring = TimerRing(device.voiceAssistant)
        this.ring = ring

        device.start()
        nsd = registerVoiceSatelliteNsd(this, config.nodeName, config.port, config.mac)

        combine(device.state, device.voiceAssistant.state, settings.muted) { server, voice, muted ->
            Triple(server, voice, muted)
        }.onEach { (server, voice, muted) -> report(server, voice, muted) }
            .launchIn(lifecycleScope + job)
        ring.watch().launchIn(lifecycleScope + job)
    }

    private fun report(server: EspHomeState, voice: EspHomeState, muted: Boolean) {
        // Outlives the device, so a rebuild keeps a mute made from Home Assistant.
        Companion.muted = muted
        if (server is ServerError) {
            // Nothing can connect, so do not keep the locks and the mDNS record.
            VoiceEvents.health(VoiceEvents.PORT_IN_USE, server.message)
            stopAfterFailure()
            return
        }
        val (state, connected) = when (voice) {
            is Connected -> "idle" to true
            is Listening -> "listening" to true
            is Processing -> "processing" to true
            is Responding -> "responding" to true
            is VoiceError -> "error" to true
            else -> "idle" to false
        }
        // Ava resets without unDuck when Home Assistant drops mid-exchange.
        if (!connected) audio.release()
        VoiceEvents.state(state, connected)
        voiceStatus = when {
            muted -> "Microphone muted"
            !connected -> "Waiting for Home Assistant"
            state == "idle" -> "Listening for the wake word"
            else -> state.replaceFirstChar(Char::uppercase)
        }
        updateNotification()
    }

    private fun onDeviceFailed(error: Throwable) {
        Timber.e(error, "Voice satellite failed")
        if (error is MicException) {
            VoiceEvents.health(VoiceEvents.MIC_OPEN_FAILED, error.message.orEmpty())
        }
        stopAfterFailure()
    }

    /** The satellite failed: stop it, and the service too unless Sendspin is playing. */
    private fun stopAfterFailure() {
        wantedVoice = null
        lifecycleScope.launch {
            lifecycleMutex.withLock {
                tearDownVoice()
                // Drop the microphone type.
                if (wantedSendspin != null && !goForeground()) wantedSendspin = null
                settle()
            }
        }
    }

    private fun tearDownVoice() {
        nsd?.unregister(this)
        nsd = null
        deviceJob?.cancel()
        deviceJob = null
        device?.close()
        device = null
        settings = null
        ring?.release()
        ring = null
        // A closed device never calls unDuck.
        audio.release()
        voiceStatus = null
    }

    /**
     * Stops unless a start arrived after the one being answered. New
     * requests then start the service afresh rather than reach this one.
     */
    private fun shutDown() {
        if (!stopSelfResult(lastStartId)) return
        if (instance === this) instance = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    }

    private fun applyMuted(muted: Boolean) {
        settings?.muted?.value = muted
    }

    fun wake() {
        device?.voiceAssistant?.wakeAssistant()
    }

    /** Rings for a local Hearth timer. False when there is no device to ring. */
    fun startTimerRing(): Boolean {
        val ring = ring ?: return false
        lifecycleScope.launch { ring.start() }
        return true
    }

    fun stopTimerRing() {
        ring?.stop()
    }

    override fun onDestroy() {
        tearDownVoice()
        sendspin?.closeNow()
        sendspin = null
        releaseLocks()
        VoiceEvents.state("idle", connected = false, running = false)
        if (instance === this) instance = null
        super.onDestroy()
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireLocks() {
        if (wakeLock != null) return
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$TAG::WakeLock")
            .apply { acquire() }
        // HIGH_PERF keeps Wi-Fi up with the screen off; from API 34 only
        // LOW_LATENCY is offered.
        @Suppress("DEPRECATION")
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
            WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        wifiLock = wifi.createWifiLock(mode, "$TAG::WifiLock").apply { acquire() }
    }

    private fun releaseLocks() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        wifiLock?.takeIf { it.isHeld }?.release()
        wifiLock = null
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Hearth audio",
            NotificationManager.IMPORTANCE_LOW,
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun notification(): Notification {
        val text = listOfNotNull(voiceStatus, sendspinStatus).joinToString(" · ").ifEmpty { "Starting" }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setOngoing(true)
            .setSmallIcon(R.drawable.ic_voice_satellite)
            .setContentTitle("Hearth audio")
            .setContentText(text)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(open)
            .build()
    }

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification())
    }

    companion object {
        private const val TAG = "HearthAudioService"
        private const val CHANNEL_ID = "voice_satellite"
        private const val NOTIFICATION_ID = 1

        /** The running service, for calls from the channel in the same process. */
        @Volatile
        var instance: HearthAudioService? = null
            private set

        /**
         * The microphone mute, whoever set it last: Dart or the Home Assistant
         * switch. Kept for the life of the process so each start applies it.
         */
        @Volatile
        var muted = false
            private set

        fun setMuted(muted: Boolean) {
            this.muted = muted
            instance?.applyMuted(muted)
        }

        /**
         * A doorbell call is open. The satellite stops capturing (see
         * [SatelliteBuilder]) and Sendspin is muted while it is true. Neither
         * [muted] nor the Home Assistant mute switch changes. Process-wide, so
         * a device built or a Sendspin started mid-call honours it too.
         */
        val callActive = MutableStateFlow(false)

        /** Main thread only, like the Sendspin player. */
        fun setCallActive(active: Boolean) {
            callActive.value = active
            instance?.sendspinPlayer?.setCallMuted(active)
        }

        /** A feature's latest request, not yet taken by the service. */
        private class Change<T>(val config: T?)

        // Main thread only, like every caller.
        private var pendingVoice: Change<VoiceConfig>? = null
        private var pendingSendspin: Change<SendspinConfig>? = null

        /**
         * Starts or rebuilds the satellite. Throws if Android refuses to
         * start the service, as it does while Hearth is not visible.
         */
        fun startVoice(context: Context, config: VoiceConfig) {
            pendingVoice = Change(config)
            request(context)
        }

        fun stopVoice(context: Context) {
            pendingVoice = Change(null)
            request(context)
        }

        /** Starts, rebuilds or stops Sendspin, starting the service if needed. Throws like [startVoice]. */
        fun configureSendspin(context: Context, config: SendspinConfig) {
            pendingSendspin = Change(config)
            request(context)
        }

        private fun request(context: Context) {
            instance?.let {
                it.apply()
                return
            }
            // Nothing to stop in a service that is not running.
            if (pendingVoice?.config == null) pendingVoice = null
            if (pendingSendspin?.config?.active != true) pendingSendspin = null
            if (pendingVoice == null && pendingSendspin == null) return
            ContextCompat.startForegroundService(context, Intent(context, HearthAudioService::class.java))
        }
    }
}
