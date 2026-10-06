# Muybridge Player - iOS Integration

Get hardware-accelerated video playback in your iOS app in 2 minutes! 🚀

## Installation

### Swift Package Manager (Recommended)

1. In Xcode: **File → Add Package Dependencies**
2. Enter: `https://github.com/est-flores/muybridge-engine`
3. Select version: `1.0.0`
4. Click **Add Package**

Or add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/est-flores/muybridge-engine", from: "1.0.0")
]
```

## Quick Start

### SwiftUI (Simplest)

```swift
import SwiftUI
import MuybridgePlayer

struct ContentView: View {
    @State private var player = MuybridgePlayer()
    
    var body: some View {
        VideoPlayerView(player: player)
            .onAppear {
                player.load(url: "https://example.com/video.mp4")
                player.play()
            }
            .onDisappear {
                player.release()
            }
    }
}
```

That's it! 🎉

### UIKit

```swift
import UIKit
import MuybridgePlayer

class VideoViewController: UIViewController {
    private var player: MuybridgePlayer!
    private var videoView: MetalVideoView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Create player
        player = MuybridgePlayer()
        
        // Create video view
        videoView = MetalVideoView(frame: view.bounds, device: player.device)
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)
        
        // Connect and play
        videoView.setPlayer(player)
        player.load(url: "https://example.com/video.mp4")
        player.play()
    }
    
    deinit {
        videoView.releaseResources()
        player.release()
    }
}
```

### Observe State

```swift
// iOS 17+ with @Observable
struct PlayerView: View {
    @State private var player = MuybridgePlayer()
    
    var body: some View {
        VStack {
            VideoPlayerView(player: player)
            
            Text("State: \(player.state)")
            
            Button(player.state == .playing ? "Pause" : "Play") {
                player.state == .playing ? player.pause() : player.play()
            }
        }
    }
}
```

## API Reference

| Method       | Description                    |
| ------------ | ------------------------------ |
| `load(url:)` | Load video from URL            |
| `play()`     | Start playback                 |
| `pause()`    | Pause playback                 |
| `seek(to:)`  | Seek to position (nanoseconds) |
| `release()`  | Release resources              |

| Property      | Type    | Description             |
| ------------- | ------- | ----------------------- |
| `state`       | `State` | Current player state    |
| `duration`    | `Int64` | Duration in nanoseconds |
| `videoWidth`  | `Int32` | Video width             |
| `videoHeight` | `Int32` | Video height            |

### States

```swift
enum State {
    case idle       // Not initialized
    case loading    // Opening media
    case buffering  // Prebuffering
    case playing    // Active playback
    case paused     // Paused
    case seeking    // Seeking
    case error      // Error occurred
}
```

## Views

| View              | Usage                     |
| ----------------- | ------------------------- |
| `VideoPlayerView` | SwiftUI wrapper (easiest) |
| `MetalVideoView`  | UIKit MTKView subclass    |

## Requirements

- iOS 13.0+
- Swift 5.9+
- Device with Metal support (all modern devices)

## Troubleshooting

**Black screen?**

- Verify video URL is accessible
- Check video format (H.264/HEVC in MP4)

**Choppy playback?**

- Run on device, not simulator
- Check `player.state` for buffering

**Build error with XCFramework?**

- Clean build folder (Cmd+Shift+K)
- Reset package caches

## Support

- 📖 [Full Documentation](https://github.com/est-flores/muybridge-engine)
- 🐛 [Report Issues](https://github.com/est-flores/muybridge-engine/issues)
