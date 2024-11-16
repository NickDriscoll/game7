import structs;

[[vk_binding(0, 0)]]
Texture2D textures[];

[[vk_binding(1, 0)]]
SamplerState samplers[];

struct VertexOutput {
    float4 clip_pos : SV_Position;
    float2 uv;
    float4 color;
    uint instance_idx;
}

[[vk::push_constant]]
cbuffer push_constants {
    UniformData *u_data;
}

static const uint NULL_OFFSET = 0xFFFFFFFF;

[shader("vertex")]
VertexOutput vertex_main(uint idx: SV_VertexID, uint inst_idx: SV_InstanceID) {
    InstanceData inst = u_data.i_data[inst_idx];
    MeshData mesh = u_data.mesh_data[inst.mesh_idx];

    VertexOutput out;

    float4 model_position = u_data.position_data[idx + mesh.position_offset];
    float4 world_position = mul(inst.world_from_model, model_position);
    out.clip_pos = mul(u_data.clip_from_world, world_position);

    // out.uv = u_data.uv_data[idx + mesh.uv_offset];
    // out.uv = UVS[idx];

    out.uv = float2(0.0);
    if (mesh.uv_offset != NULL_OFFSET) {
        out.uv = u_data.uv_data[idx + mesh.uv_offset];
    }

    out.color = float4(1.0, 1.0, 1.0, 1.0);
    if (mesh.color_offset != NULL_OFFSET) {
        out.color = u_data.color_data[idx + mesh.color_offset];
    }

    out.instance_idx = inst_idx;

    return out;
}

[shader("fragment")]
float4 fragment_main(VertexOutput input) {
    InstanceData inst = u_data.i_data[input.instance_idx];
    MaterialData material = u_data.mat_data[inst.material_idx];

    // float3 periodic_color = float3(
    //     0.5 * cos(0.6 * u_data.time + 0.1) + 0.5,
    //     0.5 * sin(u_data.time) + 0.5,
    //     0.5 * sin(0.7 * u_data.time + 0.1) + 0.5,
    // );

    float4 vtx_color = input.color;

    float4 color_sample = float4(1.0, 1.0, 1.0, 1.0);
    if (material.color_texture != NULL_OFFSET) {
        color_sample = textures[material.color_texture].Sample(samplers[material.sampler_idx], input.uv);
        //color_sample = textures[0].Sample(samplers[0], input.uv);
    }

    // if (inst.material_idx == 0) {
    //     color_sample.b = 0.0;
    // }

    return vtx_color * color_sample;
    //return float4(input.uv, 0.0, 1.0);
    //return vtx_color;
    //return float4(1.0, 0.0, 1.0, 1.0);
}