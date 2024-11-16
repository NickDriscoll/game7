
// Hardcoding a screen-filling triangle in clip space
static const float2 POSITIONS[] = {
    -1.0, -2.0,
    
};

struct VertexOutput {
    float4 clip_pos : SV_Position;
}

[shader("vertex")]
VertexOutput vertex_main(uint idx: SV_VertexID, uint inst_idx: SV_InstanceID) {
    VertexOutput out = {};

    return out;
}

[shader("fragment")]
float4 fragment_main(VertexOutput input) {

}