//
//  Histogram.metal
//  betterCam
//
//  Created by Rice on 2026/2/5.
//

#include <metal_stdlib>
using namespace metal;
kernel void histKernel(texture2d<float, access::read> inTexture [[texture(0)]],
                              device uint *histogramBuffer [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= inTexture.get_width() || gid.y >= inTexture.get_height()) return;
    
    float4 color = inTexture.read(gid);
    // 计算亮度 (Luma)
    float luminance = dot(color.rgb, float3(0.299, 0.587, 0.114));
    uint bin = uint(clamp(luminance * 255.0, 0.0, 255.0));
    
    // 原子加法统计
    atomic_fetch_add_explicit((device atomic_uint*)&histogramBuffer[bin], 1, memory_order_relaxed);
}
