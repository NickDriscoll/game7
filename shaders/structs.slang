

struct MeshData {
    uint position_offset;
    uint uv_offset;
    uint color_offset;
}

struct InstanceData {
    float4x4 world_from_model;
    uint mesh_idx;
    uint material_idx;
    uint2 _pad0;
    float4x3 _pad4;
}

struct MaterialData {
    uint color_texture;
    uint normal_texture;
    uint arm_texture; // "arm" as in ambient roughness metalness, packed in RGB in that order

    uint sampler_idx;
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

    float distortion_strength;
}