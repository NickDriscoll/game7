static const uint THREADS_X = 64;

[[vk::push_constant]]
cbuffer push_constants {
    float4 *in_positions;
    float4 *out_positions;
}

[shader("compute")]
[numthreads(THREADS_X, 1, 1)]
void compute_main(uint3 thread_id: SV_DispatchThreadID) {
    uint id = thread_id.x;

    float4 model_pos = in_positions[id];
}