import crt;
import procs;
import rt_bindings;
import structs;
import tex_bindings;

float2 hash(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float my_noise(float2 p) {
    const float K1 = 0.366025404; // (sqrt(3)-1)/2;
    const float K2 = 0.211324865; // (3-sqrt(3))/6;
    float2 i = floor(p + (p.x + p.y) * K1);
    float2 a = p - i + (i.x + i.y) * K2;
    float2 o = (a.x > a.y) ? float2(1.0, 0.0) : float2(0.0, 1.0); // vec2 of = 0.5 + 0.5*vec2(sign(a.x-a.y), sign(a.y-a.x));
    float2 b = a - o + K2;
    float2 c = a - 1.0 + 2.0 * K2;
    float3 h = max(0.5 - float3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
    float3 n = h * h * h * h * float3(dot(a, hash(i + 0.0)), dot(b, hash(i + o)), dot(c, hash(i + 1.0)));
    return dot(n, float3(70.0));
}







// mu is the cosine of angle between view and light directions i.e. dot(view_dir, light_dir)
float rayleigh_phase_func(float mu)
{
    return
            3.0 * (1.0 + mu * mu)
    / //------------------------
           (16.0 * PI);
}

// Henyey-Greenstein phase function factor [-1, 1]
// represents the average cosine of the scattered directions
// 0 is isotropic scattering
// > 1 is forward scattering, < 1 is backwards
// mu is the cosine of angle between view and light directions i.e. dot(view_dir, light_dir)
static const float g = 0.76;
float henyey_greenstein_phase_func(float mu)
{
    return
                        (1.0 - g * g)
    / //---------------------------------------------
           ((4.0 * PI) * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
}

// scattering coefficients at sea level (m)
static const float3 betaR = float3(5.5e-6, 13.0e-6, 22.4e-6); // Rayleigh
static const float3 betaM = float3(21e-6);                    // Mie

// scale height (m)
// thickness of the atmosphere if its density were uniform
static const float hR = 7994.0; // Rayleigh
static const float hM = 1200.0; // Mie

float3 integrate_atmospheric_scattering(Ray ray, float3 frag_pos, UniformData* u_data) {
    const int num_samples = 8 * u_data.fog_step_multiple;

    DirectionalLight light = u_data.directional_lights[0];
    float3 sun_direction = light.direction;
    float3 sun_color = light.color;

    // cosine of angle between view and light directions
    float mu = dot(-ray.direction, -sun_direction);

    // Rayleigh and Mie phase functions
    // A black box indicating how light is interacting with the material
    // Similar to BRDF except
    // * it usually considers a single angle
    //   (the phase angle between 2 directions)
    // * integrates to 1 over the entire sphere of directions
    float phaseR = rayleigh_phase_func(mu);
    float phaseM = henyey_greenstein_phase_func(mu);

    // optical depth (or "average density")
    // represents the accumulated extinction coefficients
    // along the path, multiplied by the length of that path
    float optical_depthR = 0.0;
    float optical_depthM = 0.0;

    // What are we summing?
    float3 sumR = float3(0.0);
    float3 sumM = float3(0.0);

    float pixel_depth = distance(u_data.view_position.xyz, frag_pos);
    float march_step = min(pixel_depth, u_data.fog_max_depth) / float(num_samples);
    //float march_step = pixel_depth / float(num_samples);

    // static const float HEIGHT_OFFSET = 100.0;
    static const float HEIGHT_OFFSET = 0.0;

    int shadow_hits = 0;
    for (int i = 0; i < num_samples; i++) {
        float3 s = ray.origin + ray.direction * ((float(i) + 0.1) * march_step);
        // float height = length(s) + HEIGHT_OFFSET;
        // float height = s.z;
        float height = distance(s, {});

        // integrate the height scale
        // float hr = exp(-height / hR) * march_step;
        // float hm = exp(-height / hM) * march_step;
        float d = distance(s, ray.origin);
        float hr = d * march_step;
        float hm = d * march_step;
        optical_depthR += hr;
        optical_depthM += hm;

        // Ray from sample point to light
        Ray light_ray = {
            s,
            sun_direction
        };

    #if defined(HardwareRT)
            // Skip integrating this sample if we're in shadow
            if (trace_shadow_ray(tlases[tlas_idx], light_ray, 1000000.0)) {
                continue;
            }
    #endif

        // gather the sunlight
        float optical_depth_lightR = 0.0;
        float optical_depth_lightM = 0.0;
        {
            const int num_samples2 = 8;
            // float t0, t1;
            // isect_sphere(light_ray, atmosphere, t0, t1);
    
            // float march_step2 = t1 / float(num_samples);
            float march_step2 = 0.8;

            for (int j = 0; j < num_samples2; j++) {
                float3 s2 = light_ray.origin + light_ray.direction * ((float(j) + 0.1) * march_step2);

                // float height2 = distance(s2, {});
                // optical_depth_lightR += exp(-height2 / hR) * march_step2;
                // optical_depth_lightM += exp(-height2 / hM) * march_step2;
                float d2 = distance(light_ray.origin, s2);
                optical_depth_lightR += d2 * march_step2;
                optical_depth_lightM += d2 * march_step2;
            }
        }

        {
            float3 tau =
                betaR * (optical_depthR + optical_depth_lightR) +
                betaM * 1.1 * (optical_depthM + optical_depth_lightM);
            float3 transmittance = exp(-tau);

            sumR += hr * transmittance;
            sumM += hm * transmittance;
        }
    }

    // float fudge = 2000.0;  // This factor exists bc this proc was ripped out of a physically-based renderer
    float3 rayleigh_contribution = sumR * phaseR * betaR;
    //float3 rayleigh_contribution = {};
    float3 mie_contribution = sumM * phaseM * betaM;
    //float3 mie_contribution = {};
    float3 fogged_color = u_data.fog_fudge * sun_color * (rayleigh_contribution + mie_contribution);
    // return lerp(fogged_color, sun_direction, float(shadow_hits) / float(num_samples));
    return fogged_color;
}

// Returns the world space position of the fragment identified
// by its depth value and position in UV space
float3 perspective_frag_depth_to_world_pos(float depth_sample, float2 uv, UniformData *u_data) {
    float z_ndc = depth_sample;
    float4 p_ndc = float4(uv * 2.0 - 1.0, z_ndc, 1.0);
    float3 world_pos = perspective_ndc_to_world(p_ndc, u_data);
    return world_pos;
}

float3 perspective_ndc_to_world(float4 p_ndc, UniformData *u_data) {

    // The following equation assumes that M[3][3] == 0 and M[3][2] == -1
    float w_clip = u_data.clip_from_view[2][3] / (p_ndc.z + u_data.clip_from_view[2][2]);

    float4 p_clip = p_ndc * w_clip;

    float3 world = mul(u_data.world_from_clip, p_clip).xyz;
    return world;
}

// Hardcoding a screen-filling triangle in clip space
static const float2 POSITIONS[] = {
    -1.0, -3.0,         // Top Left
    -1.0, 1.0,          // Botton Left
    3.0, 1.0            // Bottom Right
};
static const float2 UVS[] = {
    0.0, -1.0,
    0.0, 1.0,
    2.0, 1.0
};

struct VertexOutput {
    float4 clip_pos : SV_Position;
    float2 uv;
}

[[vk::push_constant]]
cbuffer push_constants {
    uint color_target;
    uint depth_target;
    uint sampler_idx;
    uint tlas_idx;
    UniformData *u_data;
}

[shader("vertex")]
VertexOutput vertex_main(uint idx: SV_VertexID) {
    VertexOutput out = {};

    out.clip_pos = float4(POSITIONS[idx], 0.0, 1.0);
    out.uv = UVS[idx];

    return out;
}

[shader("fragment")]
float4 fragment_main(VertexOutput input) {
    float2 sample_pos = input.uv;
    sample_pos += u_data.distortion_strength * 
        float2(
            my_noise(input.uv + 0.5 * u_data.time),
            my_noise(input.uv + 0.5 * u_data.time + 1.0)
        );

    float4 target_sample = textures[color_target].Sample(samplers[sampler_idx], sample_pos);

    float depth_sample = textures[depth_target].Sample(samplers[sampler_idx], sample_pos).r;
    float3 frag_world_pos = perspective_frag_depth_to_world_pos(depth_sample, sample_pos, u_data);

    DirectionalLight light = u_data.directional_lights[0];
    Ray view_ray;
    view_ray.direction = normalize(frag_world_pos - u_data.view_position.xyz);
    view_ray.origin = u_data.view_position.xyz;
    target_sample.xyz += integrate_atmospheric_scattering(view_ray, frag_world_pos, u_data);

    if ((u_data.flags & UniformFlag.CRTShader) != 0) {
        float3 final = crt_filer(textures[color_target], samplers[sampler_idx], sample_pos, u_data.clip_from_screen);
        return float4(final.x, final.y, final.z, target_sample.a);
    }

    return target_sample;
}