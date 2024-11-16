import structs;

[[vk_binding(0, 0)]]
Texture2D textures[];

[[vk_binding(1, 0)]]
SamplerState samplers[];

struct VertexOutput {
    float4 clip_out : SV_Position;
    float2 uv;
    float4 color;
}

[[vk::push_constant]]
cbuffer push_constants {
    UniformData *u_data;
}

[shader("vertex")]
VertexOutput vertex_main(uint idx: SV_VertexID, uint inst_idx: SV_InstanceID) {
    InstanceData inst = u_data.i_data[inst_idx];
    MeshData mesh = u_data.mesh_data[inst.mesh_idx];

    VertexOutput out;

    float4 model_position = u_data.position_data[idx + mesh.position_offset];
    float4 world_position = mul(inst.world_from_model, model_position);
    out.clip_out = mul(u_data.clip_from_world, world_position);

    // out.uv = u_data.uv_data[idx + mesh.uv_offset];
    // out.uv = UVS[idx];

    out.color = float4(1.0, 1.0, 1.0, 1.0);
    if (mesh.color_offset != 0xFFFFFFFF) {
        out.color = u_data.color_data[idx + mesh.color_offset];
    }

    return out;
    
}

[shader("fragment")]
float4 fragment_main(VertexOutput input) {
    float3 periodic_color = float3(
        0.5 * cos(0.6 * u_data.time + 0.1) + 0.5,
        0.5 * sin(u_data.time) + 0.5,
        0.5 * sin(0.7 * u_data.time + 0.1) + 0.5,
    );

    float4 vtx_color = input.color;

    return vtx_color;
}