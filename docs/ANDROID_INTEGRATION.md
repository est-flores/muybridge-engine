# Muybridge Player - Android Integration

Get hardware-accelerated video playback in your Android app in 2 minutes! 🚀

## Installation

Add to your `build.gradle.kts`:

```kotlin
repositories {
    maven {
        url = uri("https://maven.pkg.github.com/yourorg/muybridge-engine")
        credentials {
            username = "your-github-username"
            password = "your-github-token"  // with read:packages scope
        }
    }
}

dependencies {
    implementation("com.muybridge:player:1.0.0")
}
```

## Quick Start

### 1. Add the View to Your Layout

```xml
<com.muybridge.player.VideoSurfaceView
    android:id="@+id/videoView"
    android:layout_width="match_parent"
    android:layout_height="match_parent" />
```

### 2. Play a Video

```kotlin
class MainActivity : AppCompatActivity() {
    private lateinit var player: MuybridgePlayer
    
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        
        // Create player
        player = MuybridgePlayer()
        player.create()
        
        // Attach to view
        val videoView = findViewById<VideoSurfaceView>(R.id.videoView)
        videoView.setPlayer(player)
        
        // Load and play
        player.load("https://example.com/video.mp4")
        player.play()
    }
    
    override fun onDestroy() {
        super.onDestroy()
        player.release()
    }
}
```

### 3. Observe State (Optional)

```kotlin
lifecycleScope.launch {
    player.state.collect { state ->
        when (state) {
            MuybridgePlayer.State.PLAYING -> showPlayingUI()
            MuybridgePlayer.State.PAUSED -> showPausedUI()
            MuybridgePlayer.State.ERROR -> showError()
            else -> { }
        }
    }
}
```

## Jetpack Compose

```kotlin
@Composable
fun VideoPlayer(url: String) {
    val player = remember { MuybridgePlayer().also { it.create() } }
    
    DisposableEffect(Unit) {
        onDispose { player.release() }
    }
    
    AndroidView(
        factory = { context ->
            VideoSurfaceView(context).apply {
                setPlayer(player)
            }
        }
    )
    
    LaunchedEffect(url) {
        player.load(url)
        player.play()
    }
}
```

## API Reference

| Method        | Description           |
| ------------- | --------------------- |
| `create()`    | Initialize the player |
| `load(url)`   | Load video from URL   |
| `play()`      | Start playback        |
| `pause()`     | Pause playback        |
| `seek(nanos)` | Seek to position      |
| `release()`   | Release resources     |

| Property   | Type               | Description             |
| ---------- | ------------------ | ----------------------- |
| `state`    | `StateFlow<State>` | Current player state    |
| `duration` | `StateFlow<Long>`  | Duration in nanoseconds |
| `position` | `StateFlow<Long>`  | Current position        |

## Requirements

- Android API 24+ (Android 7.0)
- ARM64 or ARMv7 device

## Troubleshooting

**Video not playing?**

- Check URL is accessible
- Verify video format (H.264/HEVC in MP4)

**App crashes on startup?**

- Ensure device has hardware decoder
- Check logcat for native errors

## Support

- 📖 [Full Documentation](https://github.com/yourorg/muybridge-engine)
- 🐛 [Report Issues](https://github.com/yourorg/muybridge-engine/issues)
