package main

import "core:math/linalg/hlsl"
import "core:math"
import "core:time"
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
_UNUSED_rotate_a_onto_b :: proc(a, b: hlsl.float3) -> hlsl.float4x4 {
    //assert(hlsl.abs(hlsl.length(a) - 1.0) < 0.0001 && hlsl.abs(hlsl.length(b) - 1.0) < 0.0001)

    v := hlsl.cross(a, b)
    //sine := hlsl.length(v)
    cosine := hlsl.dot(a, b)

    sscm := hlsl.float3x3 {
        0.0, -v.z, v.y,
        v.z, 0.0, -v.x,
        -v.y, v.x, 0.0
    }

    r := IDENTITY_MATRIX3x3 + sscm + (sscm * sscm) //* (1.0 / (1.0 + cosine))
    for i in 0..<3 {
        r[i] *= 1.0 / (1.0 + cosine)
    }

    rr := hlsl.float4x4(r)
    rr[2, 3] = 1.0
    return rr
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

scaling_matrix :: proc(scale: hlsl.float3) -> hlsl.float4x4 {
    return {
        scale.x, 0.0, 0.0, 0.0,
        0.0, scale.y, 0.0, 0.0,
        0.0, 0.0, scale.z, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }
}

basis_matrix :: proc(x, y, z: hlsl.float3) -> hlsl.float4x4 {
    return {
        x.x, y.x, z.x, 0.0,
        x.y, y.y, z.y, 0.0,
        x.z, y.z, z.z, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }
}

// From https://lisyarus.github.io/blog/posts/exponential-smoothing.html
exponential_smoothing :: proc(current: $VectorType, target: VectorType, speed: f32, dt: f32) -> VectorType {
    return current + (target - current) * (1.0 - math.exp(-speed * dt))
}

z_rotate_quaternion :: proc (angle: f32) -> quaternion128 {
    half_angle := angle / 2.0
    imag := hlsl.float3 {0.0, 0.0, 1.0} * math.sin(half_angle)

    return quaternion(w = math.cos(half_angle), x = imag.x, y = imag.y, z = imag.z)
}



the_time_has_come  :: proc (timer: time.Time, d: $T/time.Duration) -> bool {
    return time.diff(timer, time.now()) > time.Duration(d)
}