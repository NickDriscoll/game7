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
    float t;
    UniformData *u_data;
}

[shader("vertex")]
VertexOutput vertex_main(uint idx: SV_VertexID, uint inst_idx: SV_InstanceID) {
    InstanceData inst = u_data.i_data[inst_idx];
    MeshData mesh = u_data.m_data[inst.mesh_idx];

    VertexOutput out;
    float4 p = u_data.position_data[idx + mesh.position_offset];

    out.clip_out = mul(u_data.clip_from_world, p);
    // out.uv = u_data.uv_data[idx + mesh.uv_offset];
    // out.uv = UVS[idx];
    // out.color = float4(COLORS[idx], 1.0);
    out.color = float4(1.0, 1.0, 1.0, 1.0);

    return out;
    
}

[shader("fragment")]
float4 fragment_main(VertexOutput input) {
    return float4(1.0, 0.0, 0.0, 1.0);
}