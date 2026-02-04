#include <metal_stdlib>
using namespace metal;

kernel void waveformKernel(texture2d<float, access::read> inTexture [[texture(0)]],
                            texture2d<float, access::write> outTexture [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    
    uint width = inTexture.get_width();
    uint height = inTexture.get_height();
    uint outWidth = outTexture.get_width();
    uint outHeight = outTexture.get_height();

    if (gid.x >= outWidth || gid.y >= outHeight) return;

    // 💡 1. 每一帧开始时，必须清空当前像素点的背景色
    outTexture.write(float4(0.0, 0.0, 0.0, 0.0), gid);

    // 💡 2. 采样计算该列的平均亮度
    float lumaSum = 0;
    uint sampleCount = 0;
    
    for (uint y = 0; y < height; y += 4) { // 步进采样
        float4 color = inTexture.read(uint2(gid.x * (width/outWidth), y));
        
        // 使用 BT.709 标准计算亮度：Y = 0.2126R + 0.7152G + 0.0722B
        float luma = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
        lumaSum += luma;
        sampleCount++;
    }

    float lumaAvg = lumaSum / sampleCount;

    // 💡 3. 映射到纵向位置
    // 0.0 在底部，1.0 在顶部
    uint targetY = uint((1.0 - lumaAvg) * (outHeight - 1));

    // 💡 4. 渲染逻辑：只在平均亮度对应的 Y 坐标画线
    // 这里使用白色 (1,1,1) 让它看起来像一条纯粹的亮度曲线
    if (gid.y == targetY) {
        outTexture.write(float4(1.0, 1.0, 1.0, 0.9), gid);
    }
}
