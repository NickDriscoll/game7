import procs;
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

// @TODO: This kind of sucks. Rethink the data.
static const uint NULL_OFFSET = 0xFFFFFFFF;

static const float3 ID_COLORS[] = {
    float3(0.1, 0.1, 0.1),
    float3(1.0, 0.0, 0.0),
    float3(0.0, 1.0, 0.0),
    float3(0.0, 0.0, 1.0),
    float3(0.0, 1.0, 1.0),
    float3(1.0, 0.0, 1.0),
    float3(1.0, 1.0, 0.0),
    float3(2.0, 2.0, 2.0),
};
float3 id_to_color(uint id) {
    uint r = id % 8;
    return ID_COLORS[r];
}

float3 simple_diffuse_brdf(float3 normal, float3 light_dir, float3 light_color) {
    float r = dot(normal, light_dir);
    r = 0.5 * r + 0.5;
    return r * r * light_color;
}

[shader("vertex")]
VertexOutput vertex_main(uint idx: SV_VertexID, uint inst: SV_InstanceID, uint first_instance: SV_StartInstanceLocation) {
    uint inst_idx = inst + first_instance;
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
    
    float4 vtx_color = input.color;
    
    float4 color_sample = float4(1.0, 1.0, 1.0, 1.0);
    if (material.color_texture != NULL_OFFSET) {
        color_sample = textures[material.color_texture].Sample(samplers[sampler_idx], input.uv);
    }
    
    float3 material_albedo = vtx_color.rgb * color_sample.rgb * material.base_color.rgb;

    // Directional lighting
    float3 diffuse_contribution = {};
    for (uint i = 0; i < u_data.directional_light_count; ++i) {
        DirectionalLight light = u_data.directional_lights[i];
        diffuse_contribution += simple_diffuse_brdf(face_normal, light.direction, light.color);
    }

    // Point lights
    float3 specular_contribution = {};
    for (uint i = 0; i < u_data.point_light_count; ++i) {
        PointLight light = u_data.point_lights[i];
        float3 direction = light.world_position - input.world_pos;
        float d = length(direction);
        float falloff = light.intensity / (d * d);
        diffuse_contribution += falloff * simple_diffuse_brdf(face_normal, normalize(direction), light.color);

        float3 view_dir = u_data.view_position.xyz - input.world_pos;
        float3 h = normalize(view_dir + face_normal);
        //specular_contribution += falloff * max(0.0, dot(h, direction));
    }

    // Glowing
    float3 glow = {};
    if ((inst.flags & InstanceFlags.Glowing) != 0) {
        glow = float3(0.0, 1.0, 0.0);
    }

    // if (u_data.acceleration_structure_data != nullptr) {
        // Trace one shadow ray per-pixel
        // RayDesc ray;
        // ray.Direction = SUNLIGHT;
        // ray.Origin = input.world_pos;
        // ray.TMin = 0.0;
        // ray.TMax = 1000000.0;
        //TraceRay();
    // }

    float3 final_color = (glow + specular_contribution + diffuse_contribution) * material_albedo;

    if ((inst.flags & InstanceFlags.Highlighted) != 0) {
        float3 pos_to_view = normalize(u_data.view_position.xyz - input.world_pos);
        float fac = smoothstep(0.5, 1.0, 1.0 - dot(face_normal, pos_to_view));

        final_color = lerp(final_color, float3(0.0, 0.0, 1.0), fac);
        //final_color = fac;
    }

    if (u_data.triangle_vis == 1) {
        final_color *= id_to_color(primitive_id);
    }

    return float4(final_color, 1.0);
}