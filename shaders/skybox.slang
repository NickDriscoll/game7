import procs;
import structs;
import tex_bindings;

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
    float3 pos = INWARD_FACING_CUBE[idx];
    out.clip_pos = mul(u_data.clip_from_skybox, float4(pos, 1.0));
    out.clip_pos.z = 0.0;

    out.view_direciton = pos;
    return out;
}

[shader("fragment")]
float4 fragment_main(VertexOutput input, uint primitive_id: SV_PrimitiveID) {
    float3 view_dir = normalize(input.view_direciton);

    // Note the swizzling of the view_dir
    float3 skybox_sample = cubemaps[u_data.skybox_idx].Sample(samplers[sampler_idx], view_dir.xzy).rgb;

    // float3 final_color = sky_color(view_dir);
    float3 final_color = skybox_sample;

    float3 suns = {};
    for (int i = 0; i < u_data.directional_light_count; ++i) {
        DirectionalLight light = u_data.directional_lights[i];
        suns += light.color * smoothstep(0.995, 1.0, max(0.0, dot(view_dir, light.direction)));
    }
    final_color += suns;

    return float4(final_color, 1.0);
}