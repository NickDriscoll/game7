

struct MeshData {
    uint position_offset;
    uint uv_offset;
    uint color_offset;
}

struct InstanceData {
    float4x4 world_from_model;
    uint mesh_idx;
    uint3 _pad0;
    float4x3 _pad4;
}

struct MaterialData {
    float4 base_color;
}

struct UniformData {
    float4x4 clip_from_world;
    float4x4 clip_from_screen;
    MeshData *mesh_data;
    InstanceData *i_data;
    MaterialData *mat_data;
    float4 *position_data;
    float2 *uv_data;
    float4 *color_data;
    
    // Periodic time value
    float time;
}