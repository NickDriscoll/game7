package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/linalg/hlsl"
import "core:math/noise"
import "core:mem"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "vendor:sdl2"
import vk "vendor:vulkan"

import vkw "desktop_vulkan_wrapper"
import imgui "odin-imgui"

DEFAULT_COMPONENT_MAP_CAPACITY :: 64

GRAVITY_ACCELERATION : hlsl.float3 : {0.0, 0.0, 2.0 * -9.8}           // m/s^2
TERMINAL_VELOCITY :: -100000.0                                  // m/s
ENEMY_THROW_SPEED :: 15.0
DEFAULT_FACING_DIRECTION :: hlsl.float3 {1.0, 0.0, 0.0}

closest_pt_terrain :: proc(point: hlsl.float3, terrain: map[EntityID]TriangleMesh) -> hlsl.float3 {
    candidate: hlsl.float3
    closest_dist := math.INF_F32
    for _, &piece in terrain {
        p := closest_pt_triangles(point, &piece)
        d := hlsl.distance(point, p)
        if d < closest_dist {
            candidate = p
            closest_dist = d
        }
    }
    return candidate
}
closest_pt_terrain_with_normal :: proc(point: hlsl.float3, terrain: map[EntityID]TriangleMesh) -> (hlsl.float3, hlsl.float3) {
    scoped_event(&profiler, "closest_pt_terrain_with_normal")
    candidate: hlsl.float3
    cn: hlsl.float3
    closest_dist := math.INF_F32
    for _, piece in terrain {
        p, n := closest_pt_triangles_with_normal(point, piece)
        d := hlsl.distance(point, p)
        if d < closest_dist {
            candidate = p
            closest_dist = d
            cn = n
        }
    }
    return candidate, cn
}

intersect_segment_terrain :: proc(segment: Segment, terrain: map[EntityID]TriangleMesh) -> (hlsl.float3, bool) {
    scoped_event(&profiler, "intersect_segment_terrain")
    cand_t := math.INF_F32
    for _, &piece in terrain {
        t, ok := intersect_segment_triangles_t(segment, piece)
        if ok {
            if t < cand_t {
                cand_t = t
            }
        }
    }

    return segment.start + cand_t * (segment.end - segment.start), cand_t < math.INF_F32
}

intersect_segment_terrain_with_normal :: proc(segment: Segment, terrain: map[EntityID]TriangleMesh) -> (f32, hlsl.float3, bool) {
    scoped_event(&profiler, "intersect_segment_terrain_with_normal")
    cand_t := math.INF_F32
    normal: hlsl.float3
    for _, piece in terrain {
        t, n, ok := intersect_segment_triangles_t_with_normal(segment, piece)
        if ok {
            if t < cand_t {
                cand_t = t
                normal = n
            }
        }
    }

    return cand_t, normal, cand_t < math.INF_F32
}

dynamic_sphere_vs_terrain_t :: proc(s: Sphere, terrain: map[EntityID]TriangleMesh, motion_interval: Segment) -> (f32, bool) {
    closest_t := math.INF_F32
    for _, piece in terrain {
        t, ok3 := dynamic_sphere_vs_triangles_t(s, piece, motion_interval)
        if ok3 {
            if t < closest_t {
                closest_t = t
            }
        }
    }
    return closest_t, closest_t < math.INF_F32
}

do_mouse_raycast :: proc(
    game_state: GameState,
    viewport_camera_id: EntityID,
    triangle_meshes: map[EntityID]TriangleMesh,
    mouse_location: [2]i32,
    viewport_dimensions: [4]f32
) -> (hlsl.float3, bool) {
    click_coords := hlsl.uint2 {
        u32(mouse_location.x) - u32(viewport_dimensions[0]),
        u32(mouse_location.y) - u32(viewport_dimensions[1]),
    }

    tform := &game_state.transforms[viewport_camera_id]
    camera := &game_state.cameras[viewport_camera_id]
    lookat_controller, is_lookat := &game_state.lookat_controllers[viewport_camera_id]

    resolution := hlsl.uint2 {u32(viewport_dimensions[2]), u32(viewport_dimensions[3])}
    ray: Ray
    if is_lookat {
        target := &game_state.transforms[lookat_controller.target]
        ray = lookat_view_ray(tform^, camera^, target.position, click_coords, resolution)
    } else {
        ray = freecam_view_ray(tform^, camera^, click_coords, resolution)
    }

    collision_pt: hlsl.float3
    closest_dist := math.INF_F32
    for _, &piece in triangle_meshes {
        candidate, ok := intersect_ray_triangles(ray, piece)
        if ok {
            candidate_dist := hlsl.distance(candidate, tform.position)
            if candidate_dist < closest_dist {
                collision_pt = candidate
                closest_dist = candidate_dist
            }
        }
    }

    return collision_pt, closest_dist < math.INF_F32
}

Transform :: struct {
    position: hlsl.float3,
    rotation: quaternion128,
    scale: f32,
}
get_transform_matrix :: proc(tform: Transform, scale: f32 = 1.0) -> hlsl.float4x4 {
    scale_mat := scaling_matrix(tform.scale)
    rot := linalg.matrix4_from_quaternion_f32(tform.rotation)
    mat := rot * scale_mat * scaling_matrix(scale)
    mat[3][0] = tform.position.x
    mat[3][1] = tform.position.y
    mat[3][2] = tform.position.z

    return mat
}

TransformDelta :: struct {
    velocity: hlsl.float3,
    rotational_velocity: quaternion128,
}

tick_transform_deltas :: proc(game_state: ^GameState, dt: f32) {
    for id, &delta in game_state.transform_deltas {
        tform := &game_state.transforms[id]
        tform.position += dt * delta.velocity
    }
}

tick_looping_animations :: proc(game_state: ^GameState, renderer: Renderer, dt: f32) {
    for id in game_state.looping_animations {
        instance := &game_state.skinned_models[id]
        instance.anim_t = instance.anim_t + dt
        duration := get_animation_duration(renderer, instance.anim_idx)
        for instance.anim_t > duration {
            instance.anim_t -= duration
        }
    }
}

tick_coins :: proc(game_state: ^GameState, audio_system: ^AudioSystem) {    
    rot := z_rotate_quaternion(game_state.time)
    z_offset := 0.25 * math.sin(game_state.time)

    for id in game_state.coins {
        model := &game_state.static_models[id]
        model.pos_offset.z = z_offset

        tform := &game_state.transforms[id]
        tform.rotation = rot
    }
}

EnemyAI :: struct {
    home_position: hlsl.float3,
    facing: hlsl.float3,
    visualize_home: bool,
    state: EnemyState,
    init_state: EnemyState,
    timer_start: time.Time
}
default_enemyai :: proc(game_state: GameState) -> EnemyAI {
    return {
        home_position = {},
        facing = {0.0, 1.0, 0.0},
        visualize_home = false,
        state = .Wandering,
        timer_start = time.now()
    }
}

new_enemy :: proc(game_state: ^GameState, position: hlsl.float3, scale: f32, state: EnemyState) -> EntityID {
    id := gamestate_next_id(game_state)
    game_state.transforms[id] = Transform {
        position = position,
        rotation = linalg.QUATERNIONF32_IDENTITY,
        scale = scale
    }
    ai := default_enemyai(game_state^)
    ai.state = state
    ai.init_state = state
    ai.home_position = position
    game_state.enemy_ais[id] = ai

    game_state.spherical_bodies[id] = SphericalBody {
        radius = 0.5,
        gravity_scale = 1.0,
        state = .Falling
    }

    game_state.static_models[id] = StaticModelInstance {
        handle = game_state.enemy_mesh,
        flags = {}
    }

    return id
}

delete_enemy :: proc(game_state: ^GameState, id: EntityID) {
    delete_key(&game_state.transforms, id)
    delete_key(&game_state.spherical_bodies, id)
    delete_key(&game_state.enemy_ais, id)
    delete_key(&game_state.static_models, id)
}

ENEMY_HOME_RADIUS :: 4.0
ENEMY_LUNGE_SPEED :: 20.0
ENEMY_JUMP_SPEED :: 6.0                 // m/s
ENEMY_PLAYER_MIN_DISTANCE :: 50.0       // Meters
tick_enemy_ai :: proc(game_state: ^GameState, audio_system: ^AudioSystem, dt: f32) {
    char_tform := &game_state.transforms[game_state.player_id]

    enemy_to_remove: Maybe(EntityID)
    for id, &enemy in game_state.enemy_ais {
        transform := &game_state.transforms[id]
        
        dist_to_player := hlsl.distance(char_tform.position, transform.position)
        body := &game_state.spherical_bodies[id]
        is_affected_by_gravity := false
        switch enemy.state {
            case .BrainDead: {
                body.velocity.xy = {}
            }
            case .Wandering: {
                sample_point := [2]f64 {f64(game_state.time), f64(id)}
                t := 5.0 * dt * noise.noise_2d(game_state.rng_seed, sample_point)
                rotq := z_rotate_quaternion(t)
                enemy.facing = linalg.quaternion128_mul_vector3(rotq, enemy.facing)

                body.velocity.xy = hlsl.normalize(enemy.facing.xy)

                if dist_to_player < ENEMY_HOME_RADIUS {
                    enemy.facing = char_tform.position - transform.position
                    enemy.facing.z = 0.0
                    enemy.facing = hlsl.normalize(enemy.facing)
                    body.velocity = {0.0, 0.0, ENEMY_JUMP_SPEED}
                    enemy.state = .AlertedBounce
                    body.state = .Falling
                    enemy.timer_start = time.now()
                    enemy.home_position = transform.position
                    play_sound_effect(audio_system, game_state.jump_sound)
                }

                if time.diff(enemy.timer_start, time.now()) > time.Duration(5.0 * SECONDS_TO_NANOSECONDS) {
                    // Start resting
                    enemy.timer_start = time.now()
                    enemy.state = .Resting
                    body.velocity = {}
                }
            }
            case .Hovering: {
                assert(false)
            }
            case .AlertedBounce: {
                if body.state == .Grounded {
                    enemy.state = .AlertedCharge
                    body.velocity.xy += enemy.facing.xy * ENEMY_LUNGE_SPEED
                    body.velocity.z = ENEMY_JUMP_SPEED / 2.0
                    body.state = .Falling
                    play_sound_effect(audio_system, game_state.jump_sound)
                }
            }
            case .AlertedCharge: {
                enemy.home_position = transform.position
                if body.state == .Grounded {
                    body := game_state.spherical_bodies[id]
                    enemy.state = .Resting
                    enemy.timer_start = time.now()
                    body.velocity = {}
                }
            }
            case .Resting: {
                if time.diff(enemy.timer_start, time.now()) > time.Duration(0.75 * SECONDS_TO_NANOSECONDS) {
                    // Start wandering
                    enemy.timer_start = time.now()
                    enemy.state = .Wandering
                }
            }
        }

        // Restrict enemy movement based on home position
        {
            disp := transform.position - enemy.home_position
            l := hlsl.length(disp.xy)
            if l > ENEMY_HOME_RADIUS {
                transform.position.xy += (l - ENEMY_HOME_RADIUS) * hlsl.normalize((enemy.home_position - transform.position).xy)
            }
        }

        // Check for collision with player
        {
            player_tform := &game_state.transforms[game_state.player_id]
            player_collision := &game_state.spherical_bodies[game_state.player_id]

            ps := Sphere {
                position = player_tform.position,
                radius = player_collision.radius
            }
            es := Sphere {
                position = transform.position,
                radius = body.radius
            }
            if are_spheres_overlapping(ps, es) {
                append(&game_state.character_damage_events, DamageEvent {})
            }
        }

        // Check if overlapping player grab
        // bullet, ok := char.air_vortex.?
        // if ok {
        //     col := Sphere {
        //         position = transform.position,
        //         radius = body.radius
        //     }
        //     if are_spheres_overlapping(bullet.collision, col) {
        //         char.held_enemy = Enemy {
        //             position = transform.position,
        //             ai_state = enemy.init_state
        //         }
        //         enemy_to_remove = id
        //         char.air_vortex = nil
        //     }
        // }

        // Get transform rotation quaternion from facing direction
        {
            transform.rotation = linalg.quaternion_between_two_vector3_f32(hlsl.float3{0.0, 1.0, 0.0}, enemy.facing)
        }
    }

    {
        to_remove, should_remove := enemy_to_remove.?
        if should_remove {
            delete_enemy(game_state, to_remove)
        }
    }
}

HoveringEnemy :: struct {
    home_position: hlsl.float3,
    radius: f32,
}

new_hovering_enemy :: proc(game_state: ^GameState, position: hlsl.float3, scale: f32) -> EntityID {
    id := gamestate_next_id(game_state)
    game_state.transforms[id] = Transform {
        position = position,
        rotation = linalg.QUATERNIONF32_IDENTITY,
        scale = scale
    }
    game_state.hovering_enemies[id] = HoveringEnemy {
        home_position = position,
        radius = 0.5,
    }
    game_state.static_models[id] = StaticModelInstance {
        handle = game_state.enemy_mesh,
        flags = {}
    }

    return id
}

tick_hovering_enemies :: proc(game_state: ^GameState, dt: f32) {
    for id, enemy in game_state.hovering_enemies {
        transform := &game_state.transforms[id]
        offset := hlsl.float3 {0, 0, 1.5 * math.sin(game_state.time)}
        transform.position = enemy.home_position + offset

        // Check for collision with player
        {
            player_tform := &game_state.transforms[game_state.player_id]
            player_collision := &game_state.spherical_bodies[game_state.player_id]

            ps := Sphere {
                position = player_tform.position,
                radius = player_collision.radius
            }
            es := Sphere {
                position = transform.position,
                radius = enemy.radius
            }
            if are_spheres_overlapping(ps, es) {
                append(&game_state.character_damage_events, DamageEvent {})
            }
        }
    }
}

ThrownEnemyAI :: struct {
    respawn_position: hlsl.float3,
    radius: f32,
    state: EnemyState
}

tick_thrown_enemies :: proc(game_state: ^GameState) {
    to_remove: Maybe(EntityID)
    for id, enemy in game_state.thrown_enemy_ais {
        transform := &game_state.transforms[id]
        closest_pt := closest_pt_terrain(transform.position, game_state.triangle_meshes)
        
        if hlsl.distance(closest_pt, transform.position) < enemy.radius {
            to_remove = id
            
            // Respawn enemy
            new_enemy(game_state, enemy.respawn_position, transform.scale * 5/4, enemy.state)
        }
    }

    remove_id, remove := to_remove.?
    if remove {
        delete_thrown_enemy(game_state, remove_id)
    }
}

new_thrown_enemy :: proc(
    game_state: ^GameState,
    position: hlsl.float3,
    velocity: hlsl.float3,
    state: EnemyState,
    respawn_position: hlsl.float3,
) -> EntityID {
    id := gamestate_next_id(game_state)
    game_state.transforms[id] = Transform {
        position = position,
        scale = 0.5 * 0.8
    }
    game_state.transform_deltas[id] = TransformDelta {
        velocity = velocity
    }
    game_state.static_models[id] = StaticModelInstance {
        handle = game_state.enemy_mesh,
        flags = {.Glowing}
    }
    game_state.thrown_enemy_ais[id] = ThrownEnemyAI {
        respawn_position = respawn_position,
        radius = 0.5 * 0.8,
        state = state
    }

    return id
}

delete_thrown_enemy :: proc(game_state: ^GameState, id: EntityID) {
    delete_key(&game_state.transforms, id)
    delete_key(&game_state.transform_deltas, id)
    delete_key(&game_state.static_models, id)
    delete_key(&game_state.thrown_enemy_ais, id)
}

SphericalBody :: struct {
    velocity: hlsl.float3,
    radius: f32,
    gravity_scale: f32,
    state: CollisionState,
}

tick_spherical_bodies :: proc(game_state: ^GameState, dt: f32) {
    scoped_event(&profiler, "tick_spherical_bodies")
    for id, &body in game_state.spherical_bodies {
        scoped_event(&profiler, "tick_spherical_bodies iteration")
        transform := &game_state.transforms[id]

        // Body's desired motion interval
        motion_interval := Segment {
            start = transform.position,
            end = transform.position + dt * body.velocity
        }

        simple_continuous_collision_detection :: proc(
            motion_interval: Segment,
            transform: ^Transform,
            radius: f32,
            terrain: map[EntityID]TriangleMesh
        ) -> (collision_normal: hlsl.float3, ok: bool) {
            segment_collision_t, segment_collision_normal, segment_intersected := intersect_segment_terrain_with_normal(motion_interval, terrain)
            if segment_intersected {
                segment_collision := sample_segment(motion_interval, segment_collision_t)
                transform.position = segment_collision + segment_collision_normal * radius
                collision_normal = segment_collision_normal
                ok = true
            } else {
                closest_pt, closest_pt_normal := closest_pt_terrain_with_normal(motion_interval.end, terrain)
                d := hlsl.distance(motion_interval.end, closest_pt)
                if d < radius {
                    // Hit terrain
                    remaining_d := radius - d
                    transform.position = motion_interval.end + remaining_d * closest_pt_normal
                    collision_normal = closest_pt_normal
                    ok = true
                }
            }
            return
        }

        collided_this_frame: bool
        switch body.state {
            case .Grounded: {
                // Check for walking into walls
                if body.velocity != {} {
                    collision_normal, ok := simple_continuous_collision_detection(motion_interval, transform, body.radius, game_state.triangle_meshes)
                    if ok {
                        collided_this_frame = true
                        n_dot := hlsl.dot(collision_normal, hlsl.float3{0.0, 0.0, 1.0})
                        if n_dot >= 0.5 {
                            // Floor
                            body.velocity.z = 0.0
                            body.state = .Grounded
                        } else if n_dot < -0.1 {
                            // Ceiling
                            body.velocity.z = 0.0
                        } else {
                            // Wall
                            
                        }
                    }
                }

                // Check if we need to bump ourselves up or down
                {
                    tolerance_segment := Segment {
                        start = transform.position + {0.0, 0.0, 0.0},
                        end = transform.position + {0.0, 0.0, -body.radius - 0.1}
                    }
                    tolerance_t, normal, okt := intersect_segment_terrain_with_normal(tolerance_segment, game_state.triangle_meshes)
                    if okt {
                        tolerance_point := sample_segment(tolerance_segment, tolerance_t)
                        transform.position = tolerance_point + {0.0, 0.0, body.radius}
                        if hlsl.dot(normal, hlsl.float3{0.0, 0.0, 1.0}) >= 0.5 {
                            body.velocity.z = 0.0
                            body.state = .Grounded
                        }
                    } else {
                        body.state = .Falling
                    }
                }
            }
            case .Falling: {
                // Update velocity
                body.velocity += dt * body.gravity_scale * GRAVITY_ACCELERATION
                if body.velocity.z < TERMINAL_VELOCITY {
                    body.velocity.z = TERMINAL_VELOCITY
                }

                collision_normal, ok := simple_continuous_collision_detection(motion_interval, transform, body.radius, game_state.triangle_meshes)
                if ok {
                    collided_this_frame = true
                    n_dot := hlsl.dot(collision_normal, hlsl.float3{0.0, 0.0, 1.0})
                    if n_dot >= 0.5 {
                        // Floor
                        body.velocity.z = 0.0
                        body.state = .Grounded
                    } else if n_dot < -0.1 {
                        // Ceiling
                        body.velocity.z = 0.0
                    } else {
                        // Wall
                        
                    }
                }

            }
        }

        // Update transform component if collision resolution didn't
        // already write to the transform
        if !collided_this_frame {
            transform.position += dt * body.velocity
        }
    }
}

CharacterFlag :: enum {
    MovingLeft,
    MovingRight,
    MovingBack,
    MovingForward,
    AlreadyJumped,
    Sprinting,
    HoldingEnemy
}
CharacterFlags :: bit_set[CharacterFlag]
CHARACTER_MAX_HEALTH :: 3
CHARACTER_INVULNERABILITY_DURATION :: 0.5
BULLET_MAX_RADIUS :: 1.0
CHARACTER_HEAVY_GRAVITY :: 2.2
CharacterController :: struct {
    acceleration: hlsl.float3,
    deceleration_speed: f32,
    move_speed: f32,
    sprint_speed: f32,
    jump_speed: f32,
    bullet_travel_time: f32,
    health: u32,
    vortex_t: f32,
    anim_speed: f32,
    time_last_damaged: time.Time,
    flags: CharacterFlags,
}

tick_character_controllers :: proc(game_state: ^GameState, gd: ^vkw.GraphicsDevice, renderer: ^Renderer, output_verbs: OutputVerbs, audio_system: ^AudioSystem, dt: f32) {
    camera := &game_state.cameras[game_state.viewport_camera_id]
    for id, &char in game_state.character_controllers {
        tform := &game_state.transforms[id]
        collision := &game_state.spherical_bodies[id]
        model := &game_state.skinned_models[id]

        // Set current xy velocity (and character facing) to whatever user input is
        {
            // X and Z bc view space is x-right, y-up, z-back
            translate_vector := output_verbs.float2s[.PlayerTranslate]
            translate_vector_x := translate_vector.x
            translate_vector_z := translate_vector.y

            // Boolean (keyboard) input handling
            {
                set_character_flags_from_verb :: proc(flags: ^CharacterFlags, d: map[VerbType]bool, verb: VerbType, action: CharacterFlag) {
                    r, ok := d[verb]
                    if ok {
                        if r {
                            flags^ += {action}
                        } else {
                            flags^ -= {action}
                        }
                    }
                }

                flags := &char.flags
                set_character_flags_from_verb(flags, output_verbs.bools, .PlayerTranslateLeft, .MovingLeft)
                set_character_flags_from_verb(flags, output_verbs.bools, .PlayerTranslateRight, .MovingRight)
                set_character_flags_from_verb(flags, output_verbs.bools, .PlayerTranslateBack, .MovingBack)
                set_character_flags_from_verb(flags, output_verbs.bools, .PlayerTranslateForward, .MovingForward)
                
                if .MovingLeft in flags^ {
                    translate_vector_x += -1.0
                }
                if .MovingRight in flags^ {
                    translate_vector_x += 1.0
                }
                if .MovingBack in flags^ {
                    translate_vector_z += -1.0
                }
                if .MovingForward in flags^ {
                    translate_vector_z += 1.0
                }
            }

            // Input vector is in view space, so we transform to world space
            world_invector := hlsl.float4 {-translate_vector_z, translate_vector_x, 0.0, 0.0}
            world_invector = yaw_rotation_matrix(-camera.yaw) * world_invector
            if hlsl.length(world_invector) > 1.0 {
                world_invector = hlsl.normalize(world_invector)
            }

            // Handle sprint
            this_frame_move_speed := char.move_speed
            {
                flags := &char.flags
                amount, ok := output_verbs.floats[.Sprint]
                if ok {
                    this_frame_move_speed = linalg.lerp(char.move_speed, char.sprint_speed, amount)
                }
                if .Sprint in output_verbs.bools {
                    if output_verbs.bools[.Sprint] {
                        flags^ += {.Sprinting}
                    } else {
                        flags^ -= {.Sprinting}
                    }
                }
                if .Sprinting in flags {
                    this_frame_move_speed = char.sprint_speed
                }
            }

            // Now we have a representation of the player's input vector in world space

            //if !taking_damage {
            {
                char.acceleration = {world_invector.x, world_invector.y, 0.0}
                accel_len := hlsl.length(char.acceleration)
                this_frame_move_speed *= accel_len
                if accel_len == 0 && collision.state == .Grounded {
                    to_zero := hlsl.float2 {0.0, 0.0} - collision.velocity.xy
                    collision.velocity.xy += char.deceleration_speed * to_zero
                }
                collision.velocity.xy += char.acceleration.xy
                if math.abs(hlsl.length(collision.velocity.xy)) > this_frame_move_speed {
                    collision.velocity.xy = this_frame_move_speed * hlsl.normalize(collision.velocity.xy)
                }
                movement_dist := hlsl.length(collision.velocity.xy)

                duration := get_animation_duration(renderer^, model.anim_idx)
                model.anim_t += char.anim_speed * dt * movement_dist
                for model.anim_t >= duration {
                    model.anim_t -= duration
                }
            }

            if translate_vector_x != 0.0 || translate_vector_z != 0.0 {
                tform.rotation = linalg.quaternion_between_two_vector3_f32(DEFAULT_FACING_DIRECTION, hlsl.normalize(world_invector).xyz)
            }
        }

        // Handle jump command
        {
            flags := &char.flags
            if collision.state == .Grounded {
                flags^ -= {.AlreadyJumped}
            }

            jumped, jump_ok := output_verbs.bools[.PlayerJump]
            if jump_ok {
                // If jump state changed...
                if jumped {
                    // To jumping...
                    if .AlreadyJumped in flags {
                        // Do thrown-enemy double-jump
                        

                        // held_enemy, is_holding_enemy := char.held_enemy.?
                        // if is_holding_enemy {
                        //     char.held_enemy = nil

                        //     // Throw enemy downwards
                        //     // append(&game_state.thrown_enemies, ThrownEnemy {
                        //     //     position = char.collision.position - {0.0, 0.0, 0.5},
                        //     //     velocity = {0.0, 0.0, -ENEMY_THROW_SPEED},
                        //     //     respawn_position = held_enemy.position,
                        //     //     respawn_home = held_enemy.home_position,
                        //     //     respawn_ai_state = .Resting,
                        //     //     collision_radius = 0.5,
                        //     // })

                        //     id := new_thrown_enemy(
                        //         game_state,
                        //         char.collision.position - {0.0, 0.0, 0.5},
                        //         {0.0, 0.0, -ENEMY_THROW_SPEED},
                        //         held_enemy.ai_state,
                        //         held_enemy.position
                        //     )

                        //     char.collision.velocity.z = 1.3 * char.jump_speed
                        //     play_sound_effect(audio_system, game_state.jump_sound)
                        // }
                    } else {
                        // Do first jump
                        collision.velocity.z = char.jump_speed
                        flags^ += {.AlreadyJumped}

                        play_sound_effect(audio_system, game_state.jump_sound)
                    }

                    collision.gravity_scale = 1.0
                    collision.state = .Falling
                } else {
                    // To not jumping...
                    collision.gravity_scale = CHARACTER_HEAVY_GRAVITY
                }
            }
        }

        // Teleport player back to spawn if hit death plane
        respawn := output_verbs.bools[.PlayerReset]
        respawn |= tform.position.z < -50.0
        respawn |= char.health == 0
        if respawn {
            tform.position = game_state.level_start
            collision.velocity = {}
            char.acceleration = {}
            char.health = CHARACTER_MAX_HEALTH
        }

        // Shoot command
        {
            res, have_shoot := output_verbs.bools[.PlayerShoot]
            if have_shoot && res {
                if .HoldingEnemy in char.flags {
                    char.flags -= {.HoldingEnemy}
                    throw_dir := ENEMY_THROW_SPEED * linalg.quaternion128_mul_vector3(tform.rotation, DEFAULT_FACING_DIRECTION)
                    new_thrown_enemy(game_state, tform.position, throw_dir, .BrainDead, {})
                } else {
                    char.vortex_t = 0.0
                }


                // if res && char.air_vortex == nil {
                //     held_enemy, is_holding_enemy := char.held_enemy.?
                //     if is_holding_enemy {
                //         id := new_thrown_enemy(
                //             game_state,
                //             char.collision.position + char.facing,
                //             ENEMY_THROW_SPEED * char.facing,
                //             held_enemy.ai_state,
                //             held_enemy.position
                //         )
                //         char.held_enemy = nil
                //     } else {
                //         start_pos := char.collision.position
                //         char.air_vortex = AirVortex {
                //             collision = Sphere {
                //                 position = start_pos,
                //                 radius = 0.1
                //             },
        
                //             t = 0.0,
                //         }
                //     }
                //     play_sound_effect(audio_system, game_state.shoot_sound)
                // }
            }
        }

        player_sphere := Sphere {
            position = tform.position,
            radius = collision.radius
        }

        {
            to_remove: Maybe(u32)
            for coin_id, idx in game_state.coins {
                coin_tform := &game_state.transforms[coin_id]
                {
                    // Are we being collected?
                    s := Sphere {
                        position = coin_tform.position,
                        //radius = game_state.coin_collision_radius
                        radius = coin_tform.scale
                    }
                    if are_spheres_overlapping(player_sphere, s) {
                        play_sound_effect(audio_system, game_state.coin_sound)
                        to_remove = u32(idx)
                        continue
                    }
                }
            }

            // Remove coin
            remove_idx, ok := to_remove.?
            if ok {
                remove_id := game_state.coins[remove_idx]
                delete_key(&game_state.transforms, remove_id)
                delete_key(&game_state.static_models, remove_id)
                unordered_remove(&game_state.coins, remove_idx)
            }
        }

        // Do logic for vortex move
        //bullet, bok := &char.air_vortex.?
        if char.vortex_t < char.bullet_travel_time {
            char.vortex_t += dt
            radius := BULLET_MAX_RADIUS * char.vortex_t / char.bullet_travel_time

            // Check for collision with enemies
            enemy_to_remove: Maybe(EntityID)
            for enemy_id, _ in game_state.enemy_ais {
                enemy_tform := &game_state.transforms[enemy_id]

                tsphere := Sphere {
                    position = enemy_tform.position,
                    radius = radius
                }
                if are_spheres_overlapping(player_sphere, tsphere) {
                    enemy_to_remove = enemy_id
                    break
                }
            }
            enemy_remove_id, ok := enemy_to_remove.?
            if ok {
                char.vortex_t = char.bullet_travel_time
                char.flags += {.HoldingEnemy}
                delete_enemy(game_state, enemy_remove_id)
            }

            // Update graphics
            mat := scaling_matrix(radius)
            mat[3][0] = tform.position.x
            mat[3][1] = tform.position.y
            mat[3][2] = tform.position.z
            draw := DebugDraw {
                world_from_model = mat,
                color = {0.0, 0.4, 0.0, 0.3}
            }
            draw_debug_mesh(gd, renderer, game_state.sphere_mesh, &draw)

            do_point_light(renderer, PointLight {
                world_position = tform.position,
                intensity = radius,
                color = {0.0, 1.0, 0.0}
            })
        }
    }
}

StaticModelInstance :: struct {
    handle: StaticModelHandle,
    pos_offset: hlsl.float3,
    flags: InstanceFlags,
}

SkinnedModelInstance :: struct {
    handle: SkinnedModelHandle,
    pos_offset: hlsl.float3,
    anim_idx: u32,
    anim_t: f32,
    flags: InstanceFlags,
}

DebugModelInstance :: struct {
    handle: StaticModelHandle,
    color: hlsl.float4,
    pos_offset: hlsl.float3,
    scale: f32,
}

DamageEvent :: struct {

}

tick_damage_events :: proc(game_state: ^GameState, audio_system: ^AudioSystem) {
    collision := &game_state.spherical_bodies[game_state.player_id]
    char := &game_state.character_controllers[game_state.player_id]
    invulnerable := !timer_expired(char.time_last_damaged, CHARACTER_INVULNERABILITY_DURATION * SECONDS_TO_NANOSECONDS)
    if invulnerable {
        return
    }
    for event in game_state.character_damage_events {
        collision.velocity.z = 3.0
        collision.state = .Falling
        char.time_last_damaged = time.now()
        char.health -= 1
        play_sound_effect(audio_system, game_state.ow_sound)
    }
}

CollisionState :: enum {
    Grounded,
    Falling
}

EnemyState :: enum {
    BrainDead,

    Wandering,
    Resting,

    Hovering,

    AlertedBounce,
    AlertedCharge,
}
ENEMY_STATE_CSTRINGS :: [EnemyState]cstring {
    .BrainDead = "Brain Dead",
    .Wandering = "Wandering",
    .Resting = "Resting",
    .Hovering = "Hovering",
    .AlertedBounce = "Alerted Bounce",
    .AlertedCharge = "Alerted Charge"
}

DebugVisualizationFlag :: enum {
    ShowPlayerSpawn,
    ShowPlayerHitSphere,
    ShowPlayerActivityRadius,
    ShowCoinRadius,
}
DebugVisualizationFlags :: bit_set[DebugVisualizationFlag]

AirVortex :: struct {
    collision: Sphere,
    t: f32,
}

LevelBlock :: enum u8 {
    Terrain = 0,
    StaticScenery = 1,
    AnimatedScenery = 2,
    Enemies = 3,
    BgmFile = 4,
    DirectionalLights = 5,
    Coins = 6,
}

EntityID :: distinct u32

// Megastruct for all game-specific data
GameState :: struct {
    player_id: EntityID,
    viewport_camera_id: EntityID,

    // Scene/Level data
    level_start: hlsl.float3,
    skybox_texture: vkw.Texture_Handle,

    // Data-oriented tables
    _next_id: u32,                   // Components with the same id are associated with one another
    transforms: map[EntityID]Transform,
    transform_deltas: map[EntityID]TransformDelta,
    cameras: map[EntityID]Camera,
    lookat_controllers: map[EntityID]LookatController,
    character_controllers: map[EntityID]CharacterController,
    enemy_ais: map[EntityID]EnemyAI,
    hovering_enemies: map[EntityID]HoveringEnemy,
    thrown_enemy_ais: map[EntityID]ThrownEnemyAI,
    spherical_bodies: map[EntityID]SphericalBody,
    triangle_meshes: map[EntityID]TriangleMesh,
    static_models: map[EntityID]StaticModelInstance,
    skinned_models: map[EntityID]SkinnedModelInstance,
    debug_models: map[EntityID]DebugModelInstance,

    // Sometimes we need behavior associated with a group of ids
    // without actually needing to store additional state
    looping_animations: [dynamic]EntityID,
    coins: [dynamic]EntityID,

    character_damage_events: [dynamic]DamageEvent,

    // User input mapping structs
    freecam_key_mappings : map[sdl2.Scancode]VerbType,
    character_key_mappings: map[sdl2.Scancode]VerbType,
    mouse_mappings: map[u8]VerbType,
    button_mappings: map[sdl2.GameControllerButton]VerbType,

    // Icosphere mesh for visualizing spherical collision and points
    sphere_mesh: StaticModelHandle,
    
    coin_mesh: StaticModelHandle,
    coin_collision_radius: f32,

    enemy_mesh: StaticModelHandle,

    debug_vis_flags: DebugVisualizationFlags,

    // Editor state
    editor_response: Maybe(EditorResponse),
    current_level: string,
    savename_buffer: [1024]c.char,

    // Global sound effects loaded on init_gamestate()
    bgm_id: uint,
    jump_sound: uint,
    shoot_sound: uint,
    coin_sound: uint,
    ow_sound: uint,

    camera_follow_point: hlsl.float3,
    camera_follow_speed: f32,
    timescale: f32,
    time: f32,
    rng_seed: i64,

    freecam_collision: bool,
    freecam_speed_multiplier: f32,
    freecam_slow_multiplier: f32,

    borderless_fullscreen: bool,
    exclusive_fullscreen: bool,

    paused: bool,
}

init_gamestate :: proc(
    gd: ^vkw.GraphicsDevice,
    renderer: ^Renderer,
    audio_system: ^AudioSystem,
    user_config: ^UserConfiguration,
    global_allocator: runtime.Allocator,
) -> GameState {
    scoped_event(&profiler, "Init gamestate")
    game_state: GameState
    game_state.freecam_collision = user_config.flags[.FreecamCollision]
    game_state.borderless_fullscreen = user_config.flags[.BorderlessFullscreen]
    game_state.exclusive_fullscreen = user_config.flags[.ExclusiveFullscreen]
    game_state.paused = false
    game_state.timescale = 1.0
    game_state.coin_collision_radius = 0.1
    
    game_state.freecam_key_mappings = make(map[sdl2.Scancode]VerbType, allocator = global_allocator)
    game_state.character_key_mappings = make(map[sdl2.Scancode]VerbType, allocator = global_allocator)
    game_state.mouse_mappings = make(map[u8]VerbType, 64, allocator = global_allocator)
    game_state.button_mappings = make(map[sdl2.GameControllerButton]VerbType, 64, allocator = global_allocator)

    {
        game_state.freecam_key_mappings[.ESCAPE] = .ToggleImgui
        game_state.freecam_key_mappings[.W] = .TranslateFreecamForward
        game_state.freecam_key_mappings[.S] = .TranslateFreecamBack
        game_state.freecam_key_mappings[.A] = .TranslateFreecamLeft
        game_state.freecam_key_mappings[.D] = .TranslateFreecamRight
        game_state.freecam_key_mappings[.Q] = .TranslateFreecamDown
        game_state.freecam_key_mappings[.E] = .TranslateFreecamUp
        game_state.freecam_key_mappings[.LSHIFT] = .Sprint
        game_state.freecam_key_mappings[.LCTRL] = .Crawl
        game_state.freecam_key_mappings[.SPACE] = .PlayerJump
        game_state.freecam_key_mappings[.BACKSLASH] = .FrameAdvance
        game_state.freecam_key_mappings[.PAUSE] = .Resume
        game_state.freecam_key_mappings[.F] = .FullscreenHotkey

        game_state.character_key_mappings[.ESCAPE] = .ToggleImgui
        game_state.character_key_mappings[.W] = .PlayerTranslateForward
        game_state.character_key_mappings[.S] = .PlayerTranslateBack
        game_state.character_key_mappings[.A] = .PlayerTranslateLeft
        game_state.character_key_mappings[.D] = .PlayerTranslateRight
        game_state.character_key_mappings[.LSHIFT] = .Sprint
        game_state.character_key_mappings[.LCTRL] = .Crawl
        game_state.character_key_mappings[.SPACE] = .PlayerJump
        game_state.character_key_mappings[.BACKSLASH] = .FrameAdvance
        game_state.character_key_mappings[.PAUSE] = .Resume
        game_state.character_key_mappings[.F] = .FullscreenHotkey
        game_state.character_key_mappings[.R] = .PlayerReset
        game_state.character_key_mappings[.E] = .PlayerShoot

        game_state.button_mappings[.A] = .PlayerJump
        game_state.button_mappings[.X] = .PlayerShoot
        game_state.button_mappings[.Y] = .PlayerReset
        game_state.button_mappings[.LEFTSHOULDER] = .TranslateFreecamDown
        game_state.button_mappings[.RIGHTSHOULDER] = .TranslateFreecamUp



        // Hardcoded default mouse mappings
        //mouse_mappings[sdl2.BUTTON_LEFT] = .PlayerShoot
        game_state.mouse_mappings[sdl2.BUTTON_RIGHT] = .ToggleMouseLook
    }

    game_state.rng_seed = time.now()._nsec

    {
        idx, ok := load_sound_effect(audio_system, "data/audio/boing.ogg", global_allocator)
        if !ok {
            log.error("Failed to load sound effect")
        }
        game_state.jump_sound = idx
    }
    {
        idx, ok := load_sound_effect(audio_system, "data/audio/shoot.ogg", global_allocator)
        if !ok {
            log.error("Failed to load sound effect")
        }
        game_state.shoot_sound = idx
    }
    {
        idx, ok := load_sound_effect(audio_system, "data/audio/orb_final.ogg", global_allocator)
        if !ok {
            log.error("Failed to load sound effect")
        }
        game_state.coin_sound = idx
    }
    {
        idx, ok := load_sound_effect(audio_system, "data/audio/ow.ogg", global_allocator)
        if !ok {
            log.error("Failed to load sound effect")
        }
        game_state.ow_sound = idx
    }

    // Load skybox
    {
        scoped_event(&profiler, "Load skybox")
        // @TODO: Load this from level file
        path := "data/images/beach.dds"
        file_bytes, image_ok := os.read_entire_file(path, context.allocator)

        if image_ok {
            // Read DDS header
            dds_header, ok := dds_load_header(file_bytes)
            if !ok {
                log.error("Unable to read DDS header")
            }
    
            is_cubemap := .D3D11_RESOURCE_MISC_TEXTURECUBE in dds_header.misc_flag
            image_flags : vk.ImageCreateFlags = {.CUBE_COMPATIBLE} if is_cubemap else {}
            image_format := dxgi_to_vulkan_format(dds_header.dxgi_format)
            image_info := vkw.Image_Create {
                flags = image_flags,
                image_type = .D2,
                format = image_format,
                extent = {
                    width = dds_header.width,
                    height = dds_header.height,
                    depth = dds_header.depth,
                },
                has_mipmaps = dds_header.mipmap_count > 1,
                mip_count = dds_header.mipmap_count,
                array_layers = 6,
                samples = {._1},
                tiling = .OPTIMAL,
                usage = {.SAMPLED},
                alloc_flags = nil,
                name = "Skybox"
            }
            image_bytes := file_bytes[TRUE_DDS_HEADER_SIZE:]
            image_handle, create_ok := vkw.sync_create_image_with_data(gd, &image_info, image_bytes[:])

            if create_ok {
                renderer.cpu_uniforms.skybox_idx = image_handle.index
            }
        }
    }

    return game_state
}

gamestate_new_scene :: proc(
    game_state: ^GameState,
    gd: ^vkw.GraphicsDevice,
    renderer: ^Renderer,
    user_config: ^UserConfiguration,
    scene_allocator := context.allocator
) {
    // Initialize data-oriented tables
    game_state._next_id = 0                 // All entities are deleted on new_scene(), so set ids back to 0
    game_state.transforms = make(map[EntityID]Transform, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.transform_deltas = make(map[EntityID]TransformDelta, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.cameras = make(map[EntityID]Camera, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.lookat_controllers = make(map[EntityID]LookatController, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.character_controllers = make(map[EntityID]CharacterController, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.enemy_ais = make(map[EntityID]EnemyAI, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.hovering_enemies = make(map[EntityID]HoveringEnemy, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.thrown_enemy_ais = make(map[EntityID]ThrownEnemyAI, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.spherical_bodies = make(map[EntityID]SphericalBody, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.triangle_meshes = make(map[EntityID]TriangleMesh, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.static_models = make(map[EntityID]StaticModelInstance, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.skinned_models = make(map[EntityID]SkinnedModelInstance, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.debug_models = make(map[EntityID]DebugModelInstance, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    
    game_state.looping_animations = make([dynamic]EntityID, 0, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)
    game_state.coins = make([dynamic]EntityID, 0, DEFAULT_COMPONENT_MAP_CAPACITY, scene_allocator)

    // Initialize player character
    {
        id := gamestate_next_id(game_state)
        game_state.player_id = id

        game_state.transforms[id] = Transform {
            scale = 1.0,
        }
        game_state.spherical_bodies[id] = SphericalBody {
            velocity = {},
            radius = 0.6,
            gravity_scale = CHARACTER_HEAVY_GRAVITY,
            state = .Falling
        }
        game_state.character_controllers[id] = CharacterController {
            acceleration = {},
            deceleration_speed = 0.1,
            move_speed = 7.0,
            sprint_speed = 14.0,
            jump_speed = 10.0,
            bullet_travel_time = 0.144,
            health = CHARACTER_MAX_HEALTH,
            vortex_t = 0.144 + 1.0,
            anim_speed = 0.856,
            time_last_damaged = {},
            flags = {}
        }

        // Load animated test glTF model
        skinned_model: SkinnedModelHandle
        {
            path : cstring = "data/models/CesiumMan.glb"
            skinned_model = load_gltf_skinned_model(gd, renderer, path, scene_allocator)
        }
        game_state.skinned_models[id] = SkinnedModelInstance {
            handle = skinned_model,
            pos_offset = {0.0, 0.0, -0.6},
            flags = {}
        }

    }

    // game_state.character = Character {
    //     collision = {
    //         position = game_state.character_start,
    //         radius = 0.6
    //     },
    //     gravity_factor = 1.0,
    //     deceleration_speed = 0.1,
    //     facing = {0.0, 1.0, 0.0},
    //     move_speed = 7.0,
    //     sprint_speed = 14.0,
    //     jump_speed = 10.0,
    //     anim_speed = 0.856,
    //     model = skinned_model,

    //     bullet_travel_time = 0.144,
    // }

    // Initialize viewport camera
    {
        id := gamestate_next_id(game_state)
        game_state.viewport_camera_id = id

        game_state.transforms[id] = Transform {
            position = {
                f32(user_config.floats[.FreecamX]),
                f32(user_config.floats[.FreecamY]),
                f32(user_config.floats[.FreecamZ])
            }
        }
        game_state.cameras[id] = Camera {
            fov_radians = f32(user_config.floats[.CameraFOV]),
            nearplane = 0.1 / math.sqrt_f32(2.0),
            farplane = 1_000_000.0,
            yaw = f32(user_config.floats[.FreecamYaw]),
            pitch = f32(user_config.floats[.FreecamPitch]),
        }
        if user_config.flags[.FollowCam] {
            game_state.lookat_controllers[id] = LookatController {
                target = game_state.player_id,
                distance = 5.0
            }
        }
    }

    game_state.freecam_speed_multiplier = 5.0
    game_state.freecam_slow_multiplier = 1.0 / 5.0

    //game_state.camera_follow_point = game_state.character.collision.position
    game_state.camera_follow_speed = 6.0
    
    // Load icosphere mesh for debug visualization
    game_state.sphere_mesh = load_gltf_static_model(gd, renderer, "data/models/icosphere.glb", scene_allocator)

    // Load enemy mesh
    game_state.enemy_mesh = load_gltf_static_model(gd, renderer, "data/models/majoras_moon.glb", scene_allocator)
    
    game_state.coin_mesh = load_gltf_static_model(gd, renderer, "data/models/precursor_orb.glb", scene_allocator)
}

gamestate_next_id :: proc(gamestate: ^GameState) -> EntityID {
    assert(gamestate._next_id < max(u32), "Overflowed entity id!")
    r := gamestate._next_id
    gamestate._next_id += 1
    return EntityID(r)
}

game_tick :: proc(game_state: ^GameState, gd: ^vkw.GraphicsDevice, renderer: ^Renderer, output_verbs: OutputVerbs, audio_system: ^AudioSystem, dt: f32) {
    // Determine if we're simulating a tick of game logic this frame
    do_this_frame := !game_state.paused
    if output_verbs.bools[.FrameAdvance] {
        do_this_frame = true
        game_state.paused = true
    }
    if output_verbs.bools[.Resume] {
        game_state.paused = !game_state.paused
    }

    if do_this_frame {
        game_state.character_damage_events = make([dynamic]DamageEvent, 0, DEFAULT_COMPONENT_MAP_CAPACITY, context.temp_allocator)

        tick_character_controllers(game_state, gd, renderer, output_verbs, audio_system, dt)
        tick_coins(game_state, audio_system)
        tick_looping_animations(game_state, renderer^, dt)
        tick_transform_deltas(game_state, dt)
        tick_thrown_enemies(game_state)
        tick_spherical_bodies(game_state, dt)
        tick_enemy_ai(game_state, audio_system, dt)
        tick_hovering_enemies(game_state, dt)
        tick_damage_events(game_state, audio_system)
    }
}


ComponentFlags :: bit_set[ComponentFlag]
ComponentFlag :: enum {
    Transform,
    TransformDelta,
    Camera,
    LookatController,
    CharacterController,
    EnemyAI,
    HoveringEnemy,
    ThrownEnemyAI,
    SphericalBody,
    TriangleMesh,
    StaticModel,
    SkinnedModel,
    DebugModel,
}

// Returns the size in bytes of component when serialized
get_serialized_size :: proc(renderer: Renderer, component: $ComponentType) -> int {
    when ComponentType == StaticModelInstance {
        size := 0
        size += size_of(component.pos_offset)
        size += size_of(component.flags)

        {
            model := get_static_model(&renderer, component.handle)
            size += len(model.name)
        }

        return size
    } else when ComponentType == SkinnedModelInstance {
        size := 0
        size += size_of(component.pos_offset)
        size += size_of(component.flags)
        size += size_of(component.anim_idx)

        {
            model := get_skinned_model(&renderer, component.handle)
            size += len(model.name)
        }

        return size
        
    } else when ComponentType == DebugModelInstance {
        size := 0
        size += size_of(component.pos_offset)
        size += size_of(component.color)
        size += size_of(component.scale)

        {
            model := get_static_model(&renderer, component.handle)
            size += len(model.name)
        }

        return size        
    } else {
        // Type doesn't need special handling
        return size_of(ComponentType)
    }
}

load_level_file :: legacy_load_level_file

new_load_level_file :: proc(
    gd: ^vkw.GraphicsDevice,
    renderer: ^Renderer,
    audio_system: ^AudioSystem,
    game_state: ^GameState,
    user_config: ^UserConfiguration,
    path: string,
    scene_allocator := context.allocator
) -> bool {
    // Audio lock while loading level data
    sdl2.LockAudioDevice(audio_system.device_id)
    defer sdl2.UnlockAudioDevice(audio_system.device_id)

    vkw.device_wait_idle(gd)

    free_all(context.temp_allocator)
    free_all(scene_allocator)
    audio_new_scene(audio_system)
    new_scene(renderer, scene_allocator)
    gamestate_new_scene(game_state, gd, renderer, user_config)

    lvl_data: []byte
    {
        err: os2.Error
        lvl_data, err = os2.read_entire_file(path, context.temp_allocator)
        if err != nil {
            log.errorf("Error reading entire level file \"%v\": %v", path, err)
            return false
        }
    }

    read_thing_from_buffer :: proc(buffer: []byte, $type: typeid, read_head: ^u32) -> type {
        thing: type
        mem.copy_non_overlapping(&thing, &buffer[read_head^], size_of(type))
        read_head^ += size_of(type)
        return thing
    }

    read_string_from_buffer :: proc(buffer: []byte, read_head: ^u32) -> string {
        // Read the u32 string length, then read the string itself
        str_len := read_thing_from_buffer(buffer, u32, read_head)
        s := strings.string_from_ptr(&buffer[read_head^], int(str_len))
        read_head^ += str_len
        return s
    }

    read_component_map :: proc(buffer: []byte, components: ^map[EntityID]$T, head: ^u32) -> u32 {
        // Read component count
        count := read_thing_from_buffer(buffer, u32, head)

        largest_id: u32
        for i in 0..<count {
            id := read_thing_from_buffer(buffer, EntityID, head)
            comp := read_thing_from_buffer(buffer, T, head)
            components[id] = comp
            if u32(id) > largest_id {
                largest_id = u32(id)
            }
        }

        // We want to return the largest id in order to initialize game_state._next_id
        return largest_id
        
        // size := u32(len(components))
        // write_thing_to_buffer(buffer, &size, head)

        // for id, &comp in components {
        //     id := id
        //     write_thing_to_buffer(buffer[:], &id, head)
        //     write_thing_to_buffer(buffer[:], &comp, head)
        // }
    }

    read_naked_entities :: proc(buffer: []byte, ids: []EntityID, head: ^u32) {
        
        
        
        // size := u32(len(ids))
        // write_thing_to_buffer(buffer, &size, head)
        // if size == 0 {
        //     return
        // }

        // len_bytes := size * size_of(EntityID)
        // mem.copy_non_overlapping(&buffer[head^], &ids[0], int(len_bytes))
        // head^ += len_bytes
    }

    read_head : u32 = 0
    
    // Read components in order
    read_component_map(lvl_data, &game_state.transforms, &read_head)
    read_component_map(lvl_data, &game_state.transform_deltas, &read_head)
    read_component_map(lvl_data, &game_state.cameras, &read_head)
    read_component_map(lvl_data, &game_state.lookat_controllers, &read_head)
    read_component_map(lvl_data, &game_state.character_controllers, &read_head)
    read_component_map(lvl_data, &game_state.enemy_ais, &read_head)
    read_component_map(lvl_data, &game_state.hovering_enemies, &read_head)
    read_component_map(lvl_data, &game_state.thrown_enemy_ais, &read_head)
    read_component_map(lvl_data, &game_state.spherical_bodies, &read_head)
    read_component_map(lvl_data, &game_state.triangle_meshes, &read_head)
    read_component_map(lvl_data, &game_state.static_models, &read_head)
    read_component_map(lvl_data, &game_state.skinned_models, &read_head)
    read_component_map(lvl_data, &game_state.debug_models, &read_head)
    

    return true
}

legacy_load_level_file :: proc(
    gd: ^vkw.GraphicsDevice,
    renderer: ^Renderer,
    audio_system: ^AudioSystem,
    game_state: ^GameState,
    user_config: ^UserConfiguration,
    path: string,
    scene_allocator := context.allocator
) -> bool {
    scoped_event(&profiler, "Load level file")
    // Audio lock while loading level data
    sdl2.LockAudioDevice(audio_system.device_id)
    defer sdl2.UnlockAudioDevice(audio_system.device_id)

    vkw.device_wait_idle(gd)

    free_all(scene_allocator)
    audio_new_scene(audio_system, scene_allocator)
    new_scene(renderer)
    gamestate_new_scene(game_state, gd, renderer, user_config)

    player_tform := &game_state.transforms[game_state.player_id]

    lvl_bytes, lvl_err := os2.read_entire_file(path, context.temp_allocator)
    if lvl_err != nil {
        log.errorf("Error reading entire level file \"%v\": %v", path, lvl_err)
        return false
    }

    read_thing_from_buffer :: proc(buffer: []byte, $type: typeid, read_head: ^u32) -> type {
        thing: type
        mem.copy_non_overlapping(&thing, &buffer[read_head^], size_of(type))
        read_head^ += size_of(type)
        return thing
    }

    read_string_from_buffer :: proc(buffer: []byte, read_head: ^u32) -> string {
        // Read the u32 string length, then read the string itself
        str_len := read_thing_from_buffer(buffer, u32, read_head)
        s := strings.string_from_ptr(&buffer[read_head^], int(str_len))
        read_head^ += str_len
        return s
    }

    file_size := u32(len(lvl_bytes))
    read_head : u32 = 0

    // Character start
    game_state.level_start = read_thing_from_buffer(lvl_bytes, type_of(game_state.level_start), &read_head)
    player_tform.position = game_state.level_start
    
    path_builder: strings.Builder
    strings.builder_init(&path_builder, context.temp_allocator)

    // Repeatedly parse level blocks
    for read_head < file_size {
        block := read_thing_from_buffer(lvl_bytes, LevelBlock, &read_head)
        switch block {
            case .BgmFile: {
                bgm_name := read_string_from_buffer(lvl_bytes, &read_head)
                fmt.sbprintf(&path_builder, "data/audio/%v.ogg", bgm_name)
                path, _ := strings.to_cstring(&path_builder)
                game_state.bgm_id, _ = open_music_file(audio_system, path)
                strings.builder_reset(&path_builder)
            }
            case .DirectionalLights: {
                count := read_thing_from_buffer(lvl_bytes, u32, &read_head)
                renderer.cpu_uniforms.directional_light_count = count
                for i in 0..<count {
                    light: DirectionalLight
                    light.direction = read_thing_from_buffer(lvl_bytes, hlsl.float3, &read_head)
                    light.color = read_thing_from_buffer(lvl_bytes, hlsl.float3, &read_head)
                    renderer.cpu_uniforms.directional_lights[i] = light
                }
            }
            case .Terrain: {
                // Terrain pieces
                ter_len := read_thing_from_buffer(lvl_bytes, u32, &read_head)
                for _ in 0..<ter_len {
                    name := read_string_from_buffer(lvl_bytes, &read_head)
                    fmt.sbprintf(&path_builder, "data/models/%v", name)
                    path, _ := strings.to_cstring(&path_builder)
                    model := load_gltf_static_model(gd, renderer, path)
            
                    position := read_thing_from_buffer(lvl_bytes, hlsl.float3, &read_head)
                    rotation := read_thing_from_buffer(lvl_bytes, quaternion128, &read_head)
                    scale := read_thing_from_buffer(lvl_bytes, f32, &read_head)
                    mmat := translation_matrix(position) * linalg.to_matrix4(rotation) * uniform_scaling_matrix(scale)
                    
                    positions := get_glb_positions(path)
                    collision := new_static_triangle_mesh(positions[:], mmat)

                    id := gamestate_next_id(game_state)
                    game_state.triangle_meshes[id] = collision
                    game_state.transforms[id] = Transform {
                        position = position,
                        rotation = rotation,
                        scale = scale,
                    }
                    game_state.static_models[id] = StaticModelInstance {
                        handle = model,
                        flags = {}
                    }

                    // append(&game_state.terrain_pieces, TerrainPiece {
                    //     collision = collision,
                    //     position = position,
                    //     rotation = rotation,
                    //     scale = scale,
                    //     model = model,
                    // })
                    strings.builder_reset(&path_builder)
                }
            }
            case .StaticScenery: {
                // Static scenery
                stat_len := read_thing_from_buffer(lvl_bytes, u32, &read_head)
                for _ in 0..<stat_len {
                    name := read_string_from_buffer(lvl_bytes, &read_head)
                    fmt.sbprintf(&path_builder, "data/models/%v", name)
                    path, _ := strings.to_cstring(&path_builder)
                    model := load_gltf_static_model(gd, renderer, path)
            
                    position := read_thing_from_buffer(lvl_bytes, hlsl.float3, &read_head)
                    rotation := read_thing_from_buffer(lvl_bytes, quaternion128, &read_head)
                    scale := read_thing_from_buffer(lvl_bytes, f32, &read_head)

                    id := gamestate_next_id(game_state)
                    game_state.transforms[id] = Transform {
                        position = position,
                        rotation = rotation,
                        scale = scale,
                    }
                    game_state.static_models[id] = StaticModelInstance {
                        handle = model,
                        flags = {},
                    }

                    strings.builder_reset(&path_builder)
                }
            }
            case .AnimatedScenery: {
                // Animated scenery
                anim_len := read_thing_from_buffer(lvl_bytes, u32, &read_head)
                for _ in 0..<anim_len {
                    name := read_string_from_buffer(lvl_bytes, &read_head)
                    fmt.sbprintf(&path_builder, "data/models/%v", name)
                    path, _ := strings.to_cstring(&path_builder)
                    model := load_gltf_skinned_model(gd, renderer, path, scene_allocator)
            
                    position := read_thing_from_buffer(lvl_bytes, hlsl.float3, &read_head)
                    rotation := read_thing_from_buffer(lvl_bytes, quaternion128, &read_head)
                    scale := read_thing_from_buffer(lvl_bytes, f32, &read_head)

                    id := gamestate_next_id(game_state)
                    game_state.transforms[id] = Transform {
                        position = position,
                        rotation = rotation,
                        scale = scale
                    }
                    game_state.skinned_models[id] = SkinnedModelInstance {
                        handle = model,
                        flags = {}
                    }
                    append(&game_state.looping_animations, id)

                    strings.builder_reset(&path_builder)
                }
            }
            case .Enemies: {
                // Enemies
                enemy_len := read_thing_from_buffer(lvl_bytes, u32, &read_head)
                for _ in 0..<enemy_len {
                    position := read_thing_from_buffer(lvl_bytes, hlsl.float3, &read_head)
                    scale := read_thing_from_buffer(lvl_bytes, f32, &read_head)
                    ai_state := read_thing_from_buffer(lvl_bytes, EnemyState, &read_head)

                    id: EntityID
                    if ai_state == .Hovering {
                        id = new_hovering_enemy(game_state, position, scale)
                    } else {
                        id = new_enemy(game_state, position, scale, ai_state)
                    }
                }

            }
            case .Coins: {
                coin_len := read_thing_from_buffer(lvl_bytes, u32, &read_head)
                for _ in 0..<coin_len {
                    p := read_thing_from_buffer(lvl_bytes, hlsl.float3, &read_head)

                    id := gamestate_next_id(game_state)
                    game_state.transforms[id] = Transform {
                        position = p,
                        scale = 0.6,
                    }
                    game_state.static_models[id] = StaticModelInstance {
                        handle = game_state.coin_mesh,
                        flags = {}
                    }

                    append(&game_state.coins, id)
                }
            }
        }
    }

    path_base := filepath.stem(path)
    path_clone, err := strings.clone(path_base)
    if err != nil {
        log.errorf("Error allocating current_level_path string: %v", err)
    }
    game_state.current_level = path_clone
    return true
}

save_level_file :: new_save_level_file

new_save_level_file :: proc(
    game_state: ^GameState,
    renderer: ^Renderer,
    audio_system: AudioSystem,
    path: string,
    temp_allocator := context.temp_allocator
) {

    // Strings in the StringTable are written back-to-back when serialized
    // Components can have a pair of u32 (offset, size) to address into it
    StringTable :: struct {
        data: [dynamic]StringTableEntry,
        string_map: map[string]int,
        total_len: int
    }
    StringTableEntry :: struct {
        s: string,
        offset: int,
    }
    string_table_init :: proc(capacity: int, allocator := context.allocator) -> StringTable {
        table: StringTable
        table.data = make([dynamic]StringTableEntry, 0, capacity, allocator)
        table.string_map = make(map[string]int, capacity, allocator)
        return table
    }
    string_table_append :: proc(table: ^StringTable, elem: string) -> StringTableEntry {
        idx: int
        ok: bool
        idx, ok = table.string_map[elem]
        if ok {
            return table.data[idx]
        } else {
            entry: StringTableEntry
            entry.s = elem
            entry.offset = table.total_len
            table.total_len += len(elem)
            append(&table.data, entry)
            table.string_map[elem] = len(table.data) - 1
            return entry
        }
    }

    // Idea: For each entity, store id followed by component mask followed by component data
    // Better idea: Just store components along with their ids

    calc_level_file_size :: proc(game_state: GameState, renderer: Renderer) -> u32 {
        final_size := 0

        // Component data + counts
        // final_size += len(game_state.transforms) * (get_serialized_size(renderer, Transform) + size_of(EntityID))
        // final_size += size_of(u32)
        // final_size += len(game_state.transform_deltas) * (get_serialized_size(renderer, TransformDelta) + size_of(EntityID))
        // final_size += size_of(u32)
        // final_size += len(game_state.cameras) * (get_serialized_size(renderer, Camera) + size_of(EntityID))
        // final_size += size_of(u32)
        // final_size += len(game_state.lookat_controllers) * (get_serialized_size(renderer, LookatController) + size_of(EntityID))
        // final_size += size_of(u32)
        // final_size += len(game_state.character_controllers) * (get_serialized_size(renderer, CharacterController) + size_of(EntityID))
        // final_size += size_of(u32)
        // final_size += len(game_state.enemy_ais) * (get_serialized_size(renderer, EnemyAI) + size_of(EntityID))
        // final_size += size_of(u32)
        // final_size += len(game_state.hovering_enemies) * (get_serialized_size(renderer, HoveringEnemy) + size_of(EntityID))
        // final_size += size_of(u32)
        // final_size += len(game_state.thrown_enemy_ais) * (get_serialized_size(renderer, ThrownEnemyAI) + size_of(EntityID))
        // final_size += size_of(u32)
        // final_size += len(game_state.spherical_bodies) * (get_serialized_size(renderer, SphericalBody) + size_of(EntityID))
        // final_size += size_of(u32)
        // final_size += len(game_state.triangle_meshes) * (get_serialized_size(renderer, TriangleMesh) + size_of(EntityID))
        // final_size += size_of(u32)
        // final_size += len(game_state.static_models) * (get_serialized_size(renderer, StaticModelInstance) + size_of(EntityID))
        // final_size += size_of(u32)
        // final_size += len(game_state.skinned_models) * (get_serialized_size(renderer, SkinnedModelInstance) + size_of(EntityID))
        // final_size += size_of(u32)
        // final_size += len(game_state.debug_models) * (get_serialized_size(renderer, DebugModelInstance) + size_of(EntityID))
        // final_size += size_of(u32)

        // Special entities that don't need extra state
        final_size += size_of(u32)
        final_size += len(game_state.looping_animations) * size_of(EntityID)
        final_size += size_of(u32)
        final_size += len(game_state.coins) * size_of(EntityID)

        // String table


        return u32(final_size)
    }

    write_thing_to_buffer :: proc(buffer: []byte, ptr: ^$T, head: ^u32) {
        amount := size_of(T)
        mem.copy_non_overlapping(&buffer[head^], ptr, amount)
        head^ += u32(amount)
    }

    write_string_to_buffer :: proc(buffer: []byte, st: string, head: ^u32) {
        amount := u32(len(st))
        write_thing_to_buffer(buffer, &amount, head)
        mem.copy_non_overlapping(&buffer[head^], raw_data(st), int(amount))
        head^ += amount
    }

    write_component_map :: proc(buffer: []byte, components: map[EntityID]$T, head: ^u32) {
        size := u32(len(components))
        write_thing_to_buffer(buffer, &size, head)

        for id, &comp in components {
            id := id
            write_thing_to_buffer(buffer[:], &id, head)

            when T == StaticModelInstance {

            } else {
                write_thing_to_buffer(buffer[:], &comp, head)
            }
        }
    }

    write_naked_entities :: proc(buffer: []byte, ids: []EntityID, head: ^u32) {
        size := u32(len(ids))
        write_thing_to_buffer(buffer, &size, head)
        if size == 0 {
            return
        }

        len_bytes := size * size_of(EntityID)
        mem.copy_non_overlapping(&buffer[head^], &ids[0], int(len_bytes))
        head^ += len_bytes
    }
    
    // Set up intermediate buffer for gathering file data
    total_size := calc_level_file_size(game_state^, renderer^)
    write_head : u32 = 0
    output_buffer := make([dynamic]byte, total_size, temp_allocator)

    string_table := string_table_init(64, temp_allocator)


    // Write components to file
    write_component_map(output_buffer[:], game_state.transforms, &write_head)
    write_component_map(output_buffer[:], game_state.transform_deltas, &write_head)
    write_component_map(output_buffer[:], game_state.cameras, &write_head)
    write_component_map(output_buffer[:], game_state.lookat_controllers, &write_head)
    write_component_map(output_buffer[:], game_state.character_controllers, &write_head)
    write_component_map(output_buffer[:], game_state.enemy_ais, &write_head)
    write_component_map(output_buffer[:], game_state.hovering_enemies, &write_head)
    write_component_map(output_buffer[:], game_state.thrown_enemy_ais, &write_head)
    write_component_map(output_buffer[:], game_state.spherical_bodies, &write_head)
    write_component_map(output_buffer[:], game_state.triangle_meshes, &write_head)
    write_component_map(output_buffer[:], game_state.static_models, &write_head)
    write_component_map(output_buffer[:], game_state.skinned_models, &write_head)
    write_component_map(output_buffer[:], game_state.debug_models, &write_head)

    // Write the looping animations and coins lists
    write_naked_entities(output_buffer[:], game_state.looping_animations[:], &write_head)
    write_naked_entities(output_buffer[:], game_state.coins[:], &write_head)

    assert(write_head == total_size)

    // Actually write the buffer to the file
    lvl_file, lvl_err := create_write_file(path)
    if lvl_err != nil {
        log.errorf("Error opening level file: %v", lvl_err)
    }
    defer os.close(lvl_file)

    _, err := os.write(lvl_file, output_buffer[:])
    if err != nil {
        log.errorf("Error writing level data: %v", err)
    }

    base_path := filepath.stem(path)
    path_clone, p_err := strings.clone(base_path)
    if p_err != nil {
        log.errorf("Error allocating current_level_path string: %v", err)
    }
    //game_state.current_level = path_clone

    log.infof("Finished saving level to \"%v\"", path)
}

legacy_save_level_file :: proc(gamestate: ^GameState, renderer: ^Renderer, audio_system: AudioSystem, path: string) {
    mesh_data_size :: proc(renderer: ^Renderer, mesh: $T) -> int {
        model := get_static_model(renderer, mesh.model)
        s := 0
        s += size_of(u32)
        s += len(model.name)
        s += size_of(mesh.position)
        s += size_of(mesh.rotation)
        s += size_of(mesh.scale)
        return s
    }

    bgm := &audio_system.music_files[gamestate.bgm_id]

    output_size := 0

    // Character spawn
    output_size += size_of(gamestate.level_start)
    
    // BGM music file name
    output_size += size_of(u8)      //block
    output_size += size_of(u32)
    output_size += len(bgm.name)

    // Directional lights
    output_size += size_of(u8)      //block
    output_size += size_of(u32)     // Directional light count
    output_size += 2 * size_of(hlsl.float3) * int(renderer.cpu_uniforms.directional_light_count)

    // Terrain pieces
    // if len(gamestate.terrain_pieces) > 0 {
    //     output_size += size_of(u8)
    //     output_size += size_of(u32)
    // }
    // for piece in gamestate.terrain_pieces {
    //     output_size += mesh_data_size(renderer, piece)
    // }

    // Static scenery
    // if len(gamestate.static_scenery) > 0 {
    //     output_size += size_of(u8)
    //     output_size += size_of(u32)
    // }
    // for scenery in gamestate.static_scenery {
    //     output_size += mesh_data_size(renderer, scenery)
    // }

    // Animated scenery
    // if len(gamestate.animated_scenery) > 0 {
    //     output_size += size_of(u8)
    //     output_size += size_of(u32)
    // }
    // for scenery in gamestate.animated_scenery {
    //     model := get_skinned_model(renderer, scenery.model)
    //     s := 0
    //     s += size_of(u32)
    //     s += len(model.name)
    //     s += size_of(scenery.position)
    //     s += size_of(scenery.rotation)
    //     s += size_of(scenery.scale)
    //     output_size += s
    // }

    // Enemies
    // if len(gamestate.enemies) > 0 {
    //     output_size += size_of(u8)
    //     output_size += size_of(u32)
    // }
    // for enemy in gamestate.enemies {
    //     output_size += size_of(enemy.position)
    //     output_size += size_of(enemy.collision_radius)
    //     output_size += size_of(enemy.ai_state)
    // }

    // Coins
    // if len(gamestate.coins) > 0 {
    //     output_size += size_of(u8)
    //     output_size += size_of(u32)
    // }
    // for coin in gamestate.coins {
    //     output_size += size_of(coin.position)
    // }
    
    write_head : u32 = 0
    raw_output_buffer := make([dynamic]byte, output_size, context.temp_allocator)

    write_thing_to_buffer :: proc(buffer: []byte, ptr: ^$T, head: ^u32) {
        amount := size_of(T)
        mem.copy_non_overlapping(&buffer[head^], ptr, amount)
        head^ += u32(amount)
    }

    write_string_to_buffer :: proc(buffer: []byte, st: string, head: ^u32) {
        amount := u32(len(st))
        write_thing_to_buffer(buffer, &amount, head)
        mem.copy_non_overlapping(&buffer[head^], raw_data(st), int(amount))
        head^ += amount
    }

    write_mesh_to_buffer :: proc(renderer: ^Renderer, buffer: []byte, mesh: ^$T, head: ^u32) {
        when T == AnimatedScenery {
            model := get_skinned_model(renderer, mesh.model)
            write_string_to_buffer(buffer, model.name, head)
        } else {
            model := get_static_model(renderer, mesh.model)
            write_string_to_buffer(buffer, model.name, head)
        }

        write_thing_to_buffer(buffer, &mesh.position, head)
        write_thing_to_buffer(buffer, &mesh.rotation, head)
        write_thing_to_buffer(buffer, &mesh.scale, head)
    }

    write_thing_to_buffer(raw_output_buffer[:], &gamestate.level_start, &write_head)

    block: LevelBlock

    {
        block = .BgmFile
        write_thing_to_buffer(raw_output_buffer[:], &block, &write_head)
        write_string_to_buffer(raw_output_buffer[:], bgm.name, &write_head)
    }

    {
        block = .DirectionalLights
        write_thing_to_buffer(raw_output_buffer[:], &block, &write_head)
        write_thing_to_buffer(raw_output_buffer[:], &renderer.cpu_uniforms.directional_light_count, &write_head)
        for i in 0..<renderer.cpu_uniforms.directional_light_count {
            light := &renderer.cpu_uniforms.directional_lights[i]
            write_thing_to_buffer(raw_output_buffer[:], &light.direction, &write_head)
            write_thing_to_buffer(raw_output_buffer[:], &light.color, &write_head)
        }
    }

    // if len(gamestate.terrain_pieces) > 0 {
    //     block = .Terrain
    //     write_thing_to_buffer(raw_output_buffer[:], &block, &write_head)
    //     ter_len := u32(len(gamestate.terrain_pieces))
    //     write_thing_to_buffer(raw_output_buffer[:], &ter_len, &write_head)
    // }
    // for &piece in gamestate.terrain_pieces {
    //     write_mesh_to_buffer(renderer, raw_output_buffer[:], &piece, &write_head)
    // }

    // if len(gamestate.static_scenery) > 0 {
    //     block = .StaticScenery
    //     write_thing_to_buffer(raw_output_buffer[:], &block, &write_head)
    //     static_len := u32(len(gamestate.static_scenery))
    //     write_thing_to_buffer(raw_output_buffer[:], &static_len, &write_head)
    // }
    // for &scenery in gamestate.static_scenery {
    //     write_mesh_to_buffer(renderer, raw_output_buffer[:], &scenery, &write_head)
    // }

    // if len(gamestate.animated_scenery) > 0 {
    //     block = .AnimatedScenery
    //     write_thing_to_buffer(raw_output_buffer[:], &block, &write_head)
    //     anim_len := u32(len(gamestate.animated_scenery))
    //     write_thing_to_buffer(raw_output_buffer[:], &anim_len, &write_head)
    // }
    // for &scenery in gamestate.animated_scenery {
    //     write_mesh_to_buffer(renderer, raw_output_buffer[:], &scenery, &write_head)
    // }

    // if len(gamestate.enemies) > 0 {
    //     block = .Enemies
    //     write_thing_to_buffer(raw_output_buffer[:], &block, &write_head)
    //     enemy_len := u32(len(gamestate.enemies))
    //     write_thing_to_buffer(raw_output_buffer[:], &enemy_len, &write_head)
    // }
    // for &enemy in gamestate.enemies {
    //     write_thing_to_buffer(raw_output_buffer[:], &enemy.position, &write_head)
    //     write_thing_to_buffer(raw_output_buffer[:], &enemy.collision_radius, &write_head)
    //     write_thing_to_buffer(raw_output_buffer[:], &enemy.ai_state, &write_head)
    // }

    // if len(gamestate.coins) > 0 {
    //     block = .Coins
    //     write_thing_to_buffer(raw_output_buffer[:], &block, &write_head)
    //     l := u32(len(gamestate.coins))
    //     write_thing_to_buffer(raw_output_buffer[:], &l, &write_head)
    // }
    // for &coin in gamestate.coins {
    //     write_thing_to_buffer(raw_output_buffer[:], &coin.position, &write_head)
    // }

    if write_head != u32(output_size) {
        log.warnf("write_head (%v) not equal to output_size (%v)", write_head, output_size)
    }

    lvl_file, lvl_err := create_write_file(path)
    if lvl_err != nil {
        log.errorf("Error opening level file: %v", lvl_err)
    }
    defer os.close(lvl_file)

    _, err := os.write(lvl_file, raw_output_buffer[:])
    if err != nil {
        log.errorf("Error writing level data: %v", err)
    }

    base_path := filepath.stem(path)
    path_clone, p_err := strings.clone(base_path)
    if p_err != nil {
        log.errorf("Error allocating current_level_path string: %v", err)
    }
    gamestate.current_level = path_clone

    log.infof("Finished saving level to \"%v\"", path)
}

EditorResponseType :: enum {
    MoveTerrainPiece,
    MoveStaticScenery,
    MoveAnimatedScenery,
    MoveEnemy,
    MoveCoin,
    MovePlayerSpawn,
    AddTerrainPiece,
    AddStaticScenery,
    AddAnimatedScenery,
    AddCoin
}
EditorResponse :: struct {
    type: EditorResponseType,
    index: u32
}

scene_editor :: proc(
    game_state: ^GameState,
    gd: ^vkw.GraphicsDevice,
    renderer: ^Renderer,
    gui: ^ImguiState,
    user_config: ^UserConfiguration
) {
    scoped_event(&profiler, "Scene editor update")

    builder: strings.Builder
    strings.builder_init(&builder, context.temp_allocator)
    io := imgui.GetIO()

    show_editor := gui.show_gui && user_config.flags[.SceneEditor]
    if show_editor && imgui.Begin("Scene editor", &user_config.flags[.SceneEditor]) {
        // Spawn point editor
        {
            imgui.DragFloat3("Player spawn", &game_state.level_start, 0.1)
            flag := .ShowPlayerSpawn in game_state.debug_vis_flags
            if imgui.Checkbox("Show player spawn", &flag) {
                game_state.debug_vis_flags ~= {.ShowPlayerSpawn}
            }
            
            resp, ok := game_state.editor_response.(EditorResponse)
            disable := false
            move_text : cstring = "Move player spawn"
            if ok {
                if resp.type == .MovePlayerSpawn {
                    disable = true
                    move_text = "Moving player spawn..."
                }
            }
            imgui.BeginDisabled(disable)
            if imgui.Button(move_text) {
                game_state.editor_response = EditorResponse {
                    type = .MovePlayerSpawn,
                    index = 0
                }
            }
            imgui.EndDisabled()

            imgui.Separator()
        }

        // terrain_piece_clone_idx: Maybe(int)
        // {
        //     objects := &game_state.terrain_pieces
        //     label : cstring = "Terrain pieces"
        //     editor_response := &game_state.editor_response
        //     response_type := EditorResponseType.MoveTerrainPiece
        //     if imgui.CollapsingHeader(label) {
        //         imgui.PushID(label)
        //         if len(objects) == 0 {
        //             imgui.Text("Nothing to see here!")
        //         }
        //         if imgui.Button("Add") {
        //             editor_response^ = EditorResponse {
        //                 type = .AddTerrainPiece,
        //                 index = 0
        //             }
        //         }
        //         imgui.Separator()
        //         for &mesh, i in objects {
        //             imgui.PushIDInt(c.int(i))

        //             model := get_static_model(renderer, mesh.model)
        //             gui_print_value(&builder, "Name", model.name)
        //             gui_print_value(&builder, "Rotation", mesh.rotation)
    
        //             imgui.DragFloat3("Position", &mesh.position, 0.1)
        //             imgui.SliderFloat("Scale", &mesh.scale, 0.0, 50.0)
        
        //             disable_button := false
        //             move_text : cstring = "Move"
        //             obj, obj_ok := editor_response.(EditorResponse)
        //             if obj_ok {
        //                 if obj.type == response_type && obj.index == u32(i) {
        //                     disable_button = true
        //                     move_text = "Moving..."
        //                 }
        //             }
        
        //             imgui.BeginDisabled(disable_button)
        //             if imgui.Button(move_text) {
        //                 editor_response^ = EditorResponse {
        //                     type = response_type,
        //                     index = u32(i)
        //                 }
        //             }
        //             imgui.SameLine()
        //             if imgui.Button("Clone") {
        //                 terrain_piece_clone_idx = i
        //             }
        //             imgui.SameLine()
        //             if imgui.Button("Delete") {
        //                 unordered_remove(objects, i)
        //                 game_state.editor_response = nil
        //             }
        //             if imgui.Button("Rebuild collision mesh") {
        //                 rot := linalg.to_matrix4(mesh.rotation)
        //                 mm := translation_matrix(mesh.position) * rot * scaling_matrix(mesh.scale)
        //                 rebuild_static_triangle_mesh(&game_state.terrain_pieces[i].collision, mm)
        //             }
        //             imgui.EndDisabled()
        //             imgui.Separator()
        
        //             imgui.PopID()
        //         }
        //         imgui.PopID()
        //     }
        // }

        // static_to_clone_idx: Maybe(int)
        // {
        //     objects := &game_state.static_scenery
        //     label : cstring = "Static scenery"
        //     editor_response := &game_state.editor_response
        //     response_type := EditorResponseType.MoveStaticScenery
        //     add_response_type := EditorResponseType.AddStaticScenery
        //     if imgui.CollapsingHeader(label) {
        //         imgui.PushID(label)
        //         if len(objects) == 0 {
        //             imgui.Text("Nothing to see here!")
        //         }
        //         if imgui.Button("Add") {
        //             editor_response^ = EditorResponse {
        //                 type = add_response_type,
        //                 index = 0
        //             }
        //         }
        //         for &mesh, i in objects {
        //             imgui.PushIDInt(c.int(i))
        
        //             model := get_static_model(renderer, mesh.model)
        //             gui_print_value(&builder, "Name", model.name)
        //             gui_print_value(&builder, "Rotation", mesh.rotation)
    
        //             imgui.DragFloat3("Position", &mesh.position, 0.1)
        //             imgui.SliderFloat("Scale", &mesh.scale, 0.0, 50.0)
        
        //             disable_button := false
        //             move_text : cstring = "Move"
        //             obj, obj_ok := editor_response.(EditorResponse)
        //             if obj_ok {
        //                 if obj.type == response_type && obj.index == u32(i) {
        //                     disable_button = true
        //                     move_text = "Moving..."
        //                 }
        //             }
        
        //             imgui.BeginDisabled(disable_button)
        //             if imgui.Button(move_text) {
        //                 editor_response^ = EditorResponse {
        //                     type = response_type,
        //                     index = u32(i)
        //                 }
        //             }
        //             imgui.SameLine()
        //             if imgui.Button("Clone") {
        //                 static_to_clone_idx = i
        //             }
        //             imgui.SameLine()
        //             if imgui.Button("Delete") {
        //                 unordered_remove(objects, i)
        //                 editor_response^ = nil
        //             }
        //             imgui.EndDisabled()
        //             imgui.Separator()
        
        //             imgui.PopID()
        //         }
        //         imgui.PopID()
        //     }
        // }

        // anim_to_clone_idx: Maybe(int)
        // {
        //     objects := &game_state.animated_scenery
        //     label : cstring = "Animated scenery"
        //     editor_response := &game_state.editor_response
        //     response_type := EditorResponseType.MoveAnimatedScenery
        //     add_response_type := EditorResponseType.AddAnimatedScenery
        //     if imgui.CollapsingHeader(label) {
        //         imgui.PushID(label)
        //         if len(objects) == 0 {
        //             imgui.Text("Nothing to see here!")
        //         }
        //         if imgui.Button("Add") {
        //             editor_response^ = EditorResponse {
        //                 type = add_response_type,
        //                 index = 0
        //             }
        //         }
        //         for &mesh, i in objects {
        //             imgui.PushIDInt(c.int(i))
        
        //             model := get_skinned_model(renderer, mesh.model)
        //             gui_print_value(&builder, "Name", model.name)
        //             gui_print_value(&builder, "Rotation", mesh.rotation)
    
        //             imgui.DragFloat3("Position", &mesh.position, 0.1)
        //             imgui.SliderFloat("Scale", &mesh.scale, 0.0, 50.0)
    
        //             anim := &renderer.animations[model.first_animation_idx]
        //             imgui.SliderFloat("Anim t", &mesh.anim_t, 0.0, get_animation_duration(anim))
        //             imgui.SliderFloat("Anim speed", &mesh.anim_speed, 0.0, 20.0)
        
        //             disable_button := false
        //             move_text : cstring = "Move"
        //             obj, obj_ok := editor_response.(EditorResponse)
        //             if obj_ok {
        //                 if obj.type == response_type && obj.index == u32(i) {
        //                     disable_button = true
        //                     move_text = "Moving..."
        //                 }
        //             }

        //             imgui.BeginDisabled(disable_button)
        //             if imgui.Button(move_text) {
        //                 editor_response^ = EditorResponse {
        //                     type = response_type,
        //                     index = u32(i)
        //                 }
        //             }
        //             imgui.SameLine()
        //             if imgui.Button("Clone") {
        //                 anim_to_clone_idx = i
        //             }
        //             imgui.SameLine()
        //             if imgui.Button("Delete") {
        //                 unordered_remove(objects, i)
        //                 editor_response^ = nil
        //             }
        //             imgui.EndDisabled()
        //             imgui.Separator()
        
        //             imgui.PopID()
        //         }
        //         imgui.PopID()
        //     }
        // }

        // enemy_to_clone_idx: Maybe(int)
        // {
        //     objects := &game_state.enemies
        //     label : cstring = "Enemies"
        //     editor_response := &game_state.editor_response
        //     response_type := EditorResponseType.MoveEnemy
        //     if imgui.CollapsingHeader(label) {
        //         imgui.PushID(label)
        //         if len(objects) == 0 {
        //             imgui.Text("Nothing to see here!")
        //         }
        //         if imgui.Button("Add") {
        //             new_enemy := default_enemy(game_state^)
        //             append(&game_state.enemies, new_enemy)
        //         }
        //         for &mesh, i in objects {
        //             imgui.PushIDInt(c.int(i))
                    
        //             gui_print_value(&builder, "Collision state", mesh.collision_state)
                    
        //             // AI state dropdown box
        //             {
        //                 cstrs := ENEMY_STATE_CSTRINGS
        //                 selected := mesh.ai_state
        //                 if imgui.BeginCombo("AI state", cstrs[selected], {.HeightLarge}) {
        //                     for item, i in cstrs {
        //                         if imgui.Selectable(item) {
        //                             mesh.ai_state = EnemyState(i)
        //                             mesh.velocity = {}
        //                             mesh.home_position = mesh.position
        //                         }
        //                     }
        //                     imgui.EndCombo()
        //                 }
        //             }
    
        //             if imgui.DragFloat3("Position", &mesh.position, 0.1) {
        //                 mesh.velocity = {}
        //             }
        //             imgui.DragFloat3("Home position", &mesh.home_position, 0.1)
        //             imgui.SliderFloat("Scale", &mesh.collision_radius, 0.0, 50.0)
        //             {
        //                 imgui.Checkbox("Visualize home radius", &mesh.visualize_home)
        //             }
        
        //             disable_button := false
        //             move_text : cstring = "Move"
        //             obj, obj_ok := editor_response.(EditorResponse)
        //             if obj_ok {
        //                 if obj.type == response_type && obj.index == u32(i) {
        //                     disable_button = true
        //                     move_text = "Moving..."
        //                 }
        //             }
        
        //             imgui.BeginDisabled(disable_button)
        //             if imgui.Button(move_text) {
        //                 editor_response^ = EditorResponse {
        //                     type = response_type,
        //                     index = u32(i)
        //                 }
        //             }
        //             imgui.SameLine()
        //             if imgui.Button("Clone") {
        //                 enemy_to_clone_idx = i
        //             }
        //             imgui.SameLine()
        //             if imgui.Button("Delete") {
        //                 unordered_remove(objects, i)
        //                 editor_response^ = nil
        //             }
        //             imgui.EndDisabled()
        //             {
        //                 imgui.SameLine()
        //                 idx, ok := game_state.selected_enemy.?
        //                 h := ok && i == idx
        //                 if imgui.Checkbox("Highlighted", &h) {
        //                     if ok && i == idx {
        //                         game_state.selected_enemy = nil
        //                     } else {
        //                         game_state.selected_enemy = i
        //                     }
        //                 }
        //             }
        //             imgui.Separator()
        
        //             imgui.PopID()
        //         }
        //         imgui.PopID()
        //     }
        // }

        // coin_to_clone_idx: Maybe(int)
        // {
        //     objects := &game_state.coins
        //     label : cstring = "Coins"
        //     editor_response := &game_state.editor_response
        //     response_type := EditorResponseType.MoveCoin
        //     if imgui.CollapsingHeader(label) {
        //         imgui.PushID(label)
        //         if len(objects) == 0 {
        //             imgui.Text("Nothing to see here!")
        //         }
        //         if imgui.Button("Add") {
        //             append(&game_state.coins, Coin {})
        //         }
        //         for &mesh, i in objects {
        //             imgui.PushIDInt(c.int(i))
    
        //             imgui.DragFloat3("Position", &mesh.position, 0.1)
        
        //             disable_button := false
        //             move_text : cstring = "Move"
        //             obj, obj_ok := editor_response.(EditorResponse)
        //             if obj_ok {
        //                 if obj.type == response_type && obj.index == u32(i) {
        //                     disable_button = true
        //                     move_text = "Moving..."
        //                 }
        //             }
        
        //             imgui.BeginDisabled(disable_button)
        //             if imgui.Button(move_text) {
        //                 editor_response^ = EditorResponse {
        //                     type = response_type,
        //                     index = u32(i)
        //                 }
        //             }
        //             imgui.SameLine()
        //             if imgui.Button("Clone") {
        //                 coin_to_clone_idx = i
        //             }
        //             imgui.SameLine()
        //             if imgui.Button("Delete") {
        //                 unordered_remove(objects, i)
        //                 editor_response^ = nil
        //             }
        //             imgui.EndDisabled()
        //             imgui.Separator()
        
        //             imgui.PopID()
        //         }
        //         imgui.PopID()
        //     }
        // }

        // Do object clone
        // {
        //     things := &game_state.terrain_pieces
        //     clone_idx, clone_ok := terrain_piece_clone_idx.?
        //     if clone_ok {
        //         new_terrain_piece := things[clone_idx]
        //         new_terrain_piece.collision = copy_static_triangle_mesh(things[clone_idx].collision)

        //         append(things, new_terrain_piece)
        //         new_idx := len(things) - 1
        //         game_state.editor_response = EditorResponse {
        //             type = .MoveTerrainPiece,
        //             index = u32(new_idx)
        //         }
        //     }
        // }
        // {
        //     things := &game_state.static_scenery
        //     clone_idx, clone_ok := static_to_clone_idx.?
        //     if clone_ok {
        //         append(things, things[clone_idx])
        //         new_idx := len(things) - 1
        //         game_state.editor_response = EditorResponse {
        //             type = .MoveStaticScenery,
        //             index = u32(new_idx)
        //         }
        //     }
        // }
        // {
        //     things := &game_state.animated_scenery
        //     clone_idx, clone_ok := anim_to_clone_idx.?
        //     if clone_ok {
        //         append(things, things[clone_idx])
        //         new_idx := len(things) - 1
        //         game_state.editor_response = EditorResponse {
        //             type = .MoveAnimatedScenery,
        //             index = u32(new_idx)
        //         }
        //     }
        // }
        // {
        //     things := &game_state.enemies
        //     clone_idx, clone_ok := enemy_to_clone_idx.?
        //     if clone_ok {
        //         append(things, things[clone_idx])
        //         new_idx := len(things) - 1
        //         game_state.editor_response = EditorResponse {
        //             type = .MoveEnemy,
        //             index = u32(new_idx)
        //         }
        //     }
        // }
        // {
        //     things := &game_state.coins
        //     clone_idx, clone_ok := coin_to_clone_idx.?
        //     if clone_ok {
        //         append(things, things[clone_idx])
        //         new_idx := len(things) - 1
        //         game_state.editor_response = EditorResponse {
        //             type = .MoveCoin,
        //             index = u32(new_idx)
        //         }
        //     }
        // }
    }
    if show_editor {
        imgui.End()
    }
}

lookat_camera_update :: proc(game_state: ^GameState, output_verbs: OutputVerbs, id: EntityID, dt: f32) {
    HEMISPHERE_START_POS :: hlsl.float4 {1.0, 0.0, 0.0, 0.0}

    tform := &game_state.transforms[id]
    camera := &game_state.cameras[id]
    lookat_controller := &game_state.lookat_controllers[id]
    target := &game_state.transforms[lookat_controller.target]

    lookat_controller.distance -= output_verbs.floats[.CameraFollowDistance]
    lookat_controller.distance = math.clamp(lookat_controller.distance, 1.0, 100.0)

    target_position := target.position

    camera_rotation := output_verbs.float2s[.RotateCamera] * dt

    relmotion_coords, ok3 := output_verbs.int2s[.MouseMotionRel]
    if ok3 {
        MOUSE_SENSITIVITY :: 0.001

        if .MouseLook in camera.flags {
            camera_rotation += MOUSE_SENSITIVITY * {f32(relmotion_coords.x), f32(relmotion_coords.y)}
        }
    }

    camera.yaw += camera_rotation.x
    camera.pitch += camera_rotation.y
    for camera.yaw < -2.0 * math.PI {
        camera.yaw += 2.0 * math.PI
    }
    for camera.yaw > 2.0 * math.PI {
        camera.yaw -= 2.0 * math.PI
    }
    camera.pitch = clamp(camera.pitch, -math.PI / 2.0 + 0.0001, math.PI / 2.0 - 0.0001)
    
    // @TODO: Quaternions
    pitchmat := roll_rotation_matrix(-camera.pitch)
    yawmat := yaw_rotation_matrix(-camera.yaw)
    pos_offset := lookat_controller.distance * hlsl.normalize(yawmat * hlsl.normalize(pitchmat * HEMISPHERE_START_POS))

    // Camera follow point chases player
    // target_pt := char.collision.position
    // game_state.camera_follow_point = exponential_smoothing(game_state.camera_follow_point, target_pt, game_state.camera_follow_speed, dt)
    lookat_controller.current_focal_point = exponential_smoothing(
        lookat_controller.current_focal_point,
        target_position,
        game_state.camera_follow_speed,
        dt
    )

    desired_position := lookat_controller.current_focal_point + pos_offset.xyz
    interval := Segment {
        start = lookat_controller.current_focal_point,
        end = desired_position
    }
    s := Sphere {
        position = lookat_controller.current_focal_point,
        radius = 0.1
    }
    hit_t, hit := dynamic_sphere_vs_terrain_t(s, game_state.triangle_meshes, interval)
    if hit {
        desired_position = interval.start + hit_t * (interval.end - interval.start)
    }

    tform.position = desired_position
}

freecam_update :: proc(game_state: ^GameState, output_verbs: OutputVerbs, id: EntityID, dt: f32) {
    camera_direction: hlsl.float3 = {0.0, 0.0, 0.0}
    camera_speed_mod : f32 = 1.0

    tform := &game_state.transforms[id]
    camera := &game_state.cameras[id]

    // Input handling part
    {
        camera_verbs : []VerbType = {
            .Sprint,
            .Crawl,
            .TranslateFreecamUp,
            .TranslateFreecamDown,
            .TranslateFreecamLeft,
            .TranslateFreecamRight,
            .TranslateFreecamForward,
            .TranslateFreecamBack,
        }
        response_flags : []CameraFlag = {
            .Speed,
            .Slow,
            .MoveUp,
            .MoveDown,
            .MoveLeft,
            .MoveRight,
            .MoveForward,
            .MoveBackward,
        }
        assert(len(camera_verbs) == len(response_flags))

        for verb, i in camera_verbs {
            if verb in output_verbs.bools {
                if output_verbs.bools[verb] {
                    camera.flags += {response_flags[i]}
                } else {
                    camera.flags -= {response_flags[i]}
                }
            }
        }
    }

    camera_rotation: [2]f32 = {0.0, 0.0}
    relmotion_coords, ok3 := output_verbs.int2s[.MouseMotionRel]
    if ok3 {
        MOUSE_SENSITIVITY :: 0.001
        if .MouseLook in camera.flags {
            camera_rotation += MOUSE_SENSITIVITY * {f32(relmotion_coords.x), f32(relmotion_coords.y)}
        }
    }

    camera_rotation += output_verbs.float2s[.RotateCamera]
    camera_direction.x += output_verbs.floats[.TranslateFreecamX]

    // Not a sign error. In view-space, -Z is forward
    camera_direction.z -= output_verbs.floats[.TranslateFreecamY]

    camera_speed_mod += game_state.freecam_speed_multiplier * output_verbs.floats[.Sprint]
    camera_speed_mod += game_state.freecam_slow_multiplier * output_verbs.floats[.Crawl]


    CAMERA_SPEED :: 10
    per_frame_speed := CAMERA_SPEED * dt

    if .Speed in camera.flags {
        camera_speed_mod *= game_state.freecam_speed_multiplier
    }
    if .Slow in camera.flags {
        camera_speed_mod *= game_state.freecam_slow_multiplier
    }

    camera.yaw += camera_rotation.x
    camera.pitch += camera_rotation.y
    for camera.yaw < -2.0 * math.PI {
        camera.yaw += 2.0 * math.PI
    }
    for camera.yaw > 2.0 * math.PI {
        camera.yaw -= 2.0 * math.PI
    }

    camera.pitch = clamp(camera.pitch, -math.PI / 2.0, math.PI / 2.0)

    control_flags_dir: hlsl.float3
    if .MoveUp in camera.flags {
        control_flags_dir += {0.0, 1.0, 0.0}
    }
    if .MoveDown in camera.flags {
        control_flags_dir += {0.0, -1.0, 0.0}
    }
    if .MoveLeft in camera.flags {
        control_flags_dir += {-1.0, 0.0, 0.0}
    }
    if .MoveRight in camera.flags {
        control_flags_dir += {1.0, 0.0, 0.0}   
    }
    if .MoveBackward in camera.flags {
        control_flags_dir += {0.0, 0.0, 1.0}
    }
    if .MoveForward in camera.flags {
        control_flags_dir += {0.0, 0.0, -1.0}
    }

    if control_flags_dir != {0.0, 0.0, 0.0} {
        camera_direction += hlsl.normalize(control_flags_dir)
    }

    if camera_direction != {0.0, 0.0, 0.0} {
        camera_direction = hlsl.float3(camera_speed_mod) * hlsl.float3(per_frame_speed) * camera_direction
    }

    // Compute temporary camera matrix for orienting player inputted direction vector
    world_from_view := hlsl.inverse(freecam_view_from_world(tform^, camera^))
    camera_direction4 := hlsl.float4{camera_direction.x, camera_direction.y, camera_direction.z, 0.0}
    tform.position += (world_from_view * camera_direction4).xyz

    // Collision test the camera's bounding sphere against the terrain
    if game_state.freecam_collision {
        scoped_event(&profiler, "Collision with terrain")
        camera_collision_point: hlsl.float3
        closest_dist := math.INF_F32
        for _, &piece in game_state.triangle_meshes {
            candidate := closest_pt_triangles(tform.position, &piece)
            candidate_dist := hlsl.distance(candidate, tform.position)
            if candidate_dist < closest_dist {
                camera_collision_point = candidate
                closest_dist = candidate_dist
            }
        }

        if game_state.freecam_collision {
            dist := hlsl.distance(camera_collision_point, tform.position)
            if dist < CAMERA_COLLISION_RADIUS {
                diff := CAMERA_COLLISION_RADIUS - dist
                tform.position += diff * hlsl.normalize(tform.position - camera_collision_point)
            }
        }
    }

    //return camera_view_from_world(game_state.viewport_camera)
}

camera_gui :: proc(
    game_state: ^GameState,
    camera_id: EntityID,
    input_system: ^InputSystem,
    user_config: ^UserConfiguration,
    close: ^bool
) {
    tform := &game_state.transforms[camera_id]
    camera := &game_state.cameras[camera_id]

    lookat_controller, is_lookat := &game_state.lookat_controllers[camera_id]

    if imgui.Begin("Camera controls", close) {
        imgui.Text("Position: (%f, %f, %f)", tform.position.x, tform.position.y, tform.position.z)
        imgui.Text("Yaw: %f", camera.yaw)
        imgui.Text("Pitch: %f", camera.pitch)

        imgui.SliderFloat("Fast speed", &game_state.freecam_speed_multiplier, 0.0, 100.0)
        imgui.SliderFloat("Slow speed", &game_state.freecam_slow_multiplier, 0.0, 1.0/5.0)
        imgui.SliderFloat("Smoothing speed", &game_state.camera_follow_speed, 0.1, 20.0)
        imgui.SameLine()
        if imgui.Button("Reset") {
            game_state.camera_follow_speed = 6.0
        }
        if imgui.Checkbox("Enable freecam collision", &game_state.freecam_collision) {
            user_config.flags[.FreecamCollision] = game_state.freecam_collision
        }

        freecam := !is_lookat
        if imgui.Checkbox("Freecam", &freecam) {
            camera.pitch = 0.0
            camera.yaw = 0.0
            
            if !freecam {
                replace_keybindings(input_system, &game_state.character_key_mappings)
                game_state.lookat_controllers[camera_id] = LookatController {
                    target = game_state.player_id,
                    distance = 4.0
                }
            } else {
                replace_keybindings(input_system, &game_state.freecam_key_mappings)
                delete_key(&game_state.lookat_controllers, camera_id)
            }
        }

        if is_lookat {
            imgui.SliderFloat("Camera follow distance", &lookat_controller.distance, 1.0, 20.0)
            tgt: c.int = c.int(lookat_controller.target)
            if imgui.SliderInt("Target ID", &tgt, 0, c.int(game_state._next_id - 1)) {
                lookat_controller.target = EntityID(tgt)
            }
        }

        imgui.SliderFloat("Camera FOV", &camera.fov_radians, math.PI / 36, math.PI)
        imgui.SameLine()
        imgui.PushIDInt(1)
        if imgui.Button("Reset") {
            camera.fov_radians = math.PI / 2.0
        }
        imgui.PopID()
    }
    imgui.End()
}