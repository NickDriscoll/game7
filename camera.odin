package main

import "core:math"
import "core:math/linalg/hlsl"

CameraTarget :: struct {
    position: hlsl.float3,
    distance: f32,
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
    Follow
}]

Camera :: struct {
    position: hlsl.float3,

    // Pitch and yaw are oriented around {0.0, 0.0, 1.0} in world space
    yaw: f32,
    pitch: f32,

    fov_radians: f32,
    aspect_ratio: f32,
    nearplane: f32,
    farplane: f32,
    collision_radius: f32,
    target: CameraTarget,
    control_flags: CameraFlags,
}

camera_view_from_world :: proc(camera: ^Camera) -> hlsl.float4x4 {
    pitch := pitch_rotation_matrix(camera.pitch)
    yaw := yaw_rotation_matrix(camera.yaw)
    trans := translation_matrix(-camera.position)

    // Change from right-handed Z-Up to left-handed Y-Up
    c_mat := hlsl.float4x4 {
        1.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, -1.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }

    return c_mat * pitch * yaw * trans
}

// Returns a projection matrix with reversed near and far values for reverse-Z
camera_projection_from_view :: proc(camera: ^Camera) -> hlsl.float4x4 {

    // Change from left-handed Y-Up to Y-down, Z-forward
    c_matrix := hlsl.float4x4 {
        1.0, 0.0, 0.0, 0.0,
        0.0, -1.0, 0.0, 0.0,
        0.0, 0.0, -1.0, 0.0,
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
lookat_view_from_world :: proc(
    using camera: ^Camera,
    up := hlsl.float3 {0.0, 0.0, 1.0}
) -> hlsl.float4x4 {
    focus_vector := hlsl.normalize(position - target.position)

    right := hlsl.normalize(hlsl.cross(up, focus_vector))
    local_up := hlsl.cross(focus_vector, right)

    look := hlsl.float4x4 {
        right.x, right.y, right.z, 0.0,
        local_up.x, local_up.y, local_up.z, 0.0,
        focus_vector.x, focus_vector.y, focus_vector.z, 0.0,
        0.0, 0.0, 0.0, 1.0
    }
    trans := translation_matrix(-position)

    return look * trans
}

pitch_yaw_from_lookat :: proc(pos: hlsl.float3, target: hlsl.float3) -> (yaw, pitch: f32) {
    focus_vector := hlsl.normalize(pos - target)
    pitch = math.asin(focus_vector.z)
    yaw = math.atan2(focus_vector.y, focus_vector.x) + (math.PI / 2.0)
    return yaw, pitch
}

get_view_ray :: proc(using camera: ^Camera, click_coords: hlsl.uint2, resolution: hlsl.uint2) -> Ray {
    tan_fovy := math.tan(fov_radians / 2.0)
    tan_fovx := tan_fovy * f32(resolution.x) / f32(resolution.y)
    clip_coords := hlsl.float4 {
        f32(click_coords.x) * 2.0 / f32(resolution.x) - 1.0,
        f32(click_coords.y) * 2.0 / f32(resolution.y) - 1.0,
        1.0,
        1.0
    }

    
    view_coords := hlsl.float4 {
        clip_coords.x * nearplane * tan_fovx,
        -clip_coords.y * nearplane * tan_fovy,
        -nearplane,
        1.0
    }

    world_coords: hlsl.float4
    if .Follow in control_flags {
        world_coords = hlsl.inverse(lookat_view_from_world(camera)) * view_coords
    } else {
        world_coords = hlsl.inverse(camera_view_from_world(camera)) * view_coords
    }

    start := hlsl.float3 {world_coords.x, world_coords.y, world_coords.z}
    return Ray {
        start = start,
        direction = hlsl.normalize(start - position)
    }
}