import tex_bindings;

// Hardcoding a screen-filling triangle in clip space
static const float2 POSITIONS[] = {
    -1.0, -3.0,
    -1.0, 1.0,
    3.0, 1.0
};

static const float2 UVS[] = {
    0.0, 2.0,
    0.0, 0.0,
    2.0, 0.0
};

struct VertexOutput {
    float4 clip_pos : SV_Position;
    float2 uv;
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

}