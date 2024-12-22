package main

import "core:math/linalg/hlsl"
import "core:math"
import hm "desktop_vulkan_wrapper/handlemap"
import imgui "odin-imgui"
import vk "vendor:vulkan"
import vkw "desktop_vulkan_wrapper"

// angle is in radians
pitch_rotation_matrix :: proc(angle: f32) -> hlsl.float4x4 {
    c := math.cos(angle)
    s := math.sin(angle)
    pitch := hlsl.float4x4 {
        1.0, 0.0, 0.0, 0.0,
        0.0, c, -s, 0.0,
        0.0, s, c, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }
    return pitch
}

// angle is in radians
yaw_rotation_matrix :: proc(angle: f32) -> hlsl.float4x4 {
    c := math.cos(angle)
    s := math.sin(angle)
    yaw := hlsl.float4x4 {
        c, -s, 0.0, 0.0,
        s, c, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }
    return yaw
}

// angle is in radians
roll_rotation_matrix :: proc(angle: f32) -> hlsl.float4x4 {
    c := math.cos(angle)
    s := math.sin(angle)
    roll := hlsl.float4x4 {
        c, 0.0, s, 0.0,
        0.0, 1.0, 0.0, 0.0,
        -s, 0.0, c, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }
    return roll
}

translation_matrix :: proc(trans: hlsl.float3) -> hlsl.float4x4 {
    return {
        1.0, 0.0, 0.0, trans.x,
        0.0, 1.0, 0.0, trans.y,
        0.0, 0.0, 1.0, trans.z,
        0.0, 0.0, 0.0, 1.0,
    }
}

uniform_scaling_matrix :: proc(scale: f32) -> hlsl.float4x4 {
    return {
        scale, 0.0, 0.0, 0.0,
        0.0, scale, 0.0, 0.0,
        0.0, 0.0, scale, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }
}

CameraFlags :: bit_set[enum {
    MouseLook,
    MoveForward,
    MoveBackward,
    MoveLeft,
    MoveRight,
    MoveUp,
    MoveDown,
    Speed,
    Slow,
}]

Camera :: struct {
    position: hlsl.float3,
    yaw: f32,
    pitch: f32,
    fov_radians: f32,
    aspect_ratio: f32,
    nearplane: f32,
    farplane: f32,
    control_flags: CameraFlags,
}

camera_view_from_world :: proc(camera: ^Camera) -> hlsl.float4x4 {
    pitch := pitch_rotation_matrix(camera.pitch)
    yaw := yaw_rotation_matrix(camera.yaw)
    trans := translation_matrix(-camera.position)

    return pitch * yaw * trans
}

// Returns a projection matrix with reversed near and far values for reverse-Z
camera_projection_from_view :: proc(camera: ^Camera) -> hlsl.float4x4 {
    c_matrix := hlsl.float4x4 {
        1.0, 0.0, 0.0, 0.0,
        0.0, 0.0, -1.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }

    tan_fovy := math.tan(camera.fov_radians / 2.0)
    near := camera.nearplane
    far := camera.farplane
    proj_matrix := hlsl.float4x4 {
        1.0 / (tan_fovy * camera.aspect_ratio), 0.0, 0.0, 0.0,
        0.0, 1.0 / tan_fovy, 0.0, 0.0,
        0.0, 0.0, near / (near - far), (near * far) / (far - near),
        0.0, 0.0, 1.0, 0.0,
    }

    return proj_matrix * c_matrix
}

lookat_view_from_world :: proc() -> hlsl.float4x4 {
    

    return {}
}
