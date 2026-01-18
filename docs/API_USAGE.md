# Muybridge Engine - API Usage Examples

This guide demonstrates how to use the Muybridge video engine on Android and
iOS.

## Android (Kotlin)

### Basic Playback

```kotlin
// Create player
val player = MuybridgePlayer()
player.create()

// Setup video view
val videoView = findViewById<VideoSurfaceView>(R.id.video_view)
videoView.setPlayer(player)

// Load and play
player.load("file:///sdcard/video.mp4")
player.play()
```

### State Observation

```kotlin
lifecycleScope.launch {
    player.state.collect { state ->
        when (state) {
            MuybridgePlayer.State.PLAYING -> updateUI()
            MuybridgePlayer.State.ERROR -> showError()
            else -> {}
        }
    }
}
```

### Cleanup

```kotlin
override fun onDestroy() {
    videoView.release()
    player.release()
    super.onDestroy()
}
```

---

## iOS (Swift)

### UIKit Integration

```swift
let player = MuybridgePlayer()
let videoView = MetalVideoView(frame: bounds, device: player.device)
videoView.setPlayer(player)
view.addSubview(videoView)

player.load(url: "file:///path/to/video.mp4")
player.play()
```

### SwiftUI Integration

```swift
import SwiftUI

struct ContentView: View {
    @State private var player = MuybridgePlayer()
    
    var body: some View {
        VideoPlayerView(player: player)
            .onAppear {
                player.load(url: videoURL)
                player.play()
            }
    }
}
```

### State Observation

```swift
// iOS 17+ with @Observable
Text("State: \(player.state)")
```

---

## Error Handling

### Android

```kotlin
when (player.state.value) {
    MuybridgePlayer.State.ERROR -> {
        // Handle error state
        Log.e(TAG, "Playback failed")
        showErrorDialog()
    }
    else -> {}
}
```

### iOS

```swift
if player.state == .error {
    showAlert(title: "Error", message: "Playback failed")
}
```

---

## Performance Monitoring

### TTFF Measurement

TTFF milestones are logged automatically:

```
[I] [TTFF] open_start @ 0.0ms
[I] [TTFF] extractor_configured @ 15.2ms
[I] [TTFF] codec_configured @ 45.7ms
[I] [TTFF] decode_started @ 48.1ms
[I] [TTFF] first_frame_decoded @ 112.4ms
[I] [TTFF] renderer_initialized @ 115.8ms
[I] [TTFF] first_frame_rendered @ 142.3ms
```

### A/V Sync Validation

Sync deviations are logged when exceeding ±16ms:

```
[W] [SYNC] Out of sync: 18.5ms (tolerance: ±16.0ms)
```
