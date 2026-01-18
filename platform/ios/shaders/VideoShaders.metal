#include <metal_stdlib>
using namespace metal;

// Vertex input
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

// Vertex output / Fragment input
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

// BT.601 YCbCr to RGB conversion matrix (for older content)
constant float3x3 kColorConversion601 = float3x3(
    float3(1.0,  1.0,     1.0),
    float3(0.0, -0.34414, 1.772),
    float3(1.402, -0.71414, 0.0)
);

/**
 * Vertex shader - passthrough for fullscreen quad
 */
vertex VertexOut videoVertex(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

/**
 * Fragment shader - YCbCr to RGB conversion
 *
 * Samples from separate Y (luma) and CbCr (chroma) textures
 * and converts to RGB using BT.709 color matrix.
 */
fragment float4 videoFragment(VertexOut in [[stage_in]],
                               texture2d<float> yTexture [[texture(0)]],
                               texture2d<float> cbcrTexture [[texture(1)]]) {
    
    constexpr sampler textureSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );
    
    // Sample Y (luma) from R channel
    float y = yTexture.sample(textureSampler, in.texCoord).r;
    
    // Sample Cb and Cr from RG channels
    float2 cbcr = cbcrTexture.sample(textureSampler, in.texCoord).rg;
    
    // Adjust for video range (16-235 for Y, 16-240 for CbCr)
    // Note: For full range, skip this adjustment
    y = (y - 16.0/255.0) * (255.0/219.0);
    cbcr = (cbcr - float2(128.0/255.0)) * (255.0/224.0);
    
    // YCbCr to RGB conversion (BT.709)
    float3 ycbcr = float3(y, cbcr.x, cbcr.y);
    float3 rgb = kColorConversion709 * ycbcr;
    
    // Clamp to valid range
    rgb = saturate(rgb);
    
    return float4(rgb, 1.0);
}
