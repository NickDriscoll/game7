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

// Computes a rotation matrix that maps unit vector A onto unit vector B
// From https://math.stackexchange.com/questions/180418/calculate-rotation-matrix-to-align-vector-a-to-vector-b-in-3d/476311#476311
rotate_a_onto_b :: proc(a, b: hlsl.float3) -> hlsl.float4x4 {
    assert(hlsl.length(a) == 1.0 && hlsl.length(b) == 1.0)

    v := hlsl.cross(a, b)
    //sine := hlsl.length(v)
    cosine := hlsl.dot(a, b)

    sscm := hlsl.float3x3 {
        0.0, -v.z, v.y,
        v.z, 0.0, -v.x,
        -v.y, v.x, 0.0
    }

    r := IDENTITY_MATRIX3x3 + sscm + (sscm * sscm) //* (1.0 / (1.0 + cosine))
    for i in 0..<4 {
        r[i] *= 1.0 / (1.0 + cosine)
    }

    return hlsl.float4x4(r)
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
