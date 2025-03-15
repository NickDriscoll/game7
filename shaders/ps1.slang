import structs;
import tex_bindings;

struct VertexOutput {
    float4 clip_pos : SV_Position;
    float3 world_pos;
    float2 uv;
    float4 color;
    uint instance_idx;
}

[[vk::push_constant]]
cbuffer push_constants {
    UniformData *u_data;
    uint sampler_idx;
}

static const float3 SUNLIGHT = normalize(float3(-1.0, 1.0, 1.0));

// @TODO: This kind of sucks. Rethink the data.
static const uint NULL_OFFSET = 0xFFFFFFFF;

float3 id_to_color(uint id) {
    uint r = id % 6;

    float3 color;
    switch (r) {
    case 0: {
        color = float3(1.0, 0.0, 0.0);
        break;
    }
    case 1: {
        color = float3(0.0, 1.0, 0.0);
        break;
    }
    case 2: {
        color = float3(0.0, 0.0, 1.0);
        break;
    }
    case 3: {
        color = float3(0.0, 1.0, 1.0);
        break;
    }
    case 4: {
        color = float3(1.0, 0.0, 1.0);
        break;
    }
    case 5: {
        color = float3(1.0, 1.0, 0.0);
        break;
    }
    }

    return color;
}

[shader("vertex")]
VertexOutput vertex_main(uint idx: SV_VertexID, uint inst_idx: SV_InstanceID) {
    InstanceData inst = u_data.i_data[inst_idx];
    StaticMeshData mesh = u_data.mesh_data[inst.mesh_idx];

    VertexOutput out;

    float4 model_position = u_data.position_data[idx + mesh.position_offset];
    float4 world_position = mul(inst.world_from_model, model_position);

    out.world_pos = world_position.xyz;
    out.clip_pos = mul(u_data.clip_from_world, world_position);

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
float4 fragment_main(VertexOutput input, uint primitive_id : SV_PrimitiveID) {
    InstanceData inst = u_data.i_data[input.instance_idx];
    MaterialData material = u_data.mat_data[inst.material_idx];

    float3 face_normal = normalize(cross(ddy(input.world_pos), ddx(input.world_pos)));
    float diffuse_contribution = dot(normalize(face_normal), SUNLIGHT);
    
    // Half lambert
    diffuse_contribution = 0.5 * diffuse_contribution + 0.5;
    diffuse_contribution *= diffuse_contribution;
    diffuse_contribution = max(0.05, diffuse_contribution);

    float4 vtx_color = input.color;

    float4 color_sample = float4(1.0, 1.0, 1.0, 1.0);
    if (material.color_texture != NULL_OFFSET) {
        color_sample = textures[material.color_texture].Sample(samplers[sampler_idx], input.uv);
    }

    float3 final_color = diffuse_contribution * vtx_color.rgb * color_sample.rgb * material.base_color.rgb;
    if (u_data.triangle_vis == 1) {
        final_color *= id_to_color(primitive_id);
    }

    return float4(final_color, 1.0);
}