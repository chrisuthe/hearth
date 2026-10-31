package com.hearth.hearth

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

/**
 * Hearth's notification, timer and alarm sounds, which the Pi plays through
 * `gst-launch-1.0`.
 *
 * Tones use the media volume, so Hearth's own slider controls them. Alarm tones
 * use the alarm volume, so turning music down at bedtime can't silence an alarm.
 * Neither asks for audio focus: a chime plays over music rather than pausing it.
 */
class SoundsChannel(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "com.hearth/sounds")
    private val mainHandler = Handler(Looper.getMainLooper())

    // Separate threads, because a tone blocks for its whole length.
    private val toneThread = Executors.newSingleThreadExecutor()
    private val alarmThread = Executors.newSingleThreadExecutor()
    private var alarmPlayer: MediaPlayer? = null

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        alarmThread.execute { stopAlarmPlayer() }
        alarmThread.shutdown()
        toneThread.shutdown()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "playTone" -> {
                val hz = call.argument<Int>("hz")
                val durationMs = call.argument<Int>("durationMs")
                val volume = call.argument<Double>("volume")
                if (hz == null || durationMs == null || volume == null) {
                    result.error("bad_args", "hz, durationMs and volume are required", null)
                    return
                }
                toneThread.execute { reply(result) { playTone(hz, durationMs, volume.toFloat()) } }
            }
            "startAlarmTone" -> {
                val asset = call.argument<String>("asset")
                val volume = call.argument<Double>("volume")
                if (asset == null || volume == null) {
                    result.error("bad_args", "asset and volume are required", null)
                    return
                }
                alarmThread.execute { reply(result) { startAlarmPlayer(asset, volume.toFloat()) } }
            }
            "stopAlarmTone" -> alarmThread.execute { reply(result) { stopAlarmPlayer() } }
            else -> result.notImplemented()
        }
    }

    private fun reply(result: MethodChannel.Result, work: () -> Unit) {
        try {
            work()
            mainHandler.post { result.success(null) }
        } catch (e: Exception) {
            Log.w(TAG, "Sound failed", e)
            mainHandler.post { result.error("sound_failed", e.toString(), null) }
        }
    }

    private fun playTone(hz: Int, durationMs: Int, volume: Float) {
        val samples = sineWave(hz, durationMs)
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(samples.size * 2)
            .build()
        try {
            track.write(samples, 0, samples.size)
            track.setVolume(volume)
            track.play()
            awaitEnd(track, samples.size, durationMs)
            track.stop()
        } finally {
            track.release()
        }
    }

    /**
     * Waits for the last frame to play. A fixed sleep would cut the fade-out by
     * the track's start-up latency, and that cut is the click the fade prevents.
     */
    private fun awaitEnd(track: AudioTrack, frames: Int, durationMs: Int) {
        val deadline = SystemClock.uptimeMillis() + durationMs + END_MARGIN_MS
        while (track.playbackHeadPosition < frames && SystemClock.uptimeMillis() < deadline) {
            Thread.sleep(END_POLL_MS)
        }
    }

    /** A sine wave with short fades, since a hard start or stop clicks. */
    private fun sineWave(hz: Int, durationMs: Int): ShortArray {
        val frames = SAMPLE_RATE * durationMs / 1000
        val fade = SAMPLE_RATE / 200
        return ShortArray(frames) { i ->
            val envelope = min(1.0, min(i, frames - 1 - i).toDouble() / fade)
            (sin(2 * PI * hz * i / SAMPLE_RATE) * envelope * Short.MAX_VALUE).toInt().toShort()
        }
    }

    private fun startAlarmPlayer(asset: String, volume: Float) {
        stopAlarmPlayer()
        val player = MediaPlayer()
        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            player.setDataSource(cachedAsset(asset).path)
            player.isLooping = true
            player.setVolume(volume, volume)
            player.prepare()
            player.start()
            alarmPlayer = player
        } catch (e: Exception) {
            player.release()
            throw e
        }
    }

    private fun stopAlarmPlayer() {
        alarmPlayer?.let {
            runCatching { it.stop() }
            it.release()
        }
        alarmPlayer = null
    }

    /**
     * Copies a bundled tone to a file, since [MediaPlayer] can't read an APK
     * asset that the build happened to compress.
     */
    private fun cachedAsset(asset: String): File {
        val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(asset)
        val file = File(context.cacheDir, "sounds/${File(asset).name}")
        file.parentFile?.mkdirs()
        // Through a rename, since a relaunching instance may still be playing it.
        val partial = File.createTempFile(file.name, null, file.parentFile)
        context.assets.open(key).use { input ->
            partial.outputStream().use { output -> input.copyTo(output) }
        }
        if (!partial.renameTo(file)) {
            partial.delete()
            throw java.io.IOException("Couldn't save ${file.name}")
        }
        return file
    }

    private companion object {
        const val TAG = "SoundsChannel"
        const val SAMPLE_RATE = 44100
        const val END_POLL_MS = 5L
        const val END_MARGIN_MS = 300L
    }
}
