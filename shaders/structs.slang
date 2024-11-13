// struct PositionData {
//     float4
// }

struct MeshData {
    uint position_offset;
    uint uv_offset;
}

struct InstanceData {
    float4x4 world_from_model;
    uint mesh_idx;
}

struct UniformData {
    float4x4 clip_from_world;
    float4x4 clip_from_screen;
    MeshData *m_data;
    InstanceData *i_data;
    float4 *position_data;
    float2 *uv_data;
}