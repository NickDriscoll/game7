package main

import "core:math/linalg/hlsl"
import "core:math"
import hm "desktop_vulkan_wrapper/handlemap"
import imgui "odin-imgui"
import vk "vendor:vulkan"
import vkw "desktop_vulkan_wrapper"

Camera :: struct {
    position: hlsl.float3,
    yaw: f32,
    pitch: f32,
    fov_radians: f32,
    aspect_ratio: f32,
    nearplane: f32,
    farplane: f32
}

camera_view_matrix :: proc(camera: ^Camera) -> hlsl.float4x4 {
    // float cosroll = cosf(roll);
    // float sinroll = sinf(roll);
    // float4x4 roll_matrix(
    //     cosroll, 0.0f, sinroll, 0.0f,
    //     0.0f, 1.0f, 0.0f, 0.0f,
    //     -sinroll, 0.0f, cosroll, 0.0f,
    //     0.0f, 0.0f, 0.0f, 1.0f
    // );

    cospitch := math.cos(camera.pitch)
    sinpitch := math.sin(camera.pitch)
    pitch := hlsl.float4x4 {
        1.0, 0.0, 0.0, 0.0,
        0.0, cospitch, -sinpitch, 0.0,
        0.0, sinpitch, cospitch, 0.0,
        0.0, 0.0, 0.0, 1.0
    }

    cosyaw := math.cos(camera.yaw)
    sinyaw := math.sin(camera.yaw)
    yaw := hlsl.float4x4 {
        cosyaw, -sinyaw, 0.0, 0.0,
        sinyaw, cosyaw, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0
    }

    trans := hlsl.float4x4 {
        1.0, 0.0, 0.0, -camera.position.x,
        0.0, 1.0, 0.0, -camera.position.y,
        0.0, 0.0, 1.0, -camera.position.z,
        0.0, 0.0, 0.0, 1.0
    }

    return pitch * yaw * trans
}

// Returns a projection matrix with reversed near and far values for reverse-Z
camera_projection_matrix :: proc(camera: ^Camera) -> hlsl.float4x4 {
    c_matrix := hlsl.float4x4 {
        1.0, 0.0, 0.0, 0.0,
        0.0, 0.0, -1.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 1.0
    }

    tan_fovy := math.tan(camera.fov_radians / 2.0)
    near := camera.nearplane
    far := camera.farplane
    proj_matrix := hlsl.float4x4 {
        1.0 / (tan_fovy * camera.aspect_ratio), 0.0, 0.0, 0.0,
        0.0, 1.0 / tan_fovy, 0.0, 0.0,
        0.0, 0.0, near / (near - far), (near * far) / (far - near),
        0.0, 0.0, 1.0, 0.0
    }

    return proj_matrix * c_matrix
}