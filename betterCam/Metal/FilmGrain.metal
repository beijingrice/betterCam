#include <CoreImage/CoreImage.h>
using namespace metal;

static uint hashGrain(uint2 point) {
    uint value = point.x * 0x9e3779b1u ^ point.y * 0x85ebca77u;
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    return value ^ (value >> 16);
}

// Sparse convolution noise: every cell holds one grain at a random position with a
// random signed strength, drawn as a smooth blob of radius 1 cell. Because the blob
// never reaches past the 3x3 neighbourhood and its centre is uniform within the cell,
// the noise variance is the same everywhere. Interpolated lattice (value) noise is
// twice as strong at cell corners as at centres, which shows up as a grid on large
// captures where a cell spans many pixels.
static float smoothGrain(float2 coordinate) {
    // Matches the mean RMS of the previous value noise so the per-film amplitudes keep
    // their calibration: (26/35) / sqrt(pi/5).
    const float normalisation = 0.93716f;
    int2 cell = int2(floor(coordinate));
    float sum = 0.0f;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            int2 neighbour = cell + int2(x, y);
            uint placement = hashGrain(as_type<uint2>(neighbour));
            uint strength = hashGrain(uint2(placement, 0x632be5abu));
            float2 centre = float2(neighbour) + float2(placement & 0xffffu, placement >> 16) / 65536.0f;
            // The sum of two uniform samples gives a symmetric triangular distribution.
            float signedStrength = float((strength & 0xffffu) + (strength >> 16)) / 65535.0f - 1.0f;
            float2 delta = coordinate - centre;
            float falloff = max(0.0f, 1.0f - dot(delta, delta));
            sum += signedStrength * falloff * falloff;
        }
    }
    // Overlapping grains can exceed the ±1 range the clipping guard below assumes (rare: > 3σ).
    return clamp(sum * normalisation, -1.0f, 1.0f);
}

[[stitchable]] float4 betterCamGrain(
    coreimage::sample_t pixel, float size, float amplitude, float chroma,
    float2 offset, coreimage::destination destination
) {
    if (pixel.a <= 0.0f) { return pixel; }
    float3 rgb = coreimage::linear_to_srgb(pixel.rgb / pixel.a);
    float3 lumaWeights = float3(0.2126f, 0.7152f, 0.0722f);
    float luma = dot(rgb, lumaWeights);
    float weight = smoothstep(0.0f, 0.26f, luma) * (1.0f - smoothstep(0.45f, 1.0f, luma));

    // Each output pixel shows the grain averaged over its own footprint, which is what a
    // large capture looks like once it is shrunk to the screen. Point-sampling grains only
    // two or three pixels wide (the viewfinder) gave hard, sand-like specks instead.
    float2 centre = destination.coord() / size + offset;
    float footprint = 1.0f / size; // one output pixel, in cells
    int taps = footprint > 0.15f ? 2 : 1;
    float3 noise = float3(0.0f);
    for (int ty = 0; ty < taps; ++ty) {
        for (int tx = 0; tx < taps; ++tx) {
            float2 position = taps == 1
                ? centre
                : centre + (float2(tx, ty) - 0.5f) * 0.5f * footprint;
            float3 sample = float3(smoothGrain(position));
            if (chroma > 0.0f) {
                float3 color = float3(
                    smoothGrain(position + float2(791.0f, 719.0f)),
                    0.0f,
                    smoothGrain(position + float2(587.0f, 919.0f))
                );
                sample += (color - dot(color, lumaWeights)) * chroma;
            }
            noise += sample;
        }
    }
    noise /= float(taps * taps);

    // Scale all three channels by one factor so grain brightens or darkens a colour
    // without moving its hue. On sRGB code values this is close to a common factor in
    // linear light too. The swing is symmetric and small enough that no channel leaves
    // [0, 1], so clipping never biases the mean. A channel already above 1 means no grain.
    if (luma <= 1e-4f) { return pixel; }
    float peak = max(rgb.r, max(rgb.g, rgb.b));
    float room = peak >= 1.0f ? 0.0f : luma * min(1.0f, (1.0f - peak) / peak);
    float swing = min(amplitude * weight, room / (1.0f + 2.0f * chroma));
    float3 gain = 1.0f + noise * (swing / luma);
    return float4(coreimage::srgb_to_linear(rgb * gain) * pixel.a, pixel.a);
}
