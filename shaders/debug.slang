import structs;

struct VertexOutput {
    float4 clip_pos : SV_Position;
    float4 color;
    uint instance_idx;
}

[[vk::push_constant]]
cbuffer push_constants {
    UniformData *u_data;
    uint sampler_idx;
}

[shader("vertex")]
VertexOutput vertex_main(uint idx: SV_VertexID, uint inst_idx: SV_InstanceID) {
    InstanceData inst = u_data.i_data[inst_idx];
    StaticMeshData mesh = u_data.mesh_data[inst.mesh_idx];

    VertexOutput out;

    float4 model_position = u_data.position_data[idx + mesh.position_offset];
    float4 world_position = mul(inst.world_from_model, model_position);

    out.clip_pos = mul(u_data.clip_from_world, world_position);
    out.instance_idx = inst_idx;

    return out;
}

[shader("fragment")]
float4 fragment_main(VertexOutput input, uint primitive_id: SV_PrimitiveID) {
    InstanceData inst = u_data.i_data[input.instance_idx];
    
    return inst.color;
}