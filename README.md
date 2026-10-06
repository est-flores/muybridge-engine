# Muybridge Engine

Muybridge Engine is a hardware-accelerated video playback engine for mobile.
It has four parts:

- **C++17 core**: an A/V sync clock, a buffer pool and a playback state machine.
- **iOS layer**: VideoToolbox decode, Metal rendering via
  CVMetalTextureCache, and a Swift API.
- **Android layer**: MediaCodec decode, OpenGL ES 3.0 rendering via
  SurfaceTexture, and a Kotlin API.
- **Flutter plugin**: exposes the iOS and Android layers to Flutter apps.

## Status

This is a research project. It has never been used in production.

The engine is designed for a sub-200 ms time-to-first-frame (TTFF) target; the
example apps log TTFF against it. The repository contains no recorded TTFF
measurements.

## What the code does

- **Decode straight to the GPU.** On iOS, decoded `CVPixelBuffer`s become Metal
  textures through `CVMetalTextureCache`. On Android, MediaCodec decodes into a
  `SurfaceTexture` that OpenGL ES samples as an external texture.
- **iOS decode paths.** Local files are read with `AVAssetReader`; network URLs
  play through `AVPlayer` with `AVPlayerItemVideoOutput`. Both decode in
  hardware through VideoToolbox.
- **Android audio.** Audio is decoded with MediaCodec and played through AAudio.
  Video frames are timed against the audio timestamps.
- **Sync calculator.** The core `AVSync` class decides whether to present,
  wait for, drop or repeat a frame, using a ±16 ms tolerance window.
- **TTFF instrumentation.** `MUY_TTFF_MILESTONE` logs timestamped milestones
  from open to first frame, and `TTFFTracker` reports the breakdown.

## Project Structure

```
muybridge-engine/
├── CMakeLists.txt           # Root build configuration
├── Package.swift            # Swift Package Manager manifest
├── include/muybridge/
│   ├── IEngine.h            # Pure virtual interface
│   ├── State.h              # State machine enumeration
│   ├── Clock.h              # A/V sync clock
│   ├── AVSync.h             # Sync calculator
│   ├── BufferPool.h         # Memory management
│   ├── TTFFTracker.h        # Time-to-first-frame tracking
│   ├── SyncValidator.h      # A/V sync statistics and reporting
│   └── Log.h                # Structured logging
├── src/core/
│   ├── Clock.cpp
│   ├── AVSync.cpp
│   └── BufferPool.cpp
├── platform/
│   ├── android/             # MediaCodec + OpenGL ES 3.0, Kotlin API
│   └── ios/                 # VideoToolbox + Metal, Swift API
├── flutter/                 # Flutter plugin
├── examples/                # Android and iOS example code
└── docs/
    ├── API_USAGE.md
    ├── ANDROID_INTEGRATION.md
    ├── IOS_INTEGRATION.md
    └── threading_architecture.md
```

## Building

```bash
# macOS/Linux development build
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Debug
cmake --build . -j$(nproc)
```

## Requirements

- CMake 3.16+
- C++17 compatible compiler
- Clang 10+ or GCC 9+

## License

Copyright Formula Systems, LLC. All rights reserved. The source is published for reference; no license to use, copy or distribute it is granted.
