import structs;

// static const float3 SKYBOX_POSITIONS[] = {
//     // Back
//     -1.0, 1.0, 1.0,
//     -1.0, 1.0, -1.0,
//     1.0, 1.0, -1.0,

//     1.0, 1.0, 1.0,
//     -1.0, 1.0, 1.0,
//     1.0, 1.0, -1.0,

//     // Right

//     // Front
//     -1.0, -1.0, 1.0,
//     1.0, -1.0, -1.0,
//     -1.0, -1.0, -1.0,

//     1.0, -1.0, 1.0,
//     1.0, -1.0, -1.0,
//     -1.0, -1.0, 1.0,

//     // Left

//     // Top

//     // Down
// };

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
    // float3x3 world_mat = (float3x3)u_data.clip_from_world;
    // float3 pos = mul(world_mat, SKYBOX_POSITIONS[idx]);
    float3 pos = SKYBOX_POSITIONS[idx];
    out.clip_pos = mul(u_data.clip_from_skybox, float4(pos, 1.0));
    out.clip_pos.z = 0.0;

    out.view_direciton = pos;
    return out;
}

[shader("fragment")]
float4 fragment_main(VertexOutput input, uint primitive_id: SV_PrimitiveID) {
    float3 view_dir = normalize(input.view_direciton);
    // float fac = max(dot(view_dir, float3(0.0, 0.0, 1.0)), 0.0);
    // return float4(0.0, 0.0, fac, 1.0);
    return float4((view_dir + 1.0) / 2.0, 1.0);
    // return float4(0.0, 0.4, 1.0, 1.0);
}