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
