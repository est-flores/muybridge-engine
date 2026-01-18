#ifndef MUYBRIDGE_METAL_VIDEO_RENDERER_H
#define MUYBRIDGE_METAL_VIDEO_RENDERER_H

/**
 * @file MetalVideoRenderer.h
 * @brief Metal renderer for video frames from CVPixelBuffer.
 */

#include "muybridge/Log.h"

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#include <atomic>
#include <mutex>

namespace muybridge {
namespace ios {

/**
 * @class MetalVideoRenderer
 * @brief Renders YCbCr video frames using Metal.
 */
class MetalVideoRenderer {
public:
  MetalVideoRenderer();
  ~MetalVideoRenderer();

  /**
   * @brief Initialize Metal resources.
   * @param device Metal device
   * @return true on success
   */
  bool initialize(id<MTLDevice> device);

  /**
   * @brief Set viewport dimensions.
   */
  void setViewport(int width, int height);

  /**
   * @brief Render pixel buffer to drawable.
   * @param pixelBuffer CVPixelBuffer in YCbCr format
   * @param drawable Current drawable to render to
   * @param commandBuffer Command buffer to encode commands
   */
  void render(CVPixelBufferRef pixelBuffer, id<CAMetalDrawable> drawable,
              id<MTLCommandBuffer> commandBuffer);

  /**
   * @brief Release Metal resources.
   */
  void release();

private:
  bool createPipeline();
  bool createTextureCache();

  // Metal objects (bridged to void* for header)
  id<MTLDevice> device_;
  id<MTLRenderPipelineState> pipelineState_;
  id<MTLBuffer> vertexBuffer_;
  CVMetalTextureCacheRef textureCache_;

  // Viewport
  int viewportWidth_ = 0;
  int viewportHeight_ = 0;

  bool initialized_ = false;
};

} // namespace ios
} // namespace muybridge

#endif // MUYBRIDGE_METAL_VIDEO_RENDERER_H
