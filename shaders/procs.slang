import structs;
import tex_bindings;

float3 sky_color(float3 view_dir) {
    float3 sky = (view_dir + 1.0) / 2.0;
    return sky;
}

float3 shade_sky(float3 view_dir, UniformData* u_data, uint sampler_idx) {
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

    return final_color;
}