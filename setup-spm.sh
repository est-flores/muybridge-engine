#!/bin/bash
#===============================================================================
# setup-spm.sh - Create SPM Sources directory structure with symlinks
#===============================================================================
# Run this script after cloning to set up Swift Package Manager sources.
# The Sources/ directory is gitignored because it only contains symlinks.
#===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Creating SPM Sources directory structure..."

# Create directories
mkdir -p Sources/MuybridgeNative/core
mkdir -p Sources/MuybridgeNative/ios
mkdir -p Sources/MuybridgeNative/include/muybridge
mkdir -p Sources/MuybridgePlayer

# Link core C++ sources
ln -sf ../../../src/core/Clock.cpp Sources/MuybridgeNative/core/Clock.cpp
ln -sf ../../../src/core/AVSync.cpp Sources/MuybridgeNative/core/AVSync.cpp
ln -sf ../../../src/core/BufferPool.cpp Sources/MuybridgeNative/core/BufferPool.cpp

# Link iOS platform sources
ln -sf ../../../platform/ios/src/IOSVideoDecoder.mm Sources/MuybridgeNative/ios/IOSVideoDecoder.mm
ln -sf ../../../platform/ios/src/IOSVideoDecoder.h Sources/MuybridgeNative/ios/IOSVideoDecoder.h
ln -sf ../../../platform/ios/src/MetalVideoRenderer.mm Sources/MuybridgeNative/ios/MetalVideoRenderer.mm
ln -sf ../../../platform/ios/src/MetalVideoRenderer.h Sources/MuybridgeNative/ios/MetalVideoRenderer.h
ln -sf ../../../platform/ios/src/MuybridgeBridge.mm Sources/MuybridgeNative/ios/MuybridgeBridge.mm

# Link public headers
for f in include/muybridge/*.h; do
    ln -sf ../../../../$f Sources/MuybridgeNative/include/muybridge/$(basename $f)
done

# Link Swift sources
ln -sf ../../platform/ios/swift/MuybridgePlayer.swift Sources/MuybridgePlayer/MuybridgePlayer.swift
ln -sf ../../platform/ios/swift/MetalVideoView.swift Sources/MuybridgePlayer/MetalVideoView.swift

# Copy (not link) files that are SPM-specific
cat > Sources/MuybridgeNative/include/module.modulemap << 'EOF'
module MuybridgeNative {
    header "MuybridgeBridge.h"
    export *
}
EOF

cat > Sources/MuybridgeNative/include/MuybridgeBridge.h << 'EOF'
/**
 * @file MuybridgeBridge.h
 * @brief C API for Swift interop.
 */

#ifndef MUYBRIDGE_BRIDGE_H
#define MUYBRIDGE_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Player lifecycle
void *MuybridgeCreatePlayer(void);
void MuybridgeReleasePlayer(void *handle);

// Media loading
bool MuybridgeOpenMedia(void *handle, const char *url);

// Playback control
void MuybridgePlay(void *handle);
void MuybridgePause(void *handle);
void MuybridgeSeek(void *handle, int64_t positionNanos);

// Media info
int64_t MuybridgeGetDuration(void *handle);
int32_t MuybridgeGetVideoWidth(void *handle);
int32_t MuybridgeGetVideoHeight(void *handle);

// Rendering
bool MuybridgeInitRenderer(void *handle);
void MuybridgeSetViewport(void *handle, int32_t width, int32_t height);
void MuybridgeRender(void *handle, void *drawable, void *commandBuffer);
void MuybridgeReleaseRenderer(void *handle);
void *MuybridgeGetDevice(void *handle);

#ifdef __cplusplus
}
#endif

#endif // MUYBRIDGE_BRIDGE_H
EOF

echo "✅ SPM Sources directory created successfully!"
echo ""
echo "You can now build with:"
echo "  swift build --sdk \$(xcrun --sdk iphonesimulator --show-sdk-path) --triple arm64-apple-ios13.0-simulator"
echo ""
echo "Or add this package to your Xcode project."
