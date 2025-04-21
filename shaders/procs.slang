import structs;

float3 sky_color(float3 view_dir) {
    float3 sky = (view_dir + 1.0) / 2.0;
    return sky;
}