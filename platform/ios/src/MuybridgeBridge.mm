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

- (instancetype)init;
- (void)dealloc;

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

    // Set up frame callback
    __weak MuybridgePlayerHandle *weakSelf = self;
    _decoder->setFrameCallback(
        [weakSelf](CVPixelBufferRef pixelBuffer, muybridge::Timestamp pts) {
          MuybridgePlayerHandle *strongSelf = weakSelf;
          if (strongSelf) {
            @synchronized(strongSelf) {
              if (strongSelf.currentFrame) {
                CVPixelBufferRelease(strongSelf.currentFrame);
              }
              strongSelf.currentFrame = pixelBuffer;
              strongSelf.currentPts = pts;
            }
          }
        });

    MUY_LOGI("MuybridgePlayerHandle created");
  }
  return self;
}

- (void)dealloc {
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
}
