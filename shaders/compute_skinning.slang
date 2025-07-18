// Notes adapted from a Twitter post by Janos, the Wicked Engine guy.

// dispatchXYZ means the vkCmdDispatch(X, Y, Z) from Vulkan
// numthreadsXYZ means the numthreads definition in the compute shader

// global ID of the dispatched GROUP, range: [0, dispatchXYZ]
// - coherent for the whole thread group (SGPR)
// - usually used when processing tiles or bins
// SV_GroupID

// local ID of the thread within the group, range: [0, numthreadsXYZ]
// - divergent for each thread within the group (VGPR)
// - usually used for accessing groupshared memory as 2D/3D array
// SV_GroupThreadID

// global ID of the thread within the Dispatch(), range: [0, dispatchXYZ * numthreadsXYZ]
// - divergent for each thread within the whole dispatch (VGPR)
// - usually this is directly the pixel coordinate when processing textures, or the buffer index when processing whole buffers
// - SV_DispatchThreadID == SV_GroupID * numthreadsXYZ + SV_GroupThreadID
// SV_DispatchThreadID

// The only one that's not an ID but an index, this is the flattened SV_GroupThreadID, range: [0, numthreads.x * numthreads.y * numthreads.z]
// - divergent for each thread within the group (VGPR)
// - usually used for accessing groupshared memory as 1D array
// SV_GroupIndex







[[vk::push_constant]]
cbuffer push_constants {
    half4 *in_positions;           // Pointer to first input position
    half4 *out_positions;          // Pointer to first output position
    uint4 *joint_ids;               // Pointer to first joint ids vector
    float4 *joint_weights;          // Pointer to first joint weights vector
    float4x4 *joint_transforms;     // Pointer to first joint transform
    uint max_vtx_id;                // Total number of vertices so overdispatched threads can exit
}

static const uint THREADS_X = 64;
[shader("compute")]
[numthreads(THREADS_X, 1, 1)]
void compute_main(uint3 thread_id: SV_DispatchThreadID) {
    uint vtx_id = thread_id.x;

    // Early out for over-dispatched threads
    if (vtx_id > max_vtx_id) return;

    // Compute skinning matrix
    uint4 ids = joint_ids[vtx_id];
    float4 weights = joint_weights[vtx_id];
    float4x4 joint_matrix = {};
    for (int i = 0; i < 4; ++i) {
        joint_matrix += weights[i] * joint_transforms[ids[i]];
    }

    // Apply skinning matrix to model position and write it out
    half4 model_pos = in_positions[vtx_id];
    out_positions[vtx_id] = half4(mul(joint_matrix, model_pos));
}