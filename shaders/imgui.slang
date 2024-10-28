import structs;
import tex_bindings;
// import bindings.frame_uniforms;
// import bindings.imgui_vertices;
// import bindings.global_textures;

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

[[vk::push_constant]]
cbuffer PushConstants
{
    uint font_idx;
    uint sampler_idx;
    uint imgui_vertex_offset;
    UniformData *u_data;
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
float4 fragment_main(ImguiVertexOutput input) {
    return input.color * textures[font_idx].Sample(samplers[sampler_idx], input.uv);
}