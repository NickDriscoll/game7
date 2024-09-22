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
    p = mul(p, rotation(t));
    // p = mul(p, rotation(t * (1.0 + 2*idx)));
    out.clip_out = float4(p.x, p.y, 1.0, 1.0);
    out.uv = UVS[idx];
    out.color = float4(COLORS[idx], 1.0);

    return out;
}

[shader("fragment")]
float4 fragment_main(VertexOutput input) {
    return float4(input.uv, 0.0, 1.0);
}