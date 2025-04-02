import procs;
import structs;

static const float3 SKYBOX_POSITIONS[] = {
    // Front
    -1.0, -1.0, -1.0,
    1.0, -1.0, -1.0,
    -1.0, 1.0, -1.0,
    1.0, 1.0, -1.0,
    -1.0, 1.0, -1.0,
    1.0, -1.0, -1.0,

    // Left
    -1.0, -1.0, -1.0,
    -1.0, 1.0, -1.0,
    -1.0, -1.0, 1.0,
    -1.0, 1.0, -1.0,
    -1.0, 1.0, 1.0,
    -1.0, -1.0, 1.0,

    // Right
    1.0, 1.0, -1.0,
    1.0, -1.0, -1.0,
    1.0, -1.0, 1.0,
    1.0, 1.0, 1.0,
    1.0, 1.0, -1.0,
    1.0, -1.0, 1.0,

    // Back
    -1.0, 1.0, 1.0,
    1.0, 1.0, 1.0,
    -1.0, -1.0, 1.0,
    1.0, 1.0, 1.0,
    1.0, -1.0, 1.0,
    -1.0, -1.0, 1.0,

    // Bottom
    -1.0, -1.0, 1.0,
    1.0, -1.0, -1.0,
    -1.0, -1.0, -1.0,
    -1.0, -1.0, 1.0,
    1.0, -1.0, 1.0,
    1.0, -1.0, -1.0,

    // Top
    1.0, 1.0, 1.0,
    -1.0, 1.0, 1.0,
    -1.0, 1.0, -1.0,
    1.0, 1.0, 1.0,
    -1.0, 1.0, -1.0,
    1.0, 1.0, -1.0
};

struct VertexOutput {
    float4 clip_pos : SV_Position;
    float3 view_direciton;
}

[[vk::push_constant]]
cbuffer push_constants {
    UniformData *u_data;
    uint sampler_idx;
}

[shader("vertex")]
VertexOutput vertex_main(uint idx: SV_VertexID) {
    VertexOutput out;
    float3 pos = SKYBOX_POSITIONS[idx];
    out.clip_pos = mul(u_data.clip_from_skybox, float4(pos, 1.0));
    out.clip_pos.z = 0.0;

    out.view_direciton = pos;
    return out;
}

[shader("fragment")]
float4 fragment_main(VertexOutput input, uint primitive_id: SV_PrimitiveID) {
    float3 view_dir = normalize(input.view_direciton);
    
    float3 final_color = sky_color(view_dir);


    return float4(final_color, 1.0);
}