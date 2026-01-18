# Muybridge Engine

A production-grade, hardware-accelerated video engine for mobile devices
(Android/iOS).

## Features

- **Sub-200ms TTFF** - Fast Time-to-First-Frame startup
- **Zero-copy architecture** - Hardware decode → GPU texture path
- **Battery efficient** - Maximizes hardware acceleration
- **Audio-master sync** - ±16ms A/V synchronization tolerance

## Project Structure

```
muybridge-engine/
├── CMakeLists.txt           # Root build configuration
├── include/muybridge/
│   ├── IEngine.h            # Pure virtual interface
│   ├── State.h              # State machine enumeration
│   ├── Clock.h              # A/V sync clock
│   ├── AVSync.h             # Sync calculator
│   ├── BufferPool.h         # Memory management
│   └── Log.h                # Structured logging
├── src/core/
│   ├── Clock.cpp
│   ├── AVSync.cpp
│   └── BufferPool.cpp
├── platform/
│   ├── android/             # Phase 2
│   └── ios/                 # Phase 3
└── docs/
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

Proprietary - All rights reserved.
