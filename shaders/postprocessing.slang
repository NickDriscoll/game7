import structs;
import tex_bindings;

// Hardcoding a screen-filling triangle in clip space
static const float2 POSITIONS[] = {
    -1.0, -3.0,         // Top Left
    -1.0, 1.0,          // Botton Left
    3.0, 1.0            // Bottom Right
};
static const float2 UVS[] = {
    0.0, -1.0,
    0.0, 1.0,
    2.0, 1.0
};

struct VertexOutput {
    float4 clip_pos : SV_Position;
    float2 uv;
}

[[vk::push_constant]]
cbuffer push_constants {
    uint color_target;
    uint sampler_idx;
    UniformData *u_data;
}

float2 hash(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float my_noise(float2 p) {
    const float K1 = 0.366025404; // (sqrt(3)-1)/2;
    const float K2 = 0.211324865; // (3-sqrt(3))/6;
    float2 i = floor(p + (p.x + p.y) * K1);
    float2 a = p - i + (i.x + i.y) * K2;
    float2 o = (a.x > a.y) ? float2(1.0, 0.0) : float2(0.0, 1.0); // vec2 of = 0.5 + 0.5*vec2(sign(a.x-a.y), sign(a.y-a.x));
    float2 b = a - o + K2;
    float2 c = a - 1.0 + 2.0 * K2;
    float3 h = max(0.5 - float3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
    float3 n = h * h * h * h * float3(dot(a, hash(i + 0.0)), dot(b, hash(i + o)), dot(c, hash(i + 1.0)));
    return dot(n, float3(70.0));
}








//
// PUBLIC DOMAIN CRT STYLED SCAN-LINE SHADER
//
//   by Timothy Lottes
//
// This is more along the style of a really good CGA arcade monitor.
// With RGB inputs instead of NTSC.
// The shadow mask example has the mask rotated 90 degrees for less chromatic aberration.
//
// Left it unoptimized to show the theory behind the algorithm.
//
// It is an example what I personally would want as a display option for pixel art games.
// Please take and use, change, or whatever.
//

// Emulated input resolution.
#if 1
  // Fix resolution to set amount.
#define res (float2(640.0 / 1.0, 480.0 / 1.0))
#else
// Optimize for resize.
float2 iResolution = { 320 / 160 };
#define res (iResolution.xy / 6.0)
#endif

// Hardness of scanline.
//  -8.0 = soft
// -16.0 = medium
static const float hardScan = -8.0;

// Hardness of pixels in scanline.
// -2.0 = soft
// -4.0 = hard
static const float hardPix = -3.0;

// Display warp.
// 0.0 = none
// 1.0/8.0 = extreme
static const float2 warp = float2(1.0 / 32.0, 1.0 / 24.0);

// Amount of shadow mask.
static const float maskDark = 0.5;
static const float maskLight = 1.5;

//------------------------------------------------------------------------

// Nearest emulated sample given floating point position and texel offset.
// Also zero's off screen.
float3 Fetch(float2 pos, float2 off) {
    pos = floor(pos * res + off) / res;
    if (max(abs(pos.x - 0.5), abs(pos.y - 0.5)) > 0.5) return float3(0.0, 0.0, 0.0);
    return textures[color_target].Sample(samplers[sampler_idx], pos.xy).rgb;
    //return texture(iChannel0, pos.xy, -16.0).rgb;
}

// Distance in emulated pixels to nearest texel.
float2 Dist(float2 pos) { pos = pos * res; return -((pos - floor(pos)) - float2(0.5));}

// 1D Gaussian.
float Gaus(float pos, float scale) { return exp2(scale * pos * pos);}

// 3-tap Gaussian filter along horz line.
float3 Horz3(float2 pos, float off) {
    float3 b = Fetch(pos, float2(-1.0, off));
    float3 c = Fetch(pos, float2(0.0, off));
    float3 d = Fetch(pos, float2(1.0, off));
    float dst = Dist(pos).x;
    // Convert distance to weight.
    float scale = hardPix;
    float wb = Gaus(dst - 1.0, scale);
    float wc = Gaus(dst + 0.0, scale);
    float wd = Gaus(dst + 1.0, scale);
    // Return filtered sample.
    return (b * wb + c * wc + d * wd) / (wb + wc + wd);
}

// 5-tap Gaussian filter along horz line.
float3 Horz5(float2 pos, float off) {
    float3 a = Fetch(pos, float2(-2.0, off));
    float3 b = Fetch(pos, float2(-1.0, off));
    float3 c = Fetch(pos, float2(0.0, off));
    float3 d = Fetch(pos, float2(1.0, off));
    float3 e = Fetch(pos, float2(2.0, off));
    float dst = Dist(pos).x;
    // Convert distance to weight.
    float scale = hardPix;
    float wa = Gaus(dst - 2.0, scale);
    float wb = Gaus(dst - 1.0, scale);
    float wc = Gaus(dst + 0.0, scale);
    float wd = Gaus(dst + 1.0, scale);
    float we = Gaus(dst + 2.0, scale);
    // Return filtered sample.
    return (a * wa + b * wb + c * wc + d * wd + e * we) / (wa + wb + wc + wd + we);
}

// Return scanline weight.
float Scan(float2 pos, float off) {
    float dst = Dist(pos).y;
    return Gaus(dst + off, hardScan);
}
    
// Allow nearest three lines to effect pixel.
float3 Tri(float2 pos) {
    float3 a = Horz3(pos, -1.0);
    float3 b = Horz5(pos, 0.0);
    float3 c = Horz3(pos, 1.0);
    float wa = Scan(pos, -1.0);
    float wb = Scan(pos, 0.0);
    float wc = Scan(pos, 1.0);
    return a * wa + b * wb + c * wc;
}

// Distortion of scanlines, and end of screen alpha.
float2 Warp(float2 pos) {
    pos = pos * 2.0 - 1.0;
    pos *= float2(1.0 + (pos.y * pos.y) * warp.x, 1.0 + (pos.x * pos.x) * warp.y);
    return pos * 0.5 + 0.5;
}

// Shadow mask.
float3 Mask(float2 pos) {
    pos.x += pos.y * 3.0;
    float3 mask = float3(maskDark, maskDark, maskDark);
    pos.x = fract(pos.x / 6.0);
    if (pos.x < 0.333) mask.r = maskLight;
    else if (pos.x < 0.666) mask.g = maskLight;
    else mask.b = maskLight;
    return mask;
}







[shader("vertex")]
VertexOutput vertex_main(uint idx: SV_VertexID) {
    VertexOutput out = {};

    out.clip_pos = float4(POSITIONS[idx], 0.0, 1.0);
    out.uv = UVS[idx];

    return out;
}

[shader("fragment")]
float4 fragment_main(VertexOutput input) {
    float2 sample_pos = input.uv;
    sample_pos += u_data.distortion_strength * 
        float2(
            my_noise(input.uv + 0.5 * u_data.time),
            my_noise(input.uv + 0.5 * u_data.time + 1.0)
        );
        
    float4 target_sample = textures[color_target].Sample(samplers[sampler_idx], sample_pos);
    if ((u_data.flags & UniformFlag.CRTShader) != 0) {
        // Extract resolution from clip_from_screen matrix
        float2 framebuffer_resolution;
        framebuffer_resolution.x = 2.0 / u_data.clip_from_screen[0][0];
        framebuffer_resolution.y = 2.0 / u_data.clip_from_screen[1][1];
        
        float2 crt_sample_pos = (framebuffer_resolution * sample_pos.xy);
        float2 pos = Warp(crt_sample_pos / framebuffer_resolution + float2(0.0, 0.0));
        float3 tri = Tri(pos);
        float3 mask = Mask(crt_sample_pos);
        float3 final = tri * mask;
        return float4(final.x, final.y, final.z, target_sample.a);
    } else {
        return target_sample;
    }
}