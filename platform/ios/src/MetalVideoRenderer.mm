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

  // Inline shader source - required because SPM packages can't include precompiled metallib
  NSString *shaderSource = @R"(
    #include <metal_stdlib>
    using namespace metal;
    
    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };
    
    // BT.709 YCbCr to RGB conversion matrix
    constant float3x3 kColorConversion709 = float3x3(
        float3(1.0,  1.0,      1.0),
        float3(0.0, -0.18732, 1.8556),
        float3(1.5748, -0.46812, 0.0)
    );
    
    struct Vertex {
        float2 position;
        float2 texCoord;
    };
    
    vertex VertexOut videoVertex(const device Vertex* vertices [[buffer(0)]],
                                  uint vid [[vertex_id]]) {
        VertexOut out;
        out.position = float4(vertices[vid].position, 0.0, 1.0);
        out.texCoord = vertices[vid].texCoord;
        return out;
    }
    
    fragment float4 videoFragment(VertexOut in [[stage_in]],
                                   texture2d<float> yTexture [[texture(0)]],
                                   texture2d<float> cbcrTexture [[texture(1)]]) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
        
        float y = yTexture.sample(textureSampler, in.texCoord).r;
        float2 cbcr = cbcrTexture.sample(textureSampler, in.texCoord).rg;
        
        // Adjust for video range (16-235 for Y, 16-240 for CbCr)
        y = (y - 16.0/255.0) * (255.0/219.0);
        cbcr = (cbcr - float2(128.0/255.0)) * (255.0/224.0);
        
        float3 ycbcr = float3(y, cbcr.x, cbcr.y);
        float3 rgb = kColorConversion709 * ycbcr;
        rgb = saturate(rgb);
        
        return float4(rgb, 1.0);
    }
  )";

  // Compile shader from source
  id<MTLLibrary> library = [device_ newLibraryWithSource:shaderSource
                                                 options:nil
                                                   error:&error];
  if (!library) {
    MUY_LOGE("Failed to compile shader: %s",
             [error.localizedDescription UTF8String]);
    return false;
  }

  MUY_LOGI("Shader library compiled successfully");

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
  // Validate all required inputs
  if (!initialized_ || !pixelBuffer || !drawable || !commandBuffer) {
    return;
  }
  
  // Validate texture cache exists
  if (!textureCache_) {
    MUY_LOGE("Texture cache is null!");
    return;
  }
  
  // Validate drawable has a texture
  if (!drawable.texture) {
    return;
  }

  @autoreleasepool {
    // Flush texture cache to prevent stale textures
    CVMetalTextureCacheFlush(textureCache_, 0);
    
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);

    // Create Y texture (luma)
    CVMetalTextureRef yTextureRef = nullptr;
    CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, textureCache_, pixelBuffer, nil,
        MTLPixelFormatR8Unorm, width, height,
        0, // Y plane
        &yTextureRef);

    if (result != kCVReturnSuccess || !yTextureRef) {
      MUY_LOGE("Failed to create Y texture: %d (width=%zu, height=%zu)", result, width, height);
      return;
    }

    // Create CbCr texture (chroma)
    CVMetalTextureRef cbcrTextureRef = nullptr;
    result = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, textureCache_, pixelBuffer, nil,
        MTLPixelFormatRG8Unorm, width / 2, height / 2,
        1, // CbCr plane
        &cbcrTextureRef);

    if (result != kCVReturnSuccess || !cbcrTextureRef) {
      CFRelease(yTextureRef);
      MUY_LOGE("Failed to create CbCr texture: %d", result);
      return;
    }

    id<MTLTexture> yTexture = CVMetalTextureGetTexture(yTextureRef);
    id<MTLTexture> cbcrTexture = CVMetalTextureGetTexture(cbcrTextureRef);
    
    // Validate extracted textures
    if (!yTexture || !cbcrTexture) {
      CFRelease(yTextureRef);
      CFRelease(cbcrTextureRef);
      MUY_LOGE("Failed to get MTLTexture from CVMetalTexture");
      return;
    }

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
    
    // Validate encoder was created
    if (!encoder) {
      CFRelease(yTextureRef);
      CFRelease(cbcrTextureRef);
      MUY_LOGE("Failed to create render command encoder");
      return;
    }

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
