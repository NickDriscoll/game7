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

float3x3 rotation(float theta) {
    return float3x3(
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0
    );
}

struct VertexOutput {
    float4 clip_out : SV_Position;
    float2 uv;
    float4 color;
}

[shader("vertex")]
VertexOutput vertex_main(uint idx : SV_VertexID) {
    VertexOutput out;
    float2 p = POSITIONS[idx];
    out.clip_out = float4(p.x, p.y, 1.0, 1.0);
    out.uv = float2(1.0, 1.0);
    out.color = float4(COLORS[idx], 1.0);

    return out;
}

[shader("fragment")]
float4 fragment_main(VertexOutput input) {
    return input.color;
}