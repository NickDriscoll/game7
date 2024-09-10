

struct VertexOutput {
    float4 clip_out : SV_Position;
    float2 uv;
    float4 color;
}

[shader("vertex")]
VertexOutput vertex_main() {
    VertexOutput out;
    out.clip_out = float4(1.0, 1.0, 1.0, 1.0);
    out.uv = float2(1.0, 1.0);
    out.color = float4(1.0, 1.0, 1.0, 1.0);

    return out;
}

[shader("fragment")]
float4 fragment_main() : SV_Target0 {
    return float4(1.0, 0.0, 0.0, 1.0);
}