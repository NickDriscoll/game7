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

get_view_ray :: proc(using camera: ^Camera, screen_coords: hlsl.uint2, resolution: hlsl.uint2) -> Ray {
    tan_fovy := math.tan(fov_radians / 2.0)
    tan_fovx := tan_fovy * f32(resolution.x) / f32(resolution.y)
    clip_coords := hlsl.float4 {
        f32(screen_coords.x) * 2.0 / f32(resolution.x) - 1.0,
        f32(screen_coords.y) * 2.0 / f32(resolution.y) - 1.0,
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

camera_update :: proc(
    game_state: ^GameState,
    output_verbs: ^OutputVerbs,
    dt: f32,
    speed_multiplier: f32,
    slow_multiplier: f32,
) -> hlsl.float4x4 {
    using game_state.viewport_camera
    if .Follow in control_flags {
        HEMISPHERE_START_POS :: hlsl.float4 {1.0, 0.0, 0.0, 0.0}

        game_state.viewport_camera.target.position = game_state.character.collision.origin

        camera_rotation: hlsl.float2 = {0.0, 0.0}
        camera_rotation.x += output_verbs.floats[.RotateFreecamX] * dt
        camera_rotation.y += output_verbs.floats[.RotateFreecamY] * dt

        relmotion_coords, ok3 := output_verbs.int2s[.MouseMotionRel]
        if ok3 {
            MOUSE_SENSITIVITY :: 0.001
            if .MouseLook in game_state.viewport_camera.control_flags {
                camera_rotation += MOUSE_SENSITIVITY * {f32(relmotion_coords.x), f32(relmotion_coords.y)}
            }
        }

        game_state.viewport_camera.yaw += camera_rotation.x
        game_state.viewport_camera.pitch += camera_rotation.y
        for game_state.viewport_camera.yaw < -2.0 * math.PI do game_state.viewport_camera.yaw += 2.0 * math.PI
        for game_state.viewport_camera.yaw > 2.0 * math.PI do game_state.viewport_camera.yaw -= 2.0 * math.PI
        if game_state.viewport_camera.pitch <= -math.PI / 2.0 do game_state.viewport_camera.pitch = -math.PI / 2.0 + 0.0001
        if game_state.viewport_camera.pitch >= math.PI / 2.0 do game_state.viewport_camera.pitch = math.PI / 2.0 - 0.0001
        
        pitchmat := roll_rotation_matrix(-game_state.viewport_camera.pitch)
        yawmat := yaw_rotation_matrix(-game_state.viewport_camera.yaw)
        pos_offset := game_state.viewport_camera.target.distance * hlsl.normalize(yawmat * hlsl.normalize(pitchmat * HEMISPHERE_START_POS))

        game_state.viewport_camera.position = game_state.character.collision.origin + pos_offset.xyz

        return lookat_view_from_world(&game_state.viewport_camera)
    } else {
        camera_rotation: hlsl.float2 = {0.0, 0.0}
        camera_direction: hlsl.float3 = {0.0, 0.0, 0.0}
        camera_speed_mod : f32 = 1.0
    
        // Input handling part
        if .Sprint in output_verbs.bools {
            if output_verbs.bools[.Sprint] do control_flags += {.Speed}
            else do control_flags -= {.Speed}
        }
        if .Crawl in output_verbs.bools {
            if output_verbs.bools[.Crawl] do control_flags += {.Slow}
            else do control_flags -= {.Slow}
        }
    
        if .TranslateFreecamUp in output_verbs.bools {
            if output_verbs.bools[.TranslateFreecamUp] do control_flags += {.MoveUp}
            else do control_flags -= {.MoveUp}
        }
        if .TranslateFreecamDown in output_verbs.bools {
            if output_verbs.bools[.TranslateFreecamDown] do control_flags += {.MoveDown}
            else do control_flags -= {.MoveDown}
        }
        if .TranslateFreecamLeft in output_verbs.bools {
            if output_verbs.bools[.TranslateFreecamLeft] do control_flags += {.MoveLeft}
            else do control_flags -= {.MoveLeft}
        }
        if .TranslateFreecamRight in output_verbs.bools {
            if output_verbs.bools[.TranslateFreecamRight] do control_flags += {.MoveRight}
            else do control_flags -= {.MoveRight}
        }
        if .TranslateFreecamBack in output_verbs.bools {
            if output_verbs.bools[.TranslateFreecamBack] do control_flags += {.MoveBackward}
            else do control_flags -= {.MoveBackward}
        }
        if .TranslateFreecamForward in output_verbs.bools {
            if output_verbs.bools[.TranslateFreecamForward] do control_flags += {.MoveForward}
            else do control_flags -= {.MoveForward}
        }
    
        relmotion_coords, ok3 := output_verbs.int2s[.MouseMotionRel]
        if ok3 {
            MOUSE_SENSITIVITY :: 0.001
            if .MouseLook in game_state.viewport_camera.control_flags {
                camera_rotation += MOUSE_SENSITIVITY * {f32(relmotion_coords.x), f32(relmotion_coords.y)}
            }
        }
    
        camera_rotation.x += output_verbs.floats[.RotateFreecamX]
        camera_rotation.y += output_verbs.floats[.RotateFreecamY]
        camera_direction.x += output_verbs.floats[.TranslateFreecamX]
    
        // Not a sign error. In view-space, -Z is forward
        camera_direction.z -= output_verbs.floats[.TranslateFreecamY]
    
        camera_speed_mod += speed_multiplier * output_verbs.floats[.Sprint]
        //camera_speed_mod += slow_multiplier * output_verbs.floats[.Crawl]
    
    
        CAMERA_SPEED :: 10
        per_frame_speed := CAMERA_SPEED * dt
    
        if .Speed in control_flags do camera_speed_mod *= speed_multiplier
        if .Slow in control_flags do camera_speed_mod *= slow_multiplier
    
        game_state.viewport_camera.yaw += camera_rotation.x
        game_state.viewport_camera.pitch += camera_rotation.y
        for game_state.viewport_camera.yaw < -2.0 * math.PI do game_state.viewport_camera.yaw += 2.0 * math.PI
        for game_state.viewport_camera.yaw > 2.0 * math.PI do game_state.viewport_camera.yaw -= 2.0 * math.PI
        if game_state.viewport_camera.pitch < -math.PI / 2.0 do game_state.viewport_camera.pitch = -math.PI / 2.0
        if game_state.viewport_camera.pitch > math.PI / 2.0 do game_state.viewport_camera.pitch = math.PI / 2.0
    
        control_flags_dir: hlsl.float3
        if .MoveUp in control_flags do control_flags_dir += {0.0, 1.0, 0.0}
        if .MoveDown in control_flags do control_flags_dir += {0.0, -1.0, 0.0}
        if .MoveLeft in control_flags do control_flags_dir += {-1.0, 0.0, 0.0}
        if .MoveRight in control_flags do control_flags_dir += {1.0, 0.0, 0.0}
        if .MoveBackward in control_flags do control_flags_dir += {0.0, 0.0, 1.0}
        if .MoveForward in control_flags do control_flags_dir += {0.0, 0.0, -1.0}
        if control_flags_dir != {0.0, 0.0, 0.0} do camera_direction += hlsl.normalize(control_flags_dir)
    
        if camera_direction != {0.0, 0.0, 0.0} {
            camera_direction = hlsl.float3(camera_speed_mod) * hlsl.float3(per_frame_speed) * camera_direction
        }
    
        //Compute temporary camera matrix for orienting player inputted direction vector
        world_from_view := hlsl.inverse(camera_view_from_world(&game_state.viewport_camera))
        camera_direction4 := hlsl.float4{camera_direction.x, camera_direction.y, camera_direction.z, 0.0}
        game_state.viewport_camera.position += (world_from_view * camera_direction4).xyz
    
        // Collision test the camera's bounding sphere against the terrain
        if game_state.freecam_collision {
            camera_collision_point: hlsl.float3
            closest_dist := math.INF_F32
            for &piece in game_state.terrain_pieces {
                candidate := closest_pt_triangles(position, &piece.collision)
                candidate_dist := hlsl.distance(candidate, position)
                if candidate_dist < closest_dist {
                    camera_collision_point = candidate
                    closest_dist = candidate_dist
                }
            }
    
            if game_state.freecam_collision {
                CAMERA_RADIUS :: 0.8
                dist := hlsl.distance(camera_collision_point, position)
                if dist < CAMERA_RADIUS {
                    diff := CAMERA_RADIUS - dist
                    position += diff * hlsl.normalize(position - camera_collision_point)
                }
            }
        }

        return camera_view_from_world(&game_state.viewport_camera)
    }
}
