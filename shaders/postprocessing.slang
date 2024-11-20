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
    float t;
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
    // float heat_wave_amplitude = 0.005;
    // float2 sample_pos += heat_wave_amplitude  * 
    // float2(
    //     my_noise(input.uv + 0.5 * t),
    //     my_noise(input.uv + 0.5 * t + 1.0)
    // );

    float4 target_sample = textures[color_target].Sample(samplers[sampler_idx], sample_pos);

    return target_sample;
}