package com.hearth.hearth.sendspin

import android.content.Context
import android.database.ContentObserver
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.sendspindroid.coordinator.FailureReason
import com.sendspindroid.coordinator.InboundConnections
import com.sendspindroid.coordinator.TransportState
import com.sendspindroid.discovery.NsdAdvertiser
import com.sendspindroid.model.PlaybackStateType
import com.sendspindroid.playback.SendSpinEngine
import com.sendspindroid.sendspin.PlaybackState
import com.sendspindroid.sendspin.SendSpin
import com.sendspindroid.sendspin.SyncAudioPlayer
import com.sendspindroid.sendspin.protocol.TrackMetadata
import com.sendspindroid.sendspin.transport.SendspinWebSocketServer
import kotlin.concurrent.thread
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.android.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import timber.log.Timber

/**
 * Sendspin inside `HearthAudioService`: waits for servers to connect, plays
 * from the one admitted through SendspinDroid's [SendSpinEngine], and keeps
 * the device's media volume and the server's in step.
 *
 * The connection side is ported from SendspinDroid's `PlaybackService`
 * (`startAdvertising`, `newInboundClient`, `onServerAdmitted`, `useClient`,
 * `advertiseAgainAfterNetworkChange`, `initializeVolumeControl`), without its
 * dialled mode, media session or audio focus.
 *
 * One instance per `configure`: a settings change closes it and starts a new
 * one. Main thread only, apart from the client callbacks, which post.
 */
class SendspinPlayer(
    private val context: Context,
    private val config: SendspinConfig,
    softwareVersion: String,
    /** A line for the service notification, whenever it changes. */
    private val onStatus: (String) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())

    // Synchronous messages on our Handler, so the engine's posts stay ordered
    // with ours, as in PlaybackService.
    private val mainDispatcher = main.asCoroutineDispatcher()
    private val scope = CoroutineScope(SupervisorJob() + mainDispatcher)

    // Not cancelled by close(): InboundConnections destroys a displaced
    // client from here once its goodbye is out, after the listener has gone.
    private val connectionScope = CoroutineScope(SupervisorJob() + mainDispatcher)

    private val secrets = SendspinSecrets.get(context)
    private val volume = MediaVolume(context)
    private val host = HearthSendSpinHost(
        config = config,
        secrets = secrets,
        softwareVersion = softwareVersion,
        onOutputDelay = { ms ->
            SendspinEvents.outputDelay(ms)
            main.post { report() }
        },
        onPairingChanged = { main.post { report() } },
    )

    private val engine = SendSpinEngine(
        listener = object : SendSpinEngine.Listener {
            // The service holds its wake and Wi-Fi locks for as long as it runs.
            override fun onStreamStarted() {}

            override fun onPlayerChanged(player: SyncAudioPlayer?) = report()

            override fun onPlayerStateChanged(state: PlaybackState) = report()
        },
        lowMemoryMode = { false },
        playerMuted = { playerMuted },
        mainDispatcher = mainDispatcher,
    )

    private var lastPlaybackServerId = config.lastPlaybackServerId

    private val inbound = InboundConnections(
        scope = connectionScope,
        newClient = ::newInboundClient,
        onAdmitted = { client -> main.post { onServerAdmitted(client) } },
        lastPlaybackServerId = { lastPlaybackServerId },
        storeLastPlaybackServerId = {
            lastPlaybackServerId = it
            SendspinEvents.lastPlaybackServer(it)
        },
    )

    private var listener: SendspinWebSocketServer? = null
    private var advertiser: NsdAdvertiser? = null
    private var boundPort: Int? = null
    private var unavailable = false
    private var closed = false

    // Bumped by every start and by close(), so a bind that finishes late
    // knows to undo itself.
    private var advertisingGeneration = 0

    /** The client being played from, and what its connection last did. */
    private var current: SendSpin? = null
    private var clientState: TransportState = TransportState.Idle
    private var clientObserver: Job? = null

    private var metadata: Map<String, Any?>? = null
    private var group: Map<String, Any?> = emptyMap()

    private var lastKnownVolume = -1
    private var volumeObserver: ContentObserver? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var lastStatus: String? = null

    /**
     * False when [start] found nothing it could do (a server URL, unreadable
     * secrets); the service then holds no locks for it.
     */
    var running = false
        private set

    /**
     * Mutes the output while a doorbell call is open. Uses the engine's VOICE
     * reason, which the engine keeps for every later player; Hearth sets it
     * nowhere else.
     */
    fun setCallMuted(muted: Boolean) {
        engine.setMuted(SyncAudioPlayer.MuteReason.VOICE, muted)
    }

    fun start() {
        if (config.serverUrl.isNotBlank()) {
            // Advertising and dialling are exclusive, and dialling is not built yet.
            unavailable = true
            SendspinEvents.health(
                SendspinEvents.DIALLED_UNSUPPORTED,
                "A server URL is set, and connecting to a server is not supported on Android yet. " +
                    "Clear the URL to let servers find this player.",
            )
            report()
            return
        }
        try {
            secrets.identity
            secrets.trustStore
        } catch (e: Exception) {
            Timber.e(e, "Sendspin secrets unreadable")
            unavailable = true
            SendspinEvents.health(SendspinEvents.SECRETS_UNREADABLE, e.message.orEmpty())
            report()
            return
        }
        running = true
        initializeVolumeControl()
        registerNetworkCallback()
        startAdvertising()
        scope.launch {
            // Buffer depth and clock precision move on their own.
            while (isActive) {
                delay(STATS_INTERVAL_MS)
                if (clientState is TransportState.Ready) report()
            }
        }
        report()
    }

    /** Dart's system slider. Sets the media volume and tells the server. */
    fun setVolume(value: Float) {
        lastKnownVolume = volume.set(value)
        reportVolume()
        report()
    }

    /**
     * End every connection, withdraw the advertisement and release the
     * output. Waits for the listener to let go of its port.
     */
    suspend fun close() {
        val server = shutDown() ?: return
        withContext(Dispatchers.IO) { server.stop() }
    }

    /**
     * [close] for the service's onDestroy, which cannot wait: the listener
     * says its goodbyes and releases the port on a thread of its own.
     */
    fun closeNow() {
        val server = shutDown() ?: return
        thread(name = "SendspinListenerStop") { server.stop() }
    }

    /** Everything but stopping the listener, which is returned for the caller to stop. */
    private fun shutDown(): SendspinWebSocketServer? {
        if (closed) return null
        closed = true
        advertisingGeneration++
        advertiser?.stop()
        advertiser = null
        clientObserver?.cancel()
        engine.endStream()
        engine.releasePlayer()
        engine.client = null
        current = null
        inbound.close()
        volumeObserver?.let { context.contentResolver.unregisterContentObserver(it) }
        volumeObserver = null
        networkCallback?.let { connectivity().unregisterNetworkCallback(it) }
        networkCallback = null
        engine.release()
        scope.cancel()
        SendspinEvents.state(mapOf("state" to "disabled", "volume" to volume.get().toDouble()))
        return listener.also { listener = null }
    }

    // ========== Server-initiated connections ==========

    private fun startAdvertising() {
        val generation = ++advertisingGeneration
        val server = SendspinWebSocketServer(
            onConnection = { inbound.onConnection(it, it.remoteAddress) },
        )
        listener = server
        inbound.open()
        scope.launch {
            // Binding the socket is blocking I/O.
            val port = withContext(Dispatchers.IO) { runCatching { server.start() } }
                .getOrElse {
                    Timber.e(it, "Cannot listen for Sendspin servers")
                    if (generation == advertisingGeneration) {
                        unavailable = true
                        SendspinEvents.health(SendspinEvents.LISTENER_FAILED, it.message.orEmpty())
                        report()
                    }
                    return@launch
                }
            if (generation != advertisingGeneration) {
                withContext(Dispatchers.IO) { server.stop() }
                return@launch
            }
            boundPort = port
            // "Advertise the port actually bound": 8928 unless it was taken.
            advertiser = NsdAdvertiser(context) { registered ->
                main.post { if (generation == advertisingGeneration) onRegistration(registered) }
            }.also { it.start(config.playerName, port, SendspinWebSocketServer.DEFAULT_PATH) }
            Timber.i("Sendspin advertising as '${config.playerName}' on port $port")
        }
    }

    private fun onRegistration(registered: Boolean) {
        if (!registered) {
            SendspinEvents.health(
                SendspinEvents.ADVERTISE_FAILED,
                "The mDNS registration for _sendspin._tcp failed",
            )
        }
        unavailable = !registered
        report()
    }

    /**
     * Announce again on a new network, and if the listener never came up,
     * try that again too. No timer retries: a change of network is when the
     * outcome can be different.
     */
    private fun advertiseAgainAfterNetworkChange() {
        if (closed) return
        if (unavailable && boundPort == null) startAdvertising() else advertiser?.refresh()
    }

    /** A client for one connection a server opens to us. Not on the main thread. */
    private fun newInboundClient(): SendSpin {
        val callback = ClientCallback()
        val client = SendSpin(config.playerName, callback, host)
        callback.client = client
        client.setInitialVolume((volume.get() * 100).roundToInt(), playerMuted)
        connectionScope.launch { watchForLegacyServer(client) }
        return client
    }

    /**
     * A server that predates encryption fails the handshake before it can be
     * admitted, so the admitted client's state never shows it.
     */
    private suspend fun watchForLegacyServer(client: SendSpin) {
        val ended = withTimeoutOrNull(LEGACY_WATCH_MS) {
            client.connectionState.first { it !is TransportState.Idle }
            client.connectionState.first { it is TransportState.Idle || it is TransportState.Failed }
        }
        if ((ended as? TransportState.Failed)?.reason is FailureReason.ServerLacksEncryption) {
            SendspinEvents.health(
                SendspinEvents.SERVER_LACKS_ENCRYPTION,
                "A server at ${client.getServerAddress()} does not support encryption; update it",
            )
        }
    }

    private fun onServerAdmitted(client: SendSpin) {
        if (closed) return
        useClient(client)
    }

    /** Play from [client] from now on. Whatever was playing ends as if its connection had. */
    private fun useClient(client: SendSpin) {
        if (current === client) return
        clientObserver?.cancel()
        if (clientState !is TransportState.Idle) onClientState(TransportState.Idle)
        current = client
        engine.client = client
        clientObserver = scope.launch { client.connectionState.collect { onClientState(it) } }
    }

    private fun onClientState(state: TransportState) {
        if (state !is TransportState.Ready) engine.endStream()
        val ended = state is TransportState.Idle || state is TransportState.Failed
        val wasEnded = clientState is TransportState.Idle || clientState is TransportState.Failed
        if (ended && !wasEnded) {
            engine.releasePlayer()
            metadata = null
            group = emptyMap()
        }
        clientState = state
        report()
    }

    /** Callbacks of one client. [SendSpin] silences them while it is not the one played from. */
    private inner class ClientCallback : SendSpin.Callback {
        @Volatile
        var client: SendSpin? = null

        /** Main thread, and only while this client is still the one played from. */
        private fun onMain(block: () -> Unit) {
            main.post { if (!closed && client === current) block() }
        }

        override fun onStateChanged(state: String) = onMain {
            engine.applyServerPlayback(PlaybackStateType.fromString(state))
            report()
        }

        override fun onGroupUpdate(groupId: String, groupName: String, playbackState: String) = onMain {
            if (playbackState.isNotEmpty()) engine.applyServerPlayback(PlaybackStateType.fromString(playbackState))
            group = mapOf(
                "id" to groupId.ifEmpty { group["id"] as String? },
                "name" to groupName.ifEmpty { group["name"] as String? },
                "playbackState" to playbackState.ifEmpty { group["playbackState"] as String? },
            )
            report()
        }

        override fun onMetadataUpdate(metadata: TrackMetadata, positionMs: Long) = onMain {
            // server/state carries the full state, so null means the track has no such field.
            this@SendspinPlayer.metadata = mapOf(
                "title" to metadata.title?.ifEmpty { null },
                "artist" to metadata.artist?.ifEmpty { null },
                "album" to metadata.album?.ifEmpty { null },
                "artworkUrl" to metadata.artworkUrl?.ifEmpty { null },
                "durationMs" to metadata.durationMs,
                "positionMs" to positionMs,
                // No progress object means no position, so nothing to advance.
                "playbackSpeed" to (metadata.progress?.playbackSpeed ?: 0),
            )
            report()
        }

        // A removal has already stopped the output; release it, as PlaybackService does.
        override fun onPlayerRoleChanged(active: Boolean) {
            if (!active) onMain { engine.releasePlayer() }
        }

        // The Media screen loads art from the metadata URL.
        override fun onArtwork(imageData: ByteArray) {}

        override fun onArtworkCleared() {}

        override fun onStreamStart(codec: String, sampleRate: Int, channels: Int, bitDepth: Int, codecHeader: ByteArray?) =
            engine.onStreamStart(codec, sampleRate, channels, bitDepth, codecHeader)

        override fun onStreamClear() = engine.onStreamClear()

        override fun onStreamEnd() = engine.onStreamEnd()

        override fun onAudioChunk(serverTimeMicros: Long, audioData: ByteArray) =
            engine.onAudioChunk(serverTimeMicros, audioData)

        override fun onVolumeChanged(volume: Int) = onMain {
            lastKnownVolume = this@SendspinPlayer.volume.set(volume / 100f)
            report()
        }

        override fun onMutedChanged(muted: Boolean) = onMain {
            // Mute and volume are independent: a later volume change must not unmute.
            engine.setMuted(SyncAudioPlayer.MuteReason.PLAYER, muted)
            playerMuted = muted
            report()
        }

        override fun onSyncOffsetApplied(offsetMs: Double, source: String) {
            Timber.i("Sendspin sync offset ${offsetMs}ms from $source")
        }

        override fun onSyncMuteChanged(muted: Boolean) = engine.onSyncMuteChanged(muted)

        override fun onNetworkChanged() = engine.onNetworkChanged()
    }

    // ========== Volume ==========

    /** Hardware keys and other apps move `STREAM_MUSIC`; tell the server. */
    private fun initializeVolumeControl() {
        lastKnownVolume = volume.index
        val observer = object : ContentObserver(main) {
            override fun onChange(selfChange: Boolean) {
                val index = volume.index
                if (index == lastKnownVolume) return
                lastKnownVolume = index
                reportVolume()
                report()
            }
        }
        context.contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, observer)
        volumeObserver = observer
    }

    /**
     * The media volume to the server. `setVolume` truncates `volume * 100`,
     * and 41/100 comes out as 40.99…: the half step makes it land on the
     * percent the device shows.
     */
    private fun reportVolume() {
        val percent = (volume.get() * 100).roundToInt()
        current?.setVolume((percent + 0.5) / 100)
    }

    // ========== Network ==========

    private fun connectivity() =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private fun registerNetworkCallback() {
        var network: Network? = null
        var addresses: List<Any>? = null
        val callback = object : ConnectivityManager.NetworkCallback() {
            // Called once for the network there is at registration; that one is not a change.
            override fun onLinkPropertiesChanged(changed: Network, properties: LinkProperties) {
                main.post {
                    val now = properties.linkAddresses.map { it.address }
                    val first = network == null
                    if (!first && changed == network && now == addresses) return@post
                    val newNetwork = changed != network
                    network = changed
                    addresses = now
                    if (!first) {
                        // Only a new network resets the client's clock and queue. An
                        // address change on the same one (an IPv6 temporary address)
                        // keeps the connection, and resetting it silenced playback
                        // for seconds; a change that breaks the path closes the socket.
                        if (newNetwork) current?.onNetworkChanged()
                        Timber.i("Network changed - Sendspin advertising again")
                        advertiseAgainAfterNetworkChange()
                    }
                }
            }
        }
        try {
            connectivity().registerDefaultNetworkCallback(callback, main)
            networkCallback = callback
        } catch (e: Exception) {
            Timber.w(e, "No network callback; Sendspin will not re-advertise on a network change")
        }
    }

    // ========== State ==========

    private fun connectionState(): String {
        if (unavailable) return "disconnected"
        if (clientState !is TransportState.Ready) return "advertising"
        val player = engine.hostPlayer ?: return "connected"
        return when (player.getPlaybackState()) {
            PlaybackState.PLAYING -> "streaming"
            else -> "syncing"
        }
    }

    /** Dart's `clockOffsetMs`: the clock's precision, -1 until it has one. */
    private fun clockPrecisionMs(): Int {
        val filter = current?.getTimeFilter() ?: return -1
        if (!filter.isReady) return -1
        val error = filter.errorMicros
        return if (error == Long.MAX_VALUE) -1 else (error / 1000).toInt()
    }

    private fun report() {
        if (closed) return
        val state = connectionState()
        val ready = clientState is TransportState.Ready
        val stream = engine.activeStream.takeIf { ready }
        SendspinEvents.state(
            mapOf(
                "state" to state,
                "serverName" to current?.getServerName()?.takeIf { ready },
                "volume" to volume.get().toDouble(),
                "muted" to playerMuted,
                "codec" to stream?.codec,
                "sampleRate" to stream?.sampleRate,
                "channels" to stream?.channels,
                "bufferDepthMs" to (engine.hostPlayer?.getBufferedDurationMs() ?: 0L).toInt(),
                "clockOffsetMs" to if (ready) clockPrecisionMs() else 0,
                "outputDelayMs" to host.outputDelayMs(),
                "pairedServers" to runCatching { secrets.trustStore.listRecords().size }.getOrDefault(0),
                "metadata" to metadata,
                "group" to group,
            ),
        )
        val status = when (state) {
            "streaming" -> "Sendspin playing from ${current?.getServerName().orEmpty()}"
            "syncing", "connected" -> "Sendspin connected to ${current?.getServerName().orEmpty()}"
            "advertising" -> "Sendspin waiting for a server"
            else -> "Sendspin unavailable"
        }
        if (status != lastStatus) {
            lastStatus = status
            onStatus(status)
        }
    }

    companion object {
        private const val STATS_INTERVAL_MS = 1000L

        /** Longer than any handshake; bounds the watch on a connection that never ends. */
        private const val LEGACY_WATCH_MS = 60_000L

        /**
         * The server's mute, kept for the life of the process so a
         * reconfigure does not unmute. Not persisted: a restart starts
         * unmuted and the server says otherwise on connect.
         */
        @Volatile
        private var playerMuted = false
    }
}
