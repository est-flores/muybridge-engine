package com.muybridge.player

import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.annotation.Keep
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Muybridge video player for Android.
 *
 * Hardware-accelerated video playback with:
 * - Sub-200ms TTFF
 * - Zero-copy decode to GPU
 * - A/V sync within ±16ms
 */
@Keep
class MuybridgePlayer {

    /**
     * Player state.
     */
    enum class State {
        IDLE, LOADING, BUFFERING, PLAYING, PAUSED, SEEKING, ERROR
    }

    private var nativeHandle: Long = 0
    private val mainHandler = Handler(Looper.getMainLooper())

    private val _state = MutableStateFlow(State.IDLE)
    val state: StateFlow<State> = _state.asStateFlow()

    private val _duration = MutableStateFlow(0L)
    val duration: StateFlow<Long> = _duration.asStateFlow()

    private val _position = MutableStateFlow(0L)
    val position: StateFlow<Long> = _position.asStateFlow()

    /**
     * Create the native player.
     */
    fun create() {
        if (nativeHandle == 0L) {
            nativeHandle = nativeCreate()
        }
    }

    /**
     * Release all resources.
     */
    fun release() {
        if (nativeHandle != 0L) {
            nativeRelease(nativeHandle)
            nativeHandle = 0
            _state.value = State.IDLE
        }
    }

    /**
     * Set the output surface.
     */
    fun setSurface(surface: Surface?) {
        if (nativeHandle != 0L) {
            nativeSetSurface(nativeHandle, surface)
        }
    }

    /**
     * Get the texture ID for SurfaceTexture.
     */
    fun getTextureId(): Int {
        return if (nativeHandle != 0L) {
            nativeGetTextureId(nativeHandle)
        } else 0
    }

    /**
     * Load media from URL.
     */
    fun load(url: String): Boolean {
        if (nativeHandle == 0L) return false
        _state.value = State.LOADING
        val result = nativeLoad(nativeHandle, url)
        if (result) {
            _duration.value = nativeGetDuration(nativeHandle)
            _state.value = State.BUFFERING
        } else {
            _state.value = State.ERROR
        }
        return result
    }

    /**
     * Start playback.
     */
    fun play() {
        if (nativeHandle != 0L) {
            nativePlay(nativeHandle)
            _state.value = State.PLAYING
        }
    }

    /**
     * Pause playback.
     */
    fun pause() {
        if (nativeHandle != 0L) {
            nativePause(nativeHandle)
            _state.value = State.PAUSED
        }
    }

    /**
     * Seek to position.
     * @param positionNanos Position in nanoseconds
     */
    fun seek(positionNanos: Long) {
        if (nativeHandle != 0L) {
            _state.value = State.SEEKING
            nativeSeek(nativeHandle, positionNanos)
        }
    }

    /**
     * Get video width.
     */
    fun getVideoWidth(): Int {
        return if (nativeHandle != 0L) {
            nativeGetVideoWidth(nativeHandle)
        } else 0
    }

    /**
     * Get video height.
     */
    fun getVideoHeight(): Int {
        return if (nativeHandle != 0L) {
            nativeGetVideoHeight(nativeHandle)
        } else 0
    }

    // --- Renderer methods (called from GLSurfaceView) ---

    fun initRenderer(): Boolean {
        return if (nativeHandle != 0L) {
            nativeInitRenderer(nativeHandle)
        } else false
    }

    fun setViewport(width: Int, height: Int) {
        if (nativeHandle != 0L) {
            nativeSetViewport(nativeHandle, width, height)
        }
    }

    fun render(transformMatrix: FloatArray?) {
        if (nativeHandle != 0L) {
            nativeRender(nativeHandle, transformMatrix)
        }
    }

    fun releaseRenderer() {
        if (nativeHandle != 0L) {
            nativeReleaseRenderer(nativeHandle)
        }
    }

    /**
     * Check if end of stream has been reached.
     */
    fun isEndOfStream(): Boolean =
        nativeHandle != 0L && nativeIsEndOfStream(nativeHandle)

    companion object {
        init {
            System.loadLibrary("muybridge_android")
        }
    }

    // --- Native methods ---

    private external fun nativeCreate(): Long
    private external fun nativeRelease(handle: Long)
    private external fun nativeSetSurface(handle: Long, surface: Surface?)
    private external fun nativeGetTextureId(handle: Long): Int
    private external fun nativeLoad(handle: Long, url: String): Boolean
    private external fun nativePlay(handle: Long)
    private external fun nativePause(handle: Long)
    private external fun nativeSeek(handle: Long, positionNanos: Long)
    private external fun nativeGetDuration(handle: Long): Long
    private external fun nativeGetVideoWidth(handle: Long): Int
    private external fun nativeGetVideoHeight(handle: Long): Int
    private external fun nativeInitRenderer(handle: Long): Boolean
    private external fun nativeSetViewport(handle: Long, width: Int, height: Int)
    private external fun nativeRender(handle: Long, transformMatrix: FloatArray?)
    private external fun nativeReleaseRenderer(handle: Long)
    private external fun nativeIsEndOfStream(handle: Long): Boolean
}
