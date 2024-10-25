

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
    uint image_idx;
    uint sampler_idx;
}

[shader("vertex")]
VertexOutput vertex_main(uint idx: SV_VertexID) {
    
}

[shader("fragment")]
float4 fragment_main(VertexOutput input) {
    
}