[[vk::push_constant]]
cbuffer push_constants {
    float4 *in_positions;
    float4 *out_positions;
    float4x4 *joint_transforms;
    uint vtx_offset;
    uint joint_offset;
}

static const uint THREADS_X = 64 * 64;
[shader("compute")]
[numthreads(THREADS_X, 1, 1)]
void compute_main(uint3 thread_id: SV_DispatchThreadID) {
    uint vtx_id = thread_id.x + vtx_offset * THREADS_X;
    uint joint_id = thread_id.x + joint_offset;

    // float4 model_pos = in_positions[vtx_id];
    // float4x4 joint = joint_transforms[joint_id];
}