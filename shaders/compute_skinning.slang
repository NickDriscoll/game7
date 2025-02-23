[[vk::push_constant]]
cbuffer push_constants {
    float4 *in_positions;           // Pointer to first input position
    float4 *out_positions;          // Pointer to first output position
    float4x4 *joint_transforms;
    //uint vtx_offset;
    uint joint_offset;
}

static const uint THREADS_X = 64;
[shader("compute")]
[numthreads(THREADS_X, 1, 1)]
void compute_main(uint3 thread_id: SV_DispatchThreadID) {
    // uint vtx_id = thread_id.x + vtx_offset * THREADS_X;
    uint vtx_id = thread_id.x;
    //uint joint_id = thread_id.x + joint_offset;

    float4 model_pos = in_positions[vtx_id];
    // float4x4 joint = joint_transforms[joint_id];

    out_positions[vtx_id] = model_pos;
}