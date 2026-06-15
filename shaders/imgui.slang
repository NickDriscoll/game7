import tex_bindings;

struct ImguiVertex {
    float2 position : POSITION;
    float2 uv : UVS;
    uint color : COLOR;
}

struct ImguiVertexOutput {
    float4 clip_out : SV_Position;
    float2 uv;
    float4 color;
}

struct ImguiUniforms {
    float4x4 clip_from_screen;
}

[[vk::push_constant]]
cbuffer PushConstants
{
    uint texture_idx;
    uint sampler_idx;
    uint imgui_vertex_offset;
    ImguiUniforms *u_data;
    ImguiVertex *imgui_vertices;
}

[shader("vertex")]
ImguiVertexOutput vertex_main(uint id: SV_VertexID) {
    ImguiVertex vert = imgui_vertices[id + imgui_vertex_offset];
    ImguiVertexOutput out;
    out.clip_out = mul(u_data.clip_from_screen, float4(vert.position, 0.0, 1.0));
    out.uv = vert.uv;

    // Color is packed into the uint as RGBA little-endian
    out.color.r = (float)(vert.color & 0xFF) / 255.0;
    out.color.g = (float)((vert.color >> 8) & 0xFF) / 255.0;
    out.color.b = (float)((vert.color >> 16) & 0xFF) / 255.0;
    out.color.a = (float)((vert.color >> 24) & 0xFF) / 255.0;

    return out;
}

[shader("fragment")]
float4 fragment_main(ImguiVertexOutput vertex) {
    // float4 sample = textures[texture_idx].Sample(samplers[sampler_idx], vertex.uv);
    // float3 final_color = (vertex.color.rgb * vertex.color.a) * sample.rgb;// * sample.a;
    // float final_alpha = sample.a * vertex.color.a;
    // return float4(final_color, final_alpha);
    vertex.color.rgb *= vertex.color.a;
    return vertex.color * textures[texture_idx].Sample(samplers[sampler_idx], vertex.uv);
}