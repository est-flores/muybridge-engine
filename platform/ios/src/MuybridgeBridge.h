#ifndef MUYBRIDGE_BRIDGE_H
#define MUYBRIDGE_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>
#include <CoreVideo/CoreVideo.h>

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

// Flutter plugin hooks
void MuybridgeSetFrameAvailableCallback(void *handle,
                                        void (*callback)(void *userData),
                                        void *userData);
CVPixelBufferRef MuybridgeCopyCurrentFrame(void *handle);
void *MuybridgeGetAVPlayerItem(void *handle);

#ifdef __cplusplus
}
#endif

#endif // MUYBRIDGE_BRIDGE_H
