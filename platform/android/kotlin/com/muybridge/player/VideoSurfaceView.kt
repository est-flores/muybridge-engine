package com.muybridge.player

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.opengl.GLSurfaceView
import android.opengl.Matrix
import android.util.AttributeSet
import android.view.Surface
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

/**
 * GLSurfaceView for rendering Muybridge video frames.
 *
 * Uses SurfaceTexture for zero-copy frame delivery from decoder.
 */
class VideoSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : GLSurfaceView(context, attrs), GLSurfaceView.Renderer, SurfaceTexture.OnFrameAvailableListener {

    private var player: MuybridgePlayer? = null
    private var surfaceTexture: SurfaceTexture? = null
    private var surface: Surface? = null
    private var textureId: Int = 0

    private val transformMatrix = FloatArray(16)
    private var frameAvailable = false
    private val lock = Object()

    init {
        setEGLContextClientVersion(3)
        setRenderer(this)
        renderMode = RENDERMODE_WHEN_DIRTY
    }

    /**
     * Attach a player to this view.
     */
    fun setPlayer(player: MuybridgePlayer) {
        this.player = player
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        GLES30.glClearColor(0f, 0f, 0f, 1f)

        player?.let { p ->
            // Initialize native renderer
            if (!p.initRenderer()) {
                return
            }

            // Get texture ID and create SurfaceTexture
            textureId = p.getTextureId()
            if (textureId > 0) {
                surfaceTexture = SurfaceTexture(textureId).apply {
                    setOnFrameAvailableListener(this@VideoSurfaceView)
                }
                surface = Surface(surfaceTexture)
                p.setSurface(surface)
            }
        }
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        GLES30.glViewport(0, 0, width, height)
        player?.setViewport(width, height)
        surfaceTexture?.setDefaultBufferSize(width, height)
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)

        synchronized(lock) {
            if (frameAvailable) {
                surfaceTexture?.updateTexImage()
                surfaceTexture?.getTransformMatrix(transformMatrix)
                frameAvailable = false
            }
        }

        player?.render(transformMatrix)
    }

    override fun onFrameAvailable(st: SurfaceTexture?) {
        synchronized(lock) {
            frameAvailable = true
        }
        requestRender()
    }

    /**
     * Release resources when view is detached.
     */
    fun release() {
        queueEvent {
            player?.releaseRenderer()
            surface?.release()
            surfaceTexture?.release()
            surface = null
            surfaceTexture = null
        }
    }

    override fun onDetachedFromWindow() {
        release()
        super.onDetachedFromWindow()
    }
}
