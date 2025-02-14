

struct StaticMeshData {
    uint position_offset;
    uint face_normals_offset;
    uint uv_offset;
    uint color_offset;
}

struct SkinnedMeshData {
    StaticMeshData static_data;
    uint joint_ids_offset;
    uint joint_weights_offset;
}

struct InstanceData {
    float4x4 world_from_model;
    float4x4 normal_matrix;
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

    StaticMeshData *mesh_data;
    InstanceData *i_data;

    MaterialData *mat_data;
    float4 *position_data;
    float4 *face_normals_data;
    
    float2 *uv_data;
    float4 *color_data;
    uint4 *joint_ids;
    float4 *joint_weights;
    float4x4 *inv_bind_matrices;

    float time; // Periodic time value
    float distortion_strength;

    float2 _pad0;
}