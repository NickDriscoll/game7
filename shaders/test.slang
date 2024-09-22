static const float2 POSITIONS[] = {
    -0.5, -0.5,         // Top left
    -0.5, 0.5,          // Bottom left
    0.5, -0.5,          // Top right
    0.5, 0.5,           // Bottom right
};

static const float3 COLORS[] = {
    1.0, 0.0, 0.0,
    0.0, 1.0, 0.0,
    0.0, 0.0, 1.0,
    0.0, 1.0, 1.0,
    // 1.0, 0.0, 0.0,
    // 1.0, 0.0, 0.0
};

static const float2 UVS[] = {
    0.0, 0.0,
    0.0, 1.0,
    1.0, 0.0,
    1.0, 1.0
};

[[vk_binding(0, 0)]]
Texture2D textures[];

[[vk_binding(1, 0)]]
SamplerState samplers[];

float2x2 rotation(float theta) {
    return float2x2(
        cos(theta), -sin(theta),
        sin(theta), cos(theta),
    );
}

float2 hash(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float noise(float2 p) {
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

struct VertexOutput {
    float4 clip_out : SV_Position;
    float2 uv;
    float4 color;
}

[[vk::push_constant]]
cbuffer push_constants {
    float t;
}

[shader("vertex")]
VertexOutput vertex_main(uint idx : SV_VertexID) {
    VertexOutput out;
    float2 p = POSITIONS[idx];

    //p = mul(p, rotation(t));

    float wiggle_dampening = 0.1;
    float2 wiggle_freq = float2(0.75, 0.5);
    p += wiggle_dampening * noise(wiggle_freq * t + p);

    // p = mul(p, rotation(t * (1.0 + 2*idx)));
    out.clip_out = float4(p.x, p.y, 1.0, 1.0);
    out.uv = UVS[idx];
    out.color = float4(COLORS[idx], 1.0);

    return out;
}

[shader("fragment")]
float4 fragment_main(VertexOutput input) {
    float2 uv = input.uv;
    float4 sample = textures[2].Sample(samplers[0], uv);
    //uv.y = 1.0 - uv.y;
    //return float4(uv, 0.0, 1.0);
    return sample;
}