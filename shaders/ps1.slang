import procs;
import structs;
import tex_bindings;

[[vk_binding(2, 0)]]
RaytracingAccelerationStructure scene_tlas;

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

float3 half_lambert(float3 normal, float3 light_dir, float3 light_color) {
    float r = dot(normal, light_dir);
    r = 0.5 * r + 0.5;
    return r * r * light_color;
}

float3 lambert(float3 normal, float3 light_dir, float3 light_color) {
    return light_color * max(0.0, dot(normal, light_dir));
}

float3x3 z_vector_rotate(float angle) {
    return float3x3(
        cos(angle), -sin(angle), 0.0,
        sin(angle), cos(angle), 0.0,
        0.0, 0.0, 1.0
    );
}

bool trace_shadow_ray(float3 origin, float3 direction, float length) {
    RayDesc ray;
    ray.Direction = direction;
    ray.Origin = origin;
    ray.TMin = 0.001;
    ray.TMax = length;

    RayQuery<RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH> query;
    query.TraceRayInline(
        scene_tlas,
        0,
        0xFF,
        ray
    );
    
    query.Proceed();

    return query.CommittedStatus() != COMMITTED_NOTHING;
}

[shader("vertex")]
VertexOutput vertex_main(uint idx: SV_VertexID, uint inst: SV_InstanceID, uint first_instance: SV_StartInstanceLocation) {
    uint inst_idx = inst + first_instance;
    InstanceData inst = u_data.i_data[inst_idx];
    StaticMeshData mesh = u_data.mesh_data[inst.mesh_idx];

    VertexOutput out;

    half4 model_position = u_data.position_data[idx + mesh.position_offset];
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
float4 fragment_main(VertexOutput input, uint primitive_id : SV_PrimitiveID, uint first_instance: SV_StartInstanceLocation) {
    InstanceData inst = u_data.i_data[input.instance_idx];
    MaterialData material = u_data.mat_data[inst.material_idx];

    float3 view_dir = normalize(u_data.view_position.xyz - input.world_pos);
    float3 face_normal = normalize(cross(ddy(input.world_pos), ddx(input.world_pos)));
    
    float4 vtx_color = input.color;
    
    float4 color_sample = float4(1.0, 1.0, 1.0, 1.0);
    if (material.color_texture != NULL_OFFSET) {
        color_sample = textures[material.color_texture].Sample(samplers[sampler_idx], input.uv);
    }

    // These terms represent the incoming light at a point
    float3 ambient_contribution = {};
    float3 diffuse_contribution = {};
    float3 specular_contribution = {};

    // Directional lighting
    for (uint i = 0; i < u_data.directional_light_count; ++i) {
        DirectionalLight light = u_data.directional_lights[i];
        ambient_contribution = 0.1 * light.color;

        if (trace_shadow_ray(input.world_pos, light.direction, 1000000.0)) {
            continue;
        }

        diffuse_contribution += lambert(face_normal, light.direction, light.color);

        float3 h = normalize(light.direction + view_dir);
        specular_contribution += light.color * max(0.0, pow(dot(h, face_normal), 64.0));
    }

    // Point lights
    for (uint i = 0; i < u_data.point_light_count; ++i) {
        PointLight light = u_data.point_lights[i];
        float3 direction = light.world_position - input.world_pos;
        float d = length(direction);
        direction /= d;

        if (trace_shadow_ray(input.world_pos, direction, d - 0.5)) {
            continue;
        }

        float falloff = light.intensity / (d * d);
        diffuse_contribution += falloff * lambert(face_normal, direction, light.color);

        float3 h = normalize(direction + view_dir);
        specular_contribution += falloff * light.color * max(0.0, pow(dot(h, face_normal), 64.0));
    }

    // Trying rt reflections
    float3 reflection_cont = {};
    {
        float3 ray_dir = normalize(reflect(-view_dir, face_normal));

        RayDesc ray;
        ray.Direction = ray_dir;
        ray.Origin = input.world_pos;
        ray.TMin = 0.001;
        ray.TMax = 1000000.0;

        RayQuery<RAY_FLAG_CULL_NON_OPAQUE> query;
        query.TraceRayInline(
            scene_tlas,
            0,
            0xFF,
            ray
        );

        query.Proceed();

        if (query.CommittedStatus() != COMMITTED_NOTHING) {
            uint id = query.CommittedRayInstanceId();
            InstanceData i = u_data.i_data[id];
            MaterialData mat = u_data.mat_data[i.material_idx];


            float2 uv = query.CandidateRayBarycentrics();
            float w = 1.0 - uv.x - uv.y;
            if (mat.color_texture != NULL_OFFSET) {
                reflection_cont = textures[mat.color_texture].Sample(samplers[sampler_idx], uv).rgb;
            } else {
                // reflection_cont = shade_sky(ray_dir, u_data, sampler_idx);
                reflection_cont = float3(uv.x, uv.y, w);
            }
            //reflection_cont = id_to_color(id);
        } else {
            reflection_cont = shade_sky(ray_dir, u_data, sampler_idx);
        }
    }

    // Glowing
    float3 glow = {};
    if ((inst.flags & InstanceFlags.Glowing) != 0) {
        glow = float3(0.0, 1.0, 0.0);
    }

    float3 material_albedo = vtx_color.rgb * color_sample.rgb * material.base_color.rgb;

    float3 final_color = (glow + reflection_cont + specular_contribution + diffuse_contribution + ambient_contribution) * material_albedo;

    if ((inst.flags & InstanceFlags.Highlighted) != 0) {
        float fac = smoothstep(0.5, 1.0, 1.0 - dot(face_normal, view_dir));

        final_color = lerp(final_color, float3(0.0, 0.0, 1.0), fac);
    }

    if (u_data.triangle_vis == 1) {
        final_color *= id_to_color(primitive_id);
    }

    return float4(final_color, 1.0);
    // return float4(specular_contribution, 1.0);
}