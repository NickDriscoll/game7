
static const uint MAX_DIRECTIONAL_LIGHTS = 4;
static const uint MAX_POINT_LIGHTS = 8;
static const float PI = acos(-1);

struct StaticMeshData {
    uint position_offset;
    uint uv_offset;
    uint color_offset;
    uint _pad0;
}

enum InstanceFlags {
    Highlighted = 1,
    Glowing = 2,
}
struct InstanceData {
    float4x4 world_from_model;
    float4x4 normal_matrix;
    uint mesh_idx;
    uint material_idx;
    uint flags;
    uint _pad0;
    float4 color;
    float4x2 _pad4;
}

struct MaterialData {
    uint color_texture;
    uint normal_texture;
    uint arm_texture; // "arm" as in ambient roughness metalness, packed in RGB in that order

    uint sampler_idx;
    float4 base_color;
}

struct DecalInstance {

}

struct DirectionalLight {
    float3 direction;
    float _pad0;
    float3 color;
    float _pad1;
}

struct PointLight {
    float3 world_position;
    float intensity;
    float3 color;
    float _pad1;
}

struct Ray {
    float3 origin;
    float3 direction;
};

enum UniformFlag {
    ColorTriangles = 0x01,
    Reflections = 0x02,
    CRTShader = 0x04,
    VisualizeFaceNormals = 0x08,
    VisualizeVertexColors = 0x10,
    VisualizeDirectDiffuse = 0x20,
    VisualizeDirectSpecular = 0x40,
    Unlit = 0x80,
}

struct UniformData {
    float4x4 clip_from_world;

    float4x4 world_from_clip;

    float4x4 clip_from_view;

    float4x4 view_from_world;

    float4x4 world_from_view;

    float4x4 view_from_clip;

    float4x4 clip_from_skybox;

    float4x4 clip_from_screen;

    StaticMeshData *mesh_data;
    InstanceData *i_data;

    MaterialData *mat_data;
    half4 *position_data;

    float2 *uv_data;
    float4 *color_data;

    uint4 *joint_ids;
    float4 *joint_weights;

    float4x4 *inv_bind_matrices;
    DecalInstance *decals;

    float4 view_position;

    DirectionalLight directional_lights[MAX_DIRECTIONAL_LIGHTS];
    PointLight point_lights[MAX_POINT_LIGHTS];

    uint directional_light_count;
    uint point_light_count;
    float time; // Periodic time value
    float distortion_strength;

    uint flags;
    uint skybox_idx;
    float cloud_speed;
    float cloud_scale;

    float fog_fudge;
    float fog_max_depth;
    int fog_step_multiple;
    float henyey_greenstein_g;

    float beta_scale;
    float3 _pad;

    // RaytracingAccelerationStructure.Handle tlas;
    // float2 _pad1;
}

static const float3 INWARD_FACING_CUBE[] = {
    // Front
    -1.0, -1.0, -1.0,
    1.0, -1.0, -1.0,
    -1.0, 1.0, -1.0,
    1.0, 1.0, -1.0,
    -1.0, 1.0, -1.0,
    1.0, -1.0, -1.0,

    // Left
    -1.0, -1.0, -1.0,
    -1.0, 1.0, -1.0,
    -1.0, -1.0, 1.0,
    -1.0, 1.0, -1.0,
    -1.0, 1.0, 1.0,
    -1.0, -1.0, 1.0,

    // Right
    1.0, 1.0, -1.0,
    1.0, -1.0, -1.0,
    1.0, -1.0, 1.0,
    1.0, 1.0, 1.0,
    1.0, 1.0, -1.0,
    1.0, -1.0, 1.0,

    // Back
    -1.0, 1.0, 1.0,
    1.0, 1.0, 1.0,
    -1.0, -1.0, 1.0,
    1.0, 1.0, 1.0,
    1.0, -1.0, 1.0,
    -1.0, -1.0, 1.0,

    // Bottom
    -1.0, -1.0, 1.0,
    1.0, -1.0, -1.0,
    -1.0, -1.0, -1.0,
    -1.0, -1.0, 1.0,
    1.0, -1.0, 1.0,
    1.0, -1.0, -1.0,

    // Top
    1.0, 1.0, 1.0,
    -1.0, 1.0, 1.0,
    -1.0, 1.0, -1.0,
    1.0, 1.0, 1.0,
    -1.0, 1.0, -1.0,
    1.0, 1.0, -1.0
};

static const float3 OUTWARD_FACING_CUBE[] = {
    // Front
    -1.0, -1.0, -1.0,
    -1.0, 1.0, -1.0,
    1.0, -1.0, -1.0,
    1.0, 1.0, -1.0,
    1.0, -1.0, -1.0,
    -1.0, 1.0, -1.0,

    // Left
    -1.0, -1.0, -1.0,
    -1.0, -1.0, 1.0,
    -1.0, 1.0, -1.0,
    -1.0, 1.0, -1.0,
    -1.0, -1.0, 1.0,
    -1.0, 1.0, 1.0,

    // Right
    1.0, 1.0, -1.0,
    1.0, -1.0, 1.0,
    1.0, -1.0, -1.0,
    1.0, 1.0, 1.0,
    1.0, -1.0, 1.0,
    1.0, 1.0, -1.0,

    // Back
    -1.0, 1.0, 1.0,
    -1.0, -1.0, 1.0,
    1.0, 1.0, 1.0,
    1.0, 1.0, 1.0,
    -1.0, -1.0, 1.0,
    1.0, -1.0, 1.0,

    // Bottom
    -1.0, -1.0, 1.0,
    -1.0, -1.0, -1.0,
    1.0, -1.0, -1.0,
    -1.0, -1.0, 1.0,
    1.0, -1.0, -1.0,
    1.0, -1.0, 1.0,

    // Top
    1.0, 1.0, 1.0,
    -1.0, 1.0, -1.0,
    -1.0, 1.0, 1.0,
    1.0, 1.0, 1.0,
    1.0, 1.0, -1.0,
    -1.0, 1.0, -1.0,
};