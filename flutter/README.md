# muybridge_flutter

Flutter plugin for [Muybridge Engine](https://github.com/est-flores/muybridge-engine) — hardware-accelerated video playback for iOS and Android.

- Zero-copy decode to GPU (`CVPixelBufferRef` on iOS, `SurfaceTexture` on Android)
- Designed for a sub-200 ms time-to-first-frame target
- Loading state stream for buffering indicators
- Pure renderer — no UI, no controls, no business logic

---

## Installation

Add the dependency to your `pubspec.yaml`:

```yaml
dependencies:
  muybridge_flutter:
    path: ../muybridge-engine/flutter   # local path
    # or from git:
    # git:
    #   url: https://github.com/est-flores/muybridge-engine
    #   path: flutter
```

Then fetch and install native dependencies:

```bash
flutter pub get
cd ios && pod install && cd ..
```

Android requires no extra steps — the native library is compiled via CMake automatically.

---

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:muybridge_flutter/muybridge_flutter.dart';

class VideoPage extends StatefulWidget {
  final String url;
  const VideoPage({required this.url, super.key});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> {
  final _controller = MuybridgeController();

  @override
  void initState() {
    super.initState();
    _controller.initialize()
        .then((_) => _controller.load(widget.url))
        .then((_) => _controller.play());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: StreamBuilder<MuybridgePlayerState>(
        stream: _controller.onStateChanged,
        builder: (context, snapshot) {
          final state = snapshot.data ?? MuybridgePlayerState.idle;
          return Stack(
            fit: StackFit.expand,
            children: [
              MuybridgeVideoPlayer(controller: _controller),
              if (state == MuybridgePlayerState.loading ||
                  state == MuybridgePlayerState.buffering)
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
            ],
          );
        },
      ),
    );
  }
}
```

---

## TikTok-style feed

For a vertical scroll feed where each item loads when it becomes visible:

```dart
class VideoFeedItem extends StatefulWidget {
  final String url;
  final bool isActive; // true when this item is on screen

  const VideoFeedItem({required this.url, required this.isActive, super.key});

  @override
  State<VideoFeedItem> createState() => _VideoFeedItemState();
}

class _VideoFeedItemState extends State<VideoFeedItem> {
  final _controller = MuybridgeController();
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) {
      setState(() => _initialized = true);
      _controller.load(widget.url);
    });
  }

  @override
  void didUpdateWidget(VideoFeedItem old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !old.isActive) {
      _controller.play();
    } else if (!widget.isActive && old.isActive) {
      _controller.pause();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) return const SizedBox.expand();

    return StreamBuilder<MuybridgePlayerState>(
      stream: _controller.onStateChanged,
      builder: (context, snapshot) {
        final state = snapshot.data ?? MuybridgePlayerState.idle;
        return Stack(
          fit: StackFit.expand,
          children: [
            MuybridgeVideoPlayer(controller: _controller),
            if (state == MuybridgePlayerState.loading ||
                state == MuybridgePlayerState.buffering)
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
          ],
        );
      },
    );
  }
}
```

---

## API reference

### `MuybridgeController`

| Member | Description |
|---|---|
| `int textureId` | Flutter texture ID. `-1` before `initialize()` completes. |
| `Stream<MuybridgePlayerState> onStateChanged` | Emits state changes (see below). |
| `Future<void> initialize()` | Creates the native player and registers a Flutter texture. Must be called first. |
| `Future<bool> load(String url)` | Opens the media URL. Resolves when the decoder is ready. Returns `false` on failure. |
| `void play()` | Start or resume playback. |
| `void pause()` | Pause playback. |
| `void seek(Duration position)` | Seek to position. |
| `void dispose()` | Release all native resources. Call in `State.dispose()`. |

### `MuybridgePlayerState`

| Value | When |
|---|---|
| `idle` | Player created, nothing loaded. |
| `loading` | `load()` called, decoder opening media. |
| `buffering` | Media open, buffering data before playback can start. |
| `ready` | Decoder ready; call `play()` to start. |
| `playing` | Video is playing. |
| `paused` | Playback paused. |
| `ended` | Playback reached end of stream. |
| `error` | Unrecoverable error (e.g. bad URL, unsupported format). |

### `MuybridgeVideoPlayer`

```dart
MuybridgeVideoPlayer(controller: _controller)
```

A `StatelessWidget` that wraps `Texture(textureId: controller.textureId)`. It renders nothing until `initialize()` has completed. Wrap in `AspectRatio`, `FittedBox`, or `SizedBox` for sizing.

---

## Supported formats

| Format | iOS | Android |
|---|---|---|
| H.264 (AVC) | ✅ Hardware | ✅ Hardware |
| H.265 (HEVC) | ✅ Hardware (A9+) | ✅ Hardware (API 21+) |
| MP4 container | ✅ | ✅ |
| MOV container | ✅ | ✅ |
| HLS (`.m3u8`) | ✅ | ✅ |
| Network URLs (`http/https`) | ✅ | ✅ |
| Local file URLs (`file://`) | ✅ | ✅ |

> **Tip:** For lowest time-to-first-frame on MP4/MOV files, ensure the `moov` atom is at the start of the file (`qt-faststart` / `+faststart` flag in FFmpeg). Files with `moov` at the end require an extra HTTP range request which adds ~1–2 s on mobile networks.

---

## Platform notes

### iOS

- Minimum deployment target: **iOS 13.0**
- Pixel format delivered to Flutter: `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (YCbCr 4:2:0). Flutter's Impeller renderer accepts this natively — no RGB conversion.
- The podspec compiles the Muybridge C++/Obj-C++ sources directly into your app. No pre-built binary is required.

### Android

- Minimum SDK: **21**
- Video decoded directly into Flutter's `SurfaceTexture` via `MediaCodec` — zero copies from decoder to compositor.
- The native library (`libmuybridge_android.so`) is compiled by CMake during `flutter build`.
