#import "MetalVideoRenderer.h"
#import <simd/simd.h>

namespace muybridge {
namespace ios {

// Vertex structure
struct Vertex {
  simd_float2 position;
  simd_float2 texCoord;
};

// Fullscreen quad vertices
static const Vertex kQuadVertices[] = {
    {{-1.0f, -1.0f}, {0.0f, 1.0f}},
    {{1.0f, -1.0f}, {1.0f, 1.0f}},
    {{-1.0f, 1.0f}, {0.0f, 0.0f}},
    {{1.0f, 1.0f}, {1.0f, 0.0f}},
};

MetalVideoRenderer::MetalVideoRenderer()
    : device_(nil), pipelineState_(nil), vertexBuffer_(nil),
      textureCache_(nullptr) {
  MUY_LOGI("MetalVideoRenderer created");
}

MetalVideoRenderer::~MetalVideoRenderer() { release(); }

bool MetalVideoRenderer::initialize(id<MTLDevice> device) {
  if (initialized_) {
    return true;
  }

  device_ = device;
  MUY_LOGI("Initializing MetalVideoRenderer");

  // Create vertex buffer
  vertexBuffer_ = [device_ newBufferWithBytes:kQuadVertices
                                       length:sizeof(kQuadVertices)
                                      options:MTLResourceStorageModeShared];

  if (!createTextureCache()) {
    MUY_LOGE("Failed to create texture cache");
    return false;
  }

  if (!createPipeline()) {
    MUY_LOGE("Failed to create pipeline");
    return false;
  }

  initialized_ = true;
  MUY_TTFF_MILESTONE("renderer_initialized");
  return true;
}

bool MetalVideoRenderer::createTextureCache() {
  CVReturn result = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device_,
                                              nil, &textureCache_);

  if (result != kCVReturnSuccess) {
    MUY_LOGE("CVMetalTextureCacheCreate failed: %d", result);
    return false;
  }

  MUY_LOGI("Metal texture cache created");
  return true;
}

bool MetalVideoRenderer::createPipeline() {
  NSError *error = nil;

  // Load shader library
  id<MTLLibrary> library = [device_ newDefaultLibrary];
  if (!library) {
    // Try loading from bundle
    NSBundle *bundle =
        [NSBundle bundleForClass:NSClassFromString(@"MuybridgePlayer")];
    if (!bundle) {
      bundle = [NSBundle mainBundle];
    }

    NSURL *libraryURL = [bundle URLForResource:@"VideoShaders"
                                 withExtension:@"metallib"];
    if (libraryURL) {
      library = [device_ newLibraryWithURL:libraryURL error:&error];
    }
  }

  if (!library) {
    MUY_LOGE("Failed to load shader library");
    return false;
  }

  id<MTLFunction> vertexFunction = [library newFunctionWithName:@"videoVertex"];
  id<MTLFunction> fragmentFunction =
      [library newFunctionWithName:@"videoFragment"];

  if (!vertexFunction || !fragmentFunction) {
    MUY_LOGE("Failed to load shader functions");
    return false;
  }

  // Create pipeline descriptor
  MTLRenderPipelineDescriptor *descriptor =
      [[MTLRenderPipelineDescriptor alloc] init];
  descriptor.vertexFunction = vertexFunction;
  descriptor.fragmentFunction = fragmentFunction;
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

  pipelineState_ = [device_ newRenderPipelineStateWithDescriptor:descriptor
                                                           error:&error];
  if (error) {
    MUY_LOGE("Failed to create pipeline: %s",
             [error.localizedDescription UTF8String]);
    return false;
  }

  MUY_LOGI("Metal pipeline created");
  return true;
}

void MetalVideoRenderer::setViewport(int width, int height) {
  viewportWidth_ = width;
  viewportHeight_ = height;
  MUY_LOGD("Viewport set: %dx%d", width, height);
}

void MetalVideoRenderer::render(CVPixelBufferRef pixelBuffer,
                                id<CAMetalDrawable> drawable,
                                id<MTLCommandBuffer> commandBuffer) {
  if (!initialized_ || !pixelBuffer) {
    return;
  }

  @autoreleasepool {
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);

    // Create Y texture (luma)
    CVMetalTextureRef yTextureRef = nullptr;
    CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, textureCache_, pixelBuffer, nil,
        MTLPixelFormatR8Unorm, width, height,
        0, // Y plane
        &yTextureRef);

    if (result != kCVReturnSuccess) {
      MUY_LOGE("Failed to create Y texture: %d", result);
      return;
    }

    // Create CbCr texture (chroma)
    CVMetalTextureRef cbcrTextureRef = nullptr;
    result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, textureCache_, pixelBuffer, nil,
        MTLPixelFormatRG8Unorm, width / 2, height / 2,
        1, // CbCr plane
        &cbcrTextureRef);

    if (result != kCVReturnSuccess) {
      CFRelease(yTextureRef);
      MUY_LOGE("Failed to create CbCr texture: %d", result);
      return;
    }

    id<MTLTexture> yTexture = CVMetalTextureGetTexture(yTextureRef);
    id<MTLTexture> cbcrTexture = CVMetalTextureGetTexture(cbcrTextureRef);

    // Create render pass
    MTLRenderPassDescriptor *passDescriptor =
        [MTLRenderPassDescriptor renderPassDescriptor];
    passDescriptor.colorAttachments[0].texture = drawable.texture;
    passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDescriptor.colorAttachments[0].clearColor =
        MTLClearColorMake(0, 0, 0, 1);

    id<MTLRenderCommandEncoder> encoder =
        [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];

    [encoder setViewport:(MTLViewport){0, 0, (double)viewportWidth_,
                                       (double)viewportHeight_, 0, 1}];
    [encoder setRenderPipelineState:pipelineState_];
    [encoder setVertexBuffer:vertexBuffer_ offset:0 atIndex:0];
    [encoder setFragmentTexture:yTexture atIndex:0];
    [encoder setFragmentTexture:cbcrTexture atIndex:1];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4];
    [encoder endEncoding];

    CFRelease(yTextureRef);
    CFRelease(cbcrTextureRef);
  }
}

void MetalVideoRenderer::release() {
  if (!initialized_) {
    return;
  }

  if (textureCache_) {
    CVMetalTextureCacheFlush(textureCache_, 0);
    CFRelease(textureCache_);
    textureCache_ = nullptr;
  }

  pipelineState_ = nil;
  vertexBuffer_ = nil;
  device_ = nil;

  initialized_ = false;
  MUY_LOGI("Renderer released");
}

} // namespace ios
} // namespace muybridge
