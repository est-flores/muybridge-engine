/**
 * @file MuybridgeBridge.mm
 * @brief Objective-C++ bridge between Swift and C++ engine.
 */

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "IOSVideoDecoder.h"
#include "MetalVideoRenderer.h"
#include "muybridge/Log.h"

/**
 * Opaque player handle for Swift
 */
@interface MuybridgePlayerHandle : NSObject

@property(nonatomic, assign) muybridge::ios::IOSVideoDecoder *decoder;
@property(nonatomic, assign) muybridge::ios::MetalVideoRenderer *renderer;
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, assign) CVPixelBufferRef currentFrame;
@property(nonatomic, assign) int64_t currentPts;

// Flutter plugin hooks — nil until set via MuybridgeSetFrameAvailableCallback
@property(nonatomic, assign) void (*frameAvailableCallback)(void *userData);
@property(nonatomic, assign) void *frameAvailableUserData;

- (instancetype)init;
- (void)dealloc;

// Returns the underlying AVPlayerItem for KVO in the Flutter plugin (network URLs only).
- (AVPlayerItem *)playerItemBridge;

@end

@implementation MuybridgePlayerHandle

- (instancetype)init {
  self = [super init];
  if (self) {
    muybridge::log::g_startTime = muybridge::log::Clock::now();

    _decoder = new muybridge::ios::IOSVideoDecoder();
    _renderer = new muybridge::ios::MetalVideoRenderer();
    _device = MTLCreateSystemDefaultDevice();
    _currentFrame = nullptr;
    _currentPts = 0;
    _frameAvailableCallback = nullptr;
    _frameAvailableUserData = nullptr;

    // Set up frame callback
    __weak MuybridgePlayerHandle *weakSelf = self;
    _decoder->setFrameCallback(
        [weakSelf](CVPixelBufferRef pixelBuffer, muybridge::Timestamp pts) {
          MuybridgePlayerHandle *strongSelf = weakSelf;
          if (strongSelf && pixelBuffer) {
            // CRITICAL: Retain the pixel buffer before storing!
            // The decoder will release it after this callback returns.
            CVPixelBufferRetain(pixelBuffer);

            @synchronized(strongSelf) {
              if (strongSelf.currentFrame) {
                CVPixelBufferRelease(strongSelf.currentFrame);
              }
              strongSelf.currentFrame = pixelBuffer;
              strongSelf.currentPts = pts;

              // Notify Flutter plugin that a new frame is ready.
              if (strongSelf.frameAvailableCallback) {
                strongSelf.frameAvailableCallback(strongSelf.frameAvailableUserData);
              }
            }
          }
        });

    MUY_LOGI("MuybridgePlayerHandle created");
  }
  return self;
}

- (void)dealloc {
  // Balance the Unmanaged.passRetained() call made when the Swift plugin
  // registered the frame-available callback. Without this release the
  // FrameCallbackContext object leaks on every player dispose cycle.
  if (_frameAvailableUserData) {
    CFRelease(_frameAvailableUserData);
    _frameAvailableUserData = nullptr;
  }

  if (_currentFrame) {
    CVPixelBufferRelease(_currentFrame);
    _currentFrame = nullptr;
  }

  if (_renderer) {
    _renderer->release();
    delete _renderer;
    _renderer = nullptr;
  }

  if (_decoder) {
    _decoder->release();
    delete _decoder;
    _decoder = nullptr;
  }

  MUY_LOGI("MuybridgePlayerHandle released");
}

- (AVPlayerItem *)playerItemBridge {
  if (_decoder) {
    void *item = _decoder->getAVPlayerItem();
    if (item) return (__bridge AVPlayerItem *)item;
  }
  return nil;
}

@end

// C functions exposed to Swift via bridging header

extern "C" {

void *MuybridgeCreatePlayer(void) {
  return (__bridge_retained void *)[[MuybridgePlayerHandle alloc] init];
}

void MuybridgeReleasePlayer(void *handle) {
  if (handle) {
    MuybridgePlayerHandle *player =
        (__bridge_transfer MuybridgePlayerHandle *)handle;
    player = nil; // ARC will dealloc
  }
}

bool MuybridgeOpenMedia(void *handle, const char *url) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  return player.decoder->open(std::string(url));
}

void MuybridgePlay(void *handle) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  player.decoder->start();
}

void MuybridgePause(void *handle) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  player.decoder->stop();
}

void MuybridgeSeek(void *handle, int64_t positionNanos) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  player.decoder->seek(positionNanos);
}

int64_t MuybridgeGetDuration(void *handle) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  return player.decoder->getMediaInfo().durationNanos;
}

int32_t MuybridgeGetVideoWidth(void *handle) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  return player.decoder->getMediaInfo().videoWidth;
}

int32_t MuybridgeGetVideoHeight(void *handle) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  return player.decoder->getMediaInfo().videoHeight;
}

bool MuybridgeInitRenderer(void *handle) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  return player.renderer->initialize(player.device);
}

void MuybridgeSetViewport(void *handle, int width, int height) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  player.renderer->setViewport(width, height);
}

void MuybridgeRender(void *handle, void *drawable, void *commandBuffer) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;

  CVPixelBufferRef frame = nullptr;
  @synchronized(player) {
    frame = player.currentFrame;
    if (frame) {
      CVPixelBufferRetain(frame);
    }
  }

  if (frame) {
    player.renderer->render(frame, (__bridge id<CAMetalDrawable>)drawable,
                            (__bridge id<MTLCommandBuffer>)commandBuffer);
    CVPixelBufferRelease(frame);
  }
}

void MuybridgeReleaseRenderer(void *handle) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  player.renderer->release();
}

void *MuybridgeGetDevice(void *handle) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  return (__bridge void *)player.device;
}

void MuybridgeSetFrameAvailableCallback(void *handle,
                                        void (*callback)(void *userData),
                                        void *userData) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  player.frameAvailableCallback = callback;
  player.frameAvailableUserData = userData;
}

CVPixelBufferRef MuybridgeCopyCurrentFrame(void *handle) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  CVPixelBufferRef frame = nullptr;
  @synchronized(player) {
    frame = player.currentFrame;
    if (frame) CVPixelBufferRetain(frame);
  }
  return frame;
}

void *MuybridgeGetAVPlayerItem(void *handle) {
  MuybridgePlayerHandle *player = (__bridge MuybridgePlayerHandle *)handle;
  AVPlayerItem *item = [player playerItemBridge];
  return item ? (__bridge void *)item : nullptr;
}
}
