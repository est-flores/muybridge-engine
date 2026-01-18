package com.muybridge.example

import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.muybridge.player.MuybridgePlayer
import com.muybridge.player.VideoSurfaceView
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * Sample Activity demonstrating Muybridge video playback.
 *
 * Features:
 * - TTFF measurement with logging
 * - State observation via Kotlin Flow
 * - Error handling patterns
 * - Playback controls
 */
class MainActivity : AppCompatActivity() {

    private lateinit var player: MuybridgePlayer
    private lateinit var videoView: VideoSurfaceView
    private lateinit var playPauseButton: Button
    private lateinit var stateText: TextView
    private lateinit var loadingIndicator: ProgressBar

    // TTFF measurement
    private var loadStartTime: Long = 0
    private var firstFrameTime: Long = 0

    companion object {
        private const val TAG = "MuybridgeExample"
        private const val TEST_VIDEO = "file:///sdcard/Movies/test.mp4"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Note: In production, use a proper layout XML
        setupUI()
        setupPlayer()
    }

    private fun setupUI() {
        // Create layout programmatically for example
        videoView = VideoSurfaceView(this)
        playPauseButton = Button(this).apply {
            text = "Play"
            setOnClickListener { togglePlayback() }
        }
        stateText = TextView(this)
        loadingIndicator = ProgressBar(this)
        
        // Set content view (simplified - use ConstraintLayout in production)
        setContentView(videoView)
    }

    private fun setupPlayer() {
        player = MuybridgePlayer()
        player.create()
        
        // Attach to view
        videoView.setPlayer(player)
        
        // Observe state changes
        lifecycleScope.launch {
            player.state.collect { state ->
                handleStateChange(state)
            }
        }
        
        // Load video
        loadVideo(TEST_VIDEO)
    }

    private fun loadVideo(url: String) {
        loadStartTime = System.nanoTime()
        Log.i(TAG, "[TTFF] Load started @ ${loadStartTime / 1_000_000}ms")
        
        val success = player.load(url)
        if (!success) {
            showError("Failed to load video")
            return
        }
        
        Log.i(TAG, "[TTFF] Media opened @ ${(System.nanoTime() - loadStartTime) / 1_000_000}ms")
        
        // Log media info
        Log.i(TAG, "Video: ${player.getVideoWidth()}x${player.getVideoHeight()}")
        Log.i(TAG, "Duration: ${player.duration.value / 1_000_000_000}s")
    }

    private fun handleStateChange(state: MuybridgePlayer.State) {
        Log.d(TAG, "State changed: $state")
        
        runOnUiThread {
            stateText.text = "State: $state"
            
            when (state) {
                MuybridgePlayer.State.IDLE -> {
                    loadingIndicator.visibility = View.GONE
                    playPauseButton.isEnabled = false
                }
                
                MuybridgePlayer.State.LOADING -> {
                    loadingIndicator.visibility = View.VISIBLE
                    playPauseButton.isEnabled = false
                }
                
                MuybridgePlayer.State.BUFFERING -> {
                    loadingIndicator.visibility = View.VISIBLE
                    playPauseButton.isEnabled = false
                }
                
                MuybridgePlayer.State.PLAYING -> {
                    // First frame rendered - log TTFF
                    if (firstFrameTime == 0L) {
                        firstFrameTime = System.nanoTime()
                        val ttffMs = (firstFrameTime - loadStartTime) / 1_000_000
                        Log.i(TAG, "[TTFF] First frame @ ${ttffMs}ms ✓")
                        
                        // Check against target
                        if (ttffMs < 200) {
                            Log.i(TAG, "[TTFF] TARGET MET: <200ms ✓")
                        } else {
                            Log.w(TAG, "[TTFF] TARGET MISSED: ${ttffMs}ms > 200ms")
                        }
                    }
                    
                    loadingIndicator.visibility = View.GONE
                    playPauseButton.text = "Pause"
                    playPauseButton.isEnabled = true
                }
                
                MuybridgePlayer.State.PAUSED -> {
                    loadingIndicator.visibility = View.GONE
                    playPauseButton.text = "Play"
                    playPauseButton.isEnabled = true
                }
                
                MuybridgePlayer.State.SEEKING -> {
                    loadingIndicator.visibility = View.VISIBLE
                }
                
                MuybridgePlayer.State.ERROR -> {
                    loadingIndicator.visibility = View.GONE
                    showError("Playback error")
                }
            }
        }
    }

    private fun togglePlayback() {
        when (player.state.value) {
            MuybridgePlayer.State.PLAYING -> player.pause()
            MuybridgePlayer.State.PAUSED -> player.play()
            MuybridgePlayer.State.BUFFERING -> player.play()
            else -> {}
        }
    }

    private fun showError(message: String) {
        Log.e(TAG, "Error: $message")
        runOnUiThread {
            stateText.text = "Error: $message"
            playPauseButton.isEnabled = false
        }
    }

    override fun onResume() {
        super.onResume()
        videoView.onResume()
    }

    override fun onPause() {
        super.onPause()
        videoView.onPause()
        player.pause()
    }

    override fun onDestroy() {
        super.onDestroy()
        videoView.release()
        player.release()
    }
}
