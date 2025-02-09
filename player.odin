package main

import "core:math"
import "core:math/linalg/hlsl"

import vkw "desktop_vulkan_wrapper"

player_update :: proc(using game_state: ^GameState, output_verbs: ^OutputVerbs, dt: f32) {
    if output_verbs.bools[.PlayerReset] {
        character.collision.position = CHARACTER_START_POS
        character.velocity = {}
    }

    GRAVITY_ACCELERATION : hlsl.float3 : {0.0, 0.0, 2.0 * -9.8}           // m/s^2
    TERMINAL_VELOCITY :: -100000.0                                  // m/s

    // Set current xy velocity (and character facing) to whatever user input is
    {
        // X and Z bc view space is x-right, y-up, z-back
        v := output_verbs.float2s[.PlayerTranslate]
        xv := v.x
        zv := v.y
        {
            r, ok := output_verbs.bools[.PlayerTranslateLeft]
            if ok {
                if r {
                    character.control_flags += {.MovingLeft}
                } else {
                    character.control_flags -= {.MovingLeft}
                }
            }
            r, ok = output_verbs.bools[.PlayerTranslateRight]
            if ok {
                if r {
                    character.control_flags += {.MovingRight}
                } else {
                    character.control_flags -= {.MovingRight}
                }
            }
            r, ok = output_verbs.bools[.PlayerTranslateBack]
            if ok {
                if r {
                    character.control_flags += {.MovingBack}
                } else {
                    character.control_flags -= {.MovingBack}
                }
            }
            r, ok = output_verbs.bools[.PlayerTranslateForward]
            if ok {
                if r {
                    character.control_flags += {.MovingForward}
                } else {
                    character.control_flags -= {.MovingForward}
                }
            }
        }
        if .MovingLeft in character.control_flags do xv += -1.0
        if .MovingRight in character.control_flags do xv += 1.0
        if .MovingBack in character.control_flags do zv += -1.0
        if .MovingForward in character.control_flags do zv += 1.0

        // Input vector is in view space, so we transform to world space
        world_v := hlsl.float4 {-zv, xv, 0.0, 0.0}
        world_v = yaw_rotation_matrix(-game_state.viewport_camera.yaw) * world_v
        if hlsl.length(world_v) > 1.0 {
            world_v = hlsl.normalize(world_v)
        }
    
        character.velocity.xy = character.move_speed * world_v.xy

        if xv != 0.0 || zv != 0.0 {
            character.facing = -hlsl.normalize(world_v).xyz
        }
    }

    // Main player character state machine
    switch character.state {
        case .Grounded: {
            //Check if we need to bump ourselves up or down
            if character.velocity.z <= 0.0 {
                tolerance_segment := Segment {
                    start = character.collision.position + {0.0, 0.0, 0.0},
                    end = character.collision.position + {0.0, 0.0, -character.collision.radius - 0.1}
                }
                tolerance_t, normal, okt := intersect_segment_terrain_with_normal(&tolerance_segment, game_state.terrain_pieces[:])
                tolerance_point := tolerance_segment.start + tolerance_t * (tolerance_segment.end - tolerance_segment.start)
                if okt {
                    character.collision.position = tolerance_point + {0.0, 0.0, character.collision.radius}
                    if hlsl.dot(normal, hlsl.float3{0.0, 0.0, 1.0}) >= 0.5 {
                        character.velocity.z = 0.0
                        character.state = .Grounded
                    }
                } else {
                    character.state = .Falling
                }
            }

            // Handle jump command
            if output_verbs.bools[.PlayerJump] {
                character.velocity += {0.0, 0.0, character.jump_speed}
                character.state = .Falling
            }

            // Compute motion interval
            motion_endpoint := character.collision.position + timescale * dt * character.velocity
            motion_interval := Segment {
                start = character.collision.position,
                end = motion_endpoint
            }

            // Push out of ground
            p, n := closest_pt_terrain_with_normal(motion_endpoint, game_state.terrain_pieces[:])
            dist := hlsl.distance(p, character.collision.position)
            if dist < character.collision.radius {
                remaining_dist := character.collision.radius - dist
                if hlsl.dot(n, hlsl.float3{0.0, 0.0, 1.0}) < 0.5 {
                    character.collision.position = motion_endpoint + remaining_dist * n
                } else {
                    character.collision.position = motion_endpoint
                    
                }
            } else {
                character.collision.position = motion_endpoint
            }
        }
        case .Falling: {
            // Apply gravity to velocity, clamping downward speed if necessary
            character.velocity += timescale * dt * GRAVITY_ACCELERATION
            if character.velocity.z < TERMINAL_VELOCITY {
                character.velocity.z = TERMINAL_VELOCITY
            }
    
            // Compute motion interval
            motion_endpoint := character.collision.position + timescale * dt * character.velocity
            motion_interval := Segment {
                start = character.collision.position,
                end = motion_endpoint
            }

            // Check if player canceled jump early
            not_canceled, ok := output_verbs.bools[.PlayerJump]
            if ok && !not_canceled && character.velocity.z > 0.0 {
                character.velocity.z *= 0.1
            }

            // Then do collision test against triangles
            //closest_t, n, hit := dynamic_sphere_vs_terrain_t_with_normal(&character.collision, game_state.terrain_pieces[:], &motion_interval)
            closest_pt, n := closest_pt_terrain_with_normal(motion_endpoint, game_state.terrain_pieces[:])
            d := hlsl.distance(character.collision.position, closest_pt)
            hit := d < character.collision.radius

            // Respond
            if hit {
                // Hit terrain
                //character.collision.position += closest_t * (motion_interval.end - motion_interval.start)
                remaining_d := character.collision.radius - d
                character.collision.position = motion_endpoint + remaining_d * n
                n_dot := hlsl.dot(n, hlsl.float3{0.0, 0.0, 1.0})
                if n_dot >= 0.5 && character.velocity.z < 0.0 {
                    character.velocity = {}
                    character.state = .Grounded
                } else if n_dot < -0.1 && character.velocity.z > 0.0 {
                    character.velocity.z = 0.0
                }
            } else {
                // Didn't hit anything, falling.
                character.collision.position = motion_endpoint
            }
        }
    }

    // Camera follow point chases player
    target_pt := character.collision.position
    //target_pt := character.collision.position - 0.01 * {character.velocity.x, character.velocity.y, 0.0}
    
    // From https://lisyarus.github.io/blog/posts/exponential-smoothing.html
    camera_follow_point += (target_pt - camera_follow_point) * (1.0 - math.exp(-camera_follow_speed * dt))
}

player_draw :: proc(using game_state: ^GameState, gd: ^vkw.Graphics_Device, render_data: ^RenderingState) {
    y := character.facing
    z := hlsl.float3 {0.0, 0.0, 1.0}
    x := hlsl.cross(z, y)
    rotate_mat := hlsl.float4x4 {
        x[0], y[0], z[0], 0.0,
        x[1], y[1], z[1], 0.0,
        x[2], y[2], z[2], 0.0,
        0.0, 0.0, 0.0, 1.0,
    }
    ddata := DrawData {
        world_from_model = rotate_mat
    }
    ddata.world_from_model[3][0] = game_state.character.collision.position.x
    ddata.world_from_model[3][1] = game_state.character.collision.position.y
    ddata.world_from_model[3][2] = game_state.character.collision.position.z
    draw_ps1_mesh(gd, render_data, &game_state.character.mesh_data, &ddata)
}