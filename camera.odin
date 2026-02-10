package main

import "core:log"
import "core:math"
import "core:math/linalg/hlsl"

CAMERA_COLLISION_RADIUS :: 0.1

CameraFlag  :: enum {
    MouseLook,
    MoveForward,
    MoveBackward,
    MoveLeft,
    MoveRight,
    MoveUp,
    MoveDown,
    Speed,
    Slow,
}
CameraFlags :: bit_set[CameraFlag]

LookatController :: struct {
    current_focal_point: hlsl.float3,
    target: EntityID,
    distance: f32,
}


Camera :: struct {
    fov_radians: f32,
    aspect_ratio: f32,
    nearplane: f32,
    farplane: f32,

    // Pitch and yaw are oriented around {0.0, 0.0, 1.0} in world space
    yaw: f32,
    pitch: f32,

    flags: CameraFlags,
}

freecam_view_from_world :: proc(transform: Transform, camera: Camera) -> hlsl.float4x4 {
    pitch := pitch_rotation_matrix(camera.pitch)
    yaw := yaw_rotation_matrix(camera.yaw)
    trans := translation_matrix(-transform.position)

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
camera_projection_from_view :: proc(camera: Camera) -> hlsl.float4x4 {

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
    transform: Transform,
    target_position: hlsl.float3,
    up := hlsl.float3 {0.0, 0.0, 1.0}
) -> hlsl.float4x4 {
    focus_vector := hlsl.normalize(transform.position - target_position)

    right := hlsl.normalize(hlsl.cross(up, focus_vector))
    local_up := hlsl.cross(focus_vector, right)

    look := hlsl.float4x4 {
        right.x, right.y, right.z, 0.0,
        local_up.x, local_up.y, local_up.z, 0.0,
        focus_vector.x, focus_vector.y, focus_vector.z, 0.0,
        0.0, 0.0, 0.0, 1.0
    }
    trans := translation_matrix(-transform.position)
    return look * trans
}

pitch_yaw_from_lookat :: proc(pos: hlsl.float3, target: hlsl.float3) -> (yaw, pitch: f32) {
    focus_vector := hlsl.normalize(pos - target)
    pitch = math.asin(focus_vector.z)
    yaw = math.atan2(focus_vector.y, focus_vector.x) + (math.PI / 2.0)
    return yaw, pitch
}

get_click_view_coords :: proc(camera_settings: Camera, click_coords: hlsl.uint2, resolution: hlsl.uint2) -> hlsl.float4 {
    tan_fovy := math.tan(camera_settings.fov_radians / 2.0)
    tan_fovx := tan_fovy * f32(resolution.x) / f32(resolution.y)
    clip_coords := hlsl.float4 {
        f32(click_coords.x) * 2.0 / f32(resolution.x) - 1.0,
        f32(click_coords.y) * 2.0 / f32(resolution.y) - 1.0,
        1.0,
        1.0
    }

    return hlsl.float4 {
        clip_coords.x * camera_settings.nearplane * tan_fovx,
        -clip_coords.y * camera_settings.nearplane * tan_fovy,
        -camera_settings.nearplane,
        1.0
    }
}

freecam_view_ray :: proc(transform: Transform, camera: Camera, click_coords: hlsl.uint2, resolution: hlsl.uint2) -> Ray {
    view_coords := get_click_view_coords(camera, click_coords, resolution)
    world_coords := hlsl.inverse(freecam_view_from_world(transform, camera)) * view_coords

    start := hlsl.float3 {world_coords.x, world_coords.y, world_coords.z}
    return Ray {
        start = start,
        direction = hlsl.normalize(start - transform.position)
    }
}

lookat_view_ray :: proc(transform: Transform, camera: Camera, target: hlsl.float3, click_coords: hlsl.uint2, resolution: hlsl.uint2) -> Ray {
    view_coords := get_click_view_coords(camera, click_coords, resolution)
    world_coords := hlsl.inverse(lookat_view_from_world(transform, target)) * view_coords

    start := hlsl.float3 {world_coords.x, world_coords.y, world_coords.z}
    return Ray {
        start = start,
        direction = hlsl.normalize(start - transform.position)
    }
}
