package com.muybridge.flutter

import android.view.Surface
import com.muybridge.player.MuybridgePlayer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

class MuybridgeFlutterPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding

    private val players = mutableMapOf<Int, PlayerEntry>()
    private val scope = CoroutineScope(Dispatchers.Main + Job())

    // MARK: - FlutterPlugin

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        methodChannel = MethodChannel(binding.binaryMessenger, "muybridge_flutter/player")
        methodChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        players.values.forEach { it.teardown() }
        players.clear()
        scope.cancel()
    }

    // MARK: - MethodCallHandler

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val playerId = call.argument<Int>("id")
        if (playerId == null) {
            result.error("INVALID_ARGS", "Missing 'id'", null)
            return
        }

        when (call.method) {
            "initialize" -> initialize(playerId, result)
            "load" -> {
                val url = call.argument<String>("url")
                if (url == null) {
                    result.error("INVALID_ARGS", "Missing 'url'", null)
                } else {
                    load(playerId, url, result)
                }
            }
            "play" -> {
                players[playerId]?.let { it.player.play(); it.emit("playing") }
                result.success(null)
            }
            "pause" -> {
                players[playerId]?.let { it.player.pause(); it.emit("paused") }
                result.success(null)
            }
            "seek" -> {
                val nanos = call.argument<Long>("positionNanos") ?: 0L
                players[playerId]?.player?.seek(nanos)
                result.success(null)
            }
            "dispose" -> {
                players.remove(playerId)?.teardown()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // MARK: - initialize

    private fun initialize(playerId: Int, result: MethodChannel.Result) {
        val registry = binding.textureRegistry
        val surfaceEntry = registry.createSurfaceTexture()
        val surface = Surface(surfaceEntry.surfaceTexture())

        val player = MuybridgePlayer()
        player.create()
        player.setSurface(surface)

        val eventChannel = EventChannel(
            binding.binaryMessenger,
            "muybridge_flutter/player/$playerId/events"
        )
        val streamHandler = EventStreamHandler()
        eventChannel.setStreamHandler(streamHandler)

        val entry = PlayerEntry(
            player = player,
            surfaceEntry = surfaceEntry,
            surface = surface,
            streamHandler = streamHandler,
        )
        players[playerId] = entry

        // Collect native StateFlow → event sink
        player.state
            .onEach { state -> entry.emit(state.toEventString()) }
            .launchIn(entry.scope)

        result.success(mapOf("textureId" to surfaceEntry.id(), "playerId" to playerId))
    }

    // MARK: - load

    private fun load(playerId: Int, url: String, result: MethodChannel.Result) {
        val entry = players[playerId]
        if (entry == null) {
            result.error("NO_PLAYER", "Player not found", null)
            return
        }
        entry.emit("loading")
        entry.scope.launch(Dispatchers.IO) {
            val ok = entry.player.load(url)
            scope.launch(Dispatchers.Main) {
                if (ok) {
                    entry.emit("ready")
                    // Watch for EOS via polling (MediaCodec doesn't fire a direct callback)
                    entry.startEosWatcher()
                } else {
                    entry.emit("error")
                }
                result.success(ok)
            }
        }
    }
}

// MARK: - PlayerEntry

private class PlayerEntry(
    val player: MuybridgePlayer,
    val surfaceEntry: io.flutter.view.TextureRegistry.SurfaceTextureEntry,
    val surface: Surface,
    val streamHandler: EventStreamHandler,
) {
    val scope = CoroutineScope(Dispatchers.Main + Job())
    private var eosJob: Job? = null

    fun emit(state: String) {
        streamHandler.sink?.invoke(mapOf("state" to state))
    }

    fun startEosWatcher() {
        eosJob?.cancel()
        eosJob = scope.launch(Dispatchers.IO) {
            while (true) {
                delay(500)
                if (player.isEndOfStream()) {
                    scope.launch(Dispatchers.Main) { emit("ended") }
                    break
                }
            }
        }
    }

    fun teardown() {
        eosJob?.cancel()
        scope.cancel()
        player.release()
        surface.release()
        surfaceEntry.release()
    }
}

// MARK: - EventStreamHandler

private class EventStreamHandler : EventChannel.StreamHandler {
    var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }
}

// MARK: - State mapping

private fun MuybridgePlayer.State.toEventString(): String = when (this) {
    MuybridgePlayer.State.IDLE -> "idle"
    MuybridgePlayer.State.LOADING -> "loading"
    MuybridgePlayer.State.BUFFERING -> "buffering"
    MuybridgePlayer.State.PLAYING -> "playing"
    MuybridgePlayer.State.PAUSED -> "paused"
    MuybridgePlayer.State.SEEKING -> "seeking"
    MuybridgePlayer.State.ERROR -> "error"
}
