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

// JUST CALL THIS FUNCTION TO USE THE CRT FILTER! 
float3 crt_filer(Texture2D texture, SamplerState sampler, float2 sample_pos, float4x4 clip_from_screen) {
    // Extract resolution from clip_from_screen matrix
    float2 framebuffer_resolution;
    framebuffer_resolution.x = 2.0 / clip_from_screen[0][0];
    framebuffer_resolution.y = 2.0 / clip_from_screen[1][1];

    // Draw the rest of the owl (Lottes's code)
    float2 crt_sample_pos = (framebuffer_resolution * sample_pos.xy);
    float2 pos = Warp(crt_sample_pos / framebuffer_resolution + float2(0.0, 0.0));
    float3 tri = Tri(texture, sampler, pos);
    float3 mask = Mask(crt_sample_pos);
    float3 final = tri * mask;
    return final;
}





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
float3 Fetch(Texture2D texture, SamplerState sampler, float2 pos, float2 off) {
    pos = floor(pos * res + off) / res;
    if (max(abs(pos.x - 0.5), abs(pos.y - 0.5)) > 0.5) return float3(0.0, 0.0, 0.0);
    return texture.Sample(sampler, pos.xy).rgb;
    //return texture(iChannel0, pos.xy, -16.0).rgb;
}

// Distance in emulated pixels to nearest texel.
float2 Dist(float2 pos) { pos = pos * res; return -((pos - floor(pos)) - float2(0.5));}

// 1D Gaussian.
float Gaus(float pos, float scale) { return exp2(scale * pos * pos);}

// 3-tap Gaussian filter along horz line.
float3 Horz3(Texture2D texture, SamplerState sampler, float2 pos, float off) {
    float3 b = Fetch(texture, sampler, pos, float2(-1.0, off));
    float3 c = Fetch(texture, sampler, pos, float2(0.0, off));
    float3 d = Fetch(texture, sampler, pos, float2(1.0, off));
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
float3 Horz5(Texture2D texture, SamplerState sampler, float2 pos, float off) {
    float3 a = Fetch(texture, sampler, pos, float2(-2.0, off));
    float3 b = Fetch(texture, sampler, pos, float2(-1.0, off));
    float3 c = Fetch(texture, sampler, pos, float2(0.0, off));
    float3 d = Fetch(texture, sampler, pos, float2(1.0, off));
    float3 e = Fetch(texture, sampler, pos, float2(2.0, off));
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
float3 Tri(Texture2D texture, SamplerState sampler, float2 pos) {
    float3 a = Horz3(texture, sampler, pos, -1.0);
    float3 b = Horz5(texture, sampler, pos, 0.0);
    float3 c = Horz3(texture, sampler, pos, 1.0);
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
