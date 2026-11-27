package com.hearth.hearth.voice

import android.content.Context
import android.media.AudioManager
import android.os.Build
import androidx.media3.common.C
import com.example.ava.esphome.EspHomeDevice
import com.example.ava.esphome.android.logger.TimberLogger
import com.example.ava.esphome.android.mediaplayer.media3MediaPlayer
import com.example.ava.esphome.entities.MediaPlayerEntity
import com.example.ava.esphome.entities.SwitchEntity
import com.example.ava.esphome.voiceassistant.VoiceAssistant
import com.example.ava.esphome.voiceassistant.VoiceInputImpl
import com.example.ava.esphome.voiceassistant.VoiceOutputImpl
import com.example.ava.server.ServerImpl
import com.example.ava.settings.SettingState
import com.example.ava.wakewords.providers.AssetWakeWordProvider
import com.example.esphomeproto.api.VoiceAssistantFeature
import com.example.esphomeproto.api.deviceInfoResponse
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.flowOf
import kotlin.coroutines.CoroutineContext

private const val WAKE_SOUND = "asset:///sounds/wake_word_triggered.flac"
private const val TIMER_FINISHED_SOUND = "asset:///sounds/timer_finished.flac"
private const val ERROR_SOUND = "asset:///sounds/error.flac"

/**
 * The settings Home Assistant can change on a running satellite. They live in
 * memory for the life of one device; a change made from Home Assistant is
 * reported to Dart, which owns the persisted copy.
 */
class SatelliteSettings(config: VoiceConfig) {
    val muted = MutableStateFlow(config.muted)
    val wakeSound = MutableStateFlow(config.wakeSound)
    val wakeWords = MutableStateFlow(config.wakeWords)
    val stopWords = MutableStateFlow(listOf("stop"))
    val playerVolume = MutableStateFlow(config.volume)
    val playerMuted = MutableStateFlow(false)
}

/**
 * Assembles the ESPHome device from Hearth's configuration. The counterpart
 * of DeviceBuilder in the fork's :app module, without Hilt or DataStore.
 */
class SatelliteBuilder(private val context: Context) {
    fun build(
        coroutineContext: CoroutineContext,
        config: VoiceConfig,
        settings: SatelliteSettings,
        audio: AudioCoordinator,
        onModelLoadFailed: (id: String, error: Throwable) -> Unit,
    ): EspHomeDevice {
        val voiceOutput = VoiceOutputImpl(
            ttsPlayer = context.media3MediaPlayer(
                C.USAGE_ASSISTANT,
                C.AUDIO_CONTENT_TYPE_SPEECH,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
            ),
            mediaPlayer = context.media3MediaPlayer(
                C.USAGE_MEDIA,
                C.AUDIO_CONTENT_TYPE_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            ),
            enableWakeSound = { settings.wakeSound.value },
            wakeSound = { WAKE_SOUND },
            timerFinishedSound = { TIMER_FINISHED_SOUND },
            // The ring repeats until the stop word, a wake word or a stop call,
            // with Ava's one-second pause after each play for the stop word.
            repeatTimerFinishedSound = { true },
            enableErrorSound = { false },
            errorSound = { ERROR_SOUND },
            volume = config.volume,
        )
        // A doorbell call silences the satellite's own players too (replies,
        // announcements, its media player), so they neither talk over the
        // visitor nor reach the Talk microphone. Home Assistant still sees
        // its own mute state, which this leaves alone.
        combine(HearthAudioService.callActive, settings.playerMuted) { held, muted -> held || muted }
            .onEach { voiceOutput.muted = it }
            .launchIn(CoroutineScope(coroutineContext))
        val voiceInput = VoiceInputImpl(
            microphone = flowOf(HearthMicrophone(config.audioSourceId)),
            wakeWord = HearthWakeWord(onModelLoadFailed),
            availableWakeWords = { wakeWords(config.cutoffScale) },
            availableStopWords = { AssetWakeWordProvider(context.assets, path = "stopWords").get() },
            activeWakeWords = SettingState(settings.wakeWords) {
                settings.wakeWords.value = it
                VoiceEvents.settingChanged("wakeWords", it)
            },
            activeStopWords = SettingState(settings.stopWords) { settings.stopWords.value = it },
            // Ava stops and releases the microphone while this is true, so a
            // doorbell call holds it off without touching the mute setting
            // that Home Assistant sees.
            muted = SettingState(
                combine(settings.muted, HearthAudioService.callActive) { muted, held -> muted || held },
            ) { settings.muted.value = it },
        )
        return EspHomeDevice(
            coroutineContext = coroutineContext,
            port = config.port,
            server = TimerEventTap(ServerImpl()),
            deviceInfo = deviceInfoResponse {
                name = config.nodeName
                friendlyName = config.name
                macAddress = config.mac
                manufacturer = "Hearth"
                model = Build.MODEL
                // Home Assistant shows this field as the device's firmware.
                esphomeVersion = appVersion()
                voiceAssistantFeatureFlags = VoiceAssistantFeature.VOICE_ASSISTANT.flag or
                    VoiceAssistantFeature.API_AUDIO.flag or
                    VoiceAssistantFeature.TIMERS.flag or
                    VoiceAssistantFeature.ANNOUNCE.flag or
                    VoiceAssistantFeature.START_CONVERSATION.flag
            },
            voiceAssistant = VoiceAssistant(
                coroutineContext = coroutineContext,
                voiceInput = voiceInput,
                voiceOutput = CoordinatedVoiceOutput(voiceOutput, audio),
            ),
            logger = TimberLogger(),
            entities = listOf(
                MediaPlayerEntity(
                    key = 0,
                    name = "Media Player",
                    objectId = "media_player",
                    mediaPlayer = voiceOutput,
                    getVolumeState = settings.playerVolume,
                    setVolume = {
                        settings.playerVolume.value = it
                        VoiceEvents.settingChanged("volume", it)
                    },
                    getMutedState = settings.playerMuted,
                    setMuted = { settings.playerMuted.value = it },
                ),
                // Hearth finds this switch by "mute" in its entity ID.
                SwitchEntity(
                    key = 1,
                    name = "Mute Microphone",
                    objectId = "mute_microphone",
                    getState = settings.muted,
                ) {
                    settings.muted.value = it
                    VoiceEvents.settingChanged("mute", it)
                },
                SwitchEntity(
                    key = 2,
                    name = "Enable Wake Sound",
                    objectId = "enable_wake_sound",
                    getState = settings.wakeSound,
                ) {
                    settings.wakeSound.value = it
                    VoiceEvents.settingChanged("wakeSound", it)
                },
            ),
        )
    }

    private suspend fun wakeWords(cutoffScale: Float) =
        AssetWakeWordProvider(context.assets).get().map {
            val micro = it.wakeWord.micro
            it.copy(
                wakeWord = it.wakeWord.copy(
                    micro = micro.copy(probability_cutoff = micro.probability_cutoff * cutoffScale),
                ),
            )
        }

    private fun appVersion(): String = runCatching {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName
    }.getOrNull().orEmpty()
}
