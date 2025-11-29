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

GRAVITY_ACCELERATION : hlsl.float3 : {0.0, 0.0, 2.0 * -9.8}           // m/s^2
TERMINAL_VELOCITY :: -100000.0                                  // m/s
ENEMY_THROW_SPEED :: 15.0

// TerrainPiece :: struct {
//     collision: TriangleMesh,
//     position: hlsl.float3,
//     rotation: quaternion128,
//     scale: f32,
//     model: StaticModelHandle,
// }

// delete_terrain_piece :: proc(using t: ^TerrainPiece) {
//     delete_static_triangles(&collision)
// }

closest_pt_terrain :: proc(point: hlsl.float3, terrain: map[u32]TriangleMesh) -> hlsl.float3 {
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
closest_pt_terrain_with_normal :: proc(point: hlsl.float3, terrain: map[u32]TriangleMesh) -> (hlsl.float3, hlsl.float3) {
    scoped_event(&profiler, "closest_pt_terrain_with_normal")
    candidate: hlsl.float3
    cn: hlsl.float3
    closest_dist := math.INF_F32
    for _, &piece in terrain {
        p, n := closest_pt_triangles_with_normal(point, &piece)
        d := hlsl.distance(point, p)
        if d < closest_dist {
            candidate = p
            closest_dist = d
            cn = n
        }
    }
    return candidate, cn
}

intersect_segment_terrain :: proc(segment: ^Segment, terrain: map[u32]TriangleMesh) -> (hlsl.float3, bool) {
    cand_t := math.INF_F32
    for _, &piece in terrain {
        t, ok := intersect_segment_triangles_t(segment, &piece)
        if ok {
            if t < cand_t {
                cand_t = t
            }
        }
    }

    return segment.start + cand_t * (segment.end - segment.start), cand_t < math.INF_F32
}

intersect_segment_terrain_with_normal :: proc(segment: ^Segment, terrain: map[u32]TriangleMesh) -> (f32, hlsl.float3, bool) {
    cand_t := math.INF_F32
    normal: hlsl.float3
    for _, &piece in terrain {
        t, n, ok := intersect_segment_triangles_t_with_normal(segment, &piece)
        if ok {
            if t < cand_t {
                cand_t = t
                normal = n
            }
        }
    }

    return cand_t, normal, cand_t < math.INF_F32
}

dynamic_sphere_vs_terrain_t :: proc(s: ^Sphere, terrain: map[u32]TriangleMesh, motion_interval: ^Segment) -> (f32, bool) {
    closest_t := math.INF_F32
    for _, &piece in terrain {
        t, ok3 := dynamic_sphere_vs_triangles_t(s, &piece, motion_interval)
        if ok3 {
            if t < closest_t {
                closest_t = t
            }
        }
    }
    return closest_t, closest_t < math.INF_F32
}

// dynamic_sphere_vs_terrain_t_with_normal :: proc(s: ^Sphere, terrain: []TerrainPiece, motion_interval: ^Segment) -> (f32, hlsl.float3, bool) {
//     closest_t := math.INF_F32
//     current_n := hlsl.float3 {}
//     for &piece in terrain {
//         t, n, ok3 := dynamic_sphere_vs_triangles_t_with_normal(s, &piece.collision, motion_interval)
//         if ok3 {
//             if t < closest_t {
//                 closest_t = t
//                 current_n = n
//             }
//         }
//     }
//     return closest_t, current_n, closest_t < math.INF_F32
// }
do_mouse_raycast :: proc(
    viewport_camera: Camera,
    triangle_meshes: map[u32]TriangleMesh,
    mouse_location: [2]i32,
    viewport_dimensions: [4]f32
) -> (hlsl.float3, bool) {
    viewport_coords := hlsl.uint2 {
        u32(mouse_location.x) - u32(viewport_dimensions[0]),
        u32(mouse_location.y) - u32(viewport_dimensions[1]),
    }
    ray := get_view_ray(
        viewport_camera,
        viewport_coords,
        {u32(viewport_dimensions[2]), u32(viewport_dimensions[3])}
    )

    collision_pt: hlsl.float3
    closest_dist := math.INF_F32
    for _, &piece in triangle_meshes {
        candidate, ok := intersect_ray_triangles(&ray, &piece)
        if ok {
            candidate_dist := hlsl.distance(candidate, viewport_camera.position)
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

StaticScenery :: struct {
    model: StaticModelHandle,
    position: hlsl.float3,
    rotation: quaternion128,
    scale: f32,
}

AnimatedScenery :: struct {
    model: SkinnedModelHandle,
    position: hlsl.float3,
    rotation: quaternion128,
    scale: f32,
    anim_idx: u32,
    anim_t: f32,
    anim_speed: f32,
}

CollisionState :: enum {
    Grounded,
    Falling
}

PhysicsSphere :: struct {
    using s: Sphere,
    velocity: hlsl.float3,
    state: CollisionState,
}

CharacterFlag :: enum {
    MovingLeft,
    MovingRight,
    MovingBack,
    MovingForward,
    AlreadyJumped,
    Sprinting,
}
CharacterFlags :: bit_set[CharacterFlag]
CHARACTER_MAX_HEALTH :: 3
CHARACTER_INVULNERABILITY_DURATION :: 0.5
BULLET_MAX_RADIUS :: 0.8
Character :: struct {
    collision: PhysicsSphere,
    gravity_factor: f32,
    acceleration: hlsl.float3,
    deceleration_speed: f32,
    facing: hlsl.float3,
    move_speed: f32,
    sprint_speed: f32,
    jump_speed: f32,
    anim_t: f32,
    anim_speed: f32,
    health: u32,
    control_flags: CharacterFlags,
    damage_timer: time.Time,
    model: SkinnedModelHandle,

    air_vortex: Maybe(AirVortex),
    bullet_travel_time: f32,
    held_enemy: Maybe(Enemy),
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
Enemy :: struct {
    position: hlsl.float3,
    velocity: hlsl.float3,
    collision_radius: f32,
    facing: hlsl.float3,
    home_position: hlsl.float3,
    visualize_home: bool,

    init_ai_state: EnemyState,
    ai_state: EnemyState,
    collision_state: CollisionState,
    timer_start: time.Time,

    model: StaticModelHandle,
}

default_enemy :: proc(game_state: GameState) -> Enemy {
    return {
        position = {},
        velocity = {},
        collision_radius = 0.5,
        facing = {0.0, 1.0, 0.0},
        home_position = {},
        visualize_home = false,
        init_ai_state = .Wandering,
        ai_state = .Wandering,
        collision_state = .Grounded,
        timer_start = time.now(),
        model = game_state.enemy_mesh
    }
}

ThrownEnemy :: struct {
    position: hlsl.float3,
    velocity: hlsl.float3,
    collision_radius: f32,
    respawn_position: hlsl.float3,
    respawn_home: hlsl.float3,
    respawn_ai_state: EnemyState,
}

Coin :: struct {
    position: hlsl.float3,
}

DebugVisualizationFlags :: bit_set[enum {
    ShowPlayerSpawn,
    ShowPlayerHitSphere,
    ShowPlayerActivityRadius,
    ShowCoinRadius,
}]

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

CollisionResponse :: enum {
    None,
    HitFloor,
    HitCeiling,
    PassedThroughGround,
    Bump,
}
gravity_affected_sphere :: proc(
    game_state: GameState,
    sphere: ^PhysicsSphere,
    closest_pt: hlsl.float3,
    collision_normal: hlsl.float3,
    triangle_normal: hlsl.float3,
    motion_interval: Segment
) -> CollisionResponse {
    scoped_event(&profiler, "gravity_affected_sphere")
    resp: CollisionResponse
    switch sphere.state {
        case .Grounded: {
            // Push out of ground
            dist := hlsl.distance(closest_pt, sphere.position)
            if dist < sphere.radius {
                remaining_dist := sphere.radius - dist
                if hlsl.dot(collision_normal, hlsl.float3{0.0, 0.0, 1.0}) < 0.5 {
                    sphere.position = motion_interval.end + remaining_dist * collision_normal
                } else {
                    sphere.position = motion_interval.end
                }
                sphere.state = .Grounded
            } else {
                sphere.position = motion_interval.end
            }

            // Check if we need to bump ourselves up or down
            {
                tolerance_segment := Segment {
                    start = sphere.position + {0.0, 0.0, 0.0},
                    end = sphere.position + {0.0, 0.0, -sphere.radius - 0.1}
                }
                tolerance_t, normal, okt := intersect_segment_terrain_with_normal(&tolerance_segment, game_state.triangle_meshes)
                if okt {
                    tolerance_point := tolerance_segment.start + tolerance_t * (tolerance_segment.end - tolerance_segment.start)
                    sphere.position = tolerance_point + {0.0, 0.0, sphere.radius}
                    if hlsl.dot(normal, hlsl.float3{0.0, 0.0, 1.0}) >= 0.5 {
                        sphere.velocity.z = 0.0
                        sphere.state = .Grounded
                        resp = .Bump
                    }
                } else {
                    sphere.state = .Falling
                }
            }
        }
        case .Falling: {
            // Then do collision test against triangles

            collided := false
            inv := motion_interval
            segment_pt, segment_ok := intersect_segment_terrain(&inv, game_state.triangle_meshes)
            if segment_ok {
                log.info("Player center passed through ground")
                sphere.position = segment_pt
                sphere.position += triangle_normal * sphere.radius
                sphere.velocity.z = 0
                sphere.state = .Grounded
            } else {

                d := hlsl.distance(sphere.position, closest_pt)
                collided = d < sphere.radius
    
                if collided {
                    // Hit terrain
                    remaining_d := sphere.radius - d
                    sphere.position = motion_interval.end + remaining_d * collision_normal
                    
                    n_dot := hlsl.dot(collision_normal, hlsl.float3{0.0, 0.0, 1.0})
                    if n_dot >= 0.5 && sphere.velocity.z < 0.0 {
                        // Floor
                        sphere.velocity.z = 0
                        sphere.state = .Grounded
                        resp = .HitFloor
                    } else if n_dot < -0.1 && sphere.velocity.z > 0.0 {
                        // Ceiling
                        sphere.velocity.z = 0.0
                        resp = .HitCeiling
                    }
                } else {
                    // Didn't hit anything, still falling.
                    sphere.position = motion_interval.end
                }
            }

        }
    }
    return resp
}

// Megastruct for all game-specific data
GameState :: struct {
    character: Character,
    viewport_camera: Camera,

    // Scene/Level data
    //terrain_pieces: [dynamic]TerrainPiece,
    static_scenery: [dynamic]StaticScenery,
    animated_scenery: [dynamic]AnimatedScenery,
    enemies: [dynamic]Enemy,
    thrown_enemies: [dynamic]ThrownEnemy,
    coins: [dynamic]Coin,
    character_start: hlsl.float3,
    skybox_texture: vkw.Texture_Handle,

    // Data-oriented tables
    next_id: u32,                   // Components with the same id are associated with one another
    transforms: map[u32]Transform,
    triangle_meshes: map[u32]TriangleMesh,
    static_models: map[u32]StaticModelHandle,

    // Icosphere mesh for visualizing spherical collision and points
    sphere_mesh: StaticModelHandle,
    
    coin_mesh: StaticModelHandle,
    coin_collision_radius: f32,

    enemy_mesh: StaticModelHandle,
    selected_enemy: Maybe(int),


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

    do_this_frame: bool,
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
    game_state.do_this_frame = true
    game_state.paused = false
    game_state.timescale = 1.0
    game_state.coin_collision_radius = 0.1

    // Initialize main viewport camera
    game_state.viewport_camera = Camera {
        position = {
            f32(user_config.floats[.FreecamX]),
            f32(user_config.floats[.FreecamY]),
            f32(user_config.floats[.FreecamZ])
        },
        yaw = f32(user_config.floats[.FreecamYaw]),
        pitch = f32(user_config.floats[.FreecamPitch]),
        fov_radians = f32(user_config.floats[.CameraFOV]),
        nearplane = 0.1 / math.sqrt_f32(2.0),
        farplane = 1_000_000.0,
        collision_radius = 0.1,
        target = {
            distance = 5.0
        },
    }
    game_state.freecam_speed_multiplier = 5.0
    game_state.freecam_slow_multiplier = 1.0 / 5.0
    if user_config.flags[.FollowCam] {
        game_state.viewport_camera.control_flags += {.Follow}
    }

    game_state.camera_follow_point = game_state.character.collision.position
    game_state.camera_follow_speed = 6.0

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
    scene_allocator := context.allocator
) {
    //game_state.terrain_pieces = make([dynamic]TerrainPiece, scene_allocator)
    game_state.static_scenery = make([dynamic]StaticScenery, scene_allocator)
    game_state.animated_scenery = make([dynamic]AnimatedScenery, scene_allocator)
    game_state.enemies = make([dynamic]Enemy, scene_allocator)
    game_state.thrown_enemies = make([dynamic]ThrownEnemy, scene_allocator)
    game_state.coins = make([dynamic]Coin, scene_allocator)

    game_state.next_id = 0
    game_state.transforms = make(map[u32]Transform, scene_allocator)
    game_state.triangle_meshes = make(map[u32]TriangleMesh, scene_allocator)
    game_state.static_models = make(map[u32]StaticModelHandle, scene_allocator)
    
    // Load icosphere mesh for debug visualization
    game_state.sphere_mesh = load_gltf_static_model(gd, renderer, "data/models/icosphere.glb", scene_allocator)

    // Load enemy mesh
    game_state.enemy_mesh = load_gltf_static_model(gd, renderer, "data/models/majoras_moon.glb", scene_allocator)
    
    game_state.coin_mesh = load_gltf_static_model(gd, renderer, "data/models/precursor_orb.glb", scene_allocator)
    
    // Load animated test glTF model
    skinned_model: SkinnedModelHandle
    {
        path : cstring = "data/models/CesiumMan.glb"
        skinned_model = load_gltf_skinned_model(gd, renderer, path, scene_allocator)
    }

    game_state.character = Character {
        collision = {
            position = game_state.character_start,
            radius = 0.8
        },
        gravity_factor = 1.0,
        deceleration_speed = 0.1,
        facing = {0.0, 1.0, 0.0},
        move_speed = 7.0,
        sprint_speed = 14.0,
        jump_speed = 10.0,
        anim_speed = 0.856,
        model = skinned_model,

        bullet_travel_time = 0.144,
    }
}

gamestate_next_id :: proc(gamestate: ^GameState) -> u32 {
    r := gamestate.next_id
    gamestate.next_id += 1
    return r
}

load_level_file :: proc(
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
    gamestate_new_scene(game_state, gd, renderer)

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
    game_state.character_start = read_thing_from_buffer(lvl_bytes, type_of(game_state.character_start), &read_head)
    game_state.character.collision.position = game_state.character_start
    game_state.camera_follow_point = game_state.character.collision.position
    
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
                    game_state.static_models[id] = model

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
            
                    append(&game_state.static_scenery, StaticScenery {
                        model = model,
                        position = position,
                        rotation = rotation,
                        scale = scale
                    })
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
                    
                    append(&game_state.animated_scenery, AnimatedScenery {
                        model = model,
                        position = position,
                        rotation = rotation,
                        scale = scale,
                        anim_idx = 0,
                        anim_t = 0.0,
                        anim_speed = 1.0,
                    })
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

                    new_enemy := default_enemy(game_state^)
                    new_enemy.position = position
                    new_enemy.home_position = position
                    new_enemy.ai_state = ai_state
                    new_enemy.init_ai_state = ai_state
                    append(&game_state.enemies, new_enemy)
                }

            }
            case .Coins: {
                coin_len := read_thing_from_buffer(lvl_bytes, u32, &read_head)
                for _ in 0..<coin_len {
                    p := read_thing_from_buffer(lvl_bytes, hlsl.float3, &read_head)
                    append(&game_state.coins, Coin {
                        position = p
                    })
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

write_level_file :: proc(gamestate: ^GameState, renderer: ^Renderer, audio_system: AudioSystem, path: string) {
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
    output_size += size_of(gamestate.character_start)
    
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
    if len(gamestate.static_scenery) > 0 {
        output_size += size_of(u8)
        output_size += size_of(u32)
    }
    for scenery in gamestate.static_scenery {
        output_size += mesh_data_size(renderer, scenery)
    }

    // Animated scenery
    if len(gamestate.animated_scenery) > 0 {
        output_size += size_of(u8)
        output_size += size_of(u32)
    }
    for scenery in gamestate.animated_scenery {
        model := get_skinned_model(renderer, scenery.model)
        s := 0
        s += size_of(u32)
        s += len(model.name)
        s += size_of(scenery.position)
        s += size_of(scenery.rotation)
        s += size_of(scenery.scale)
        output_size += s
    }

    // Enemies
    if len(gamestate.enemies) > 0 {
        output_size += size_of(u8)
        output_size += size_of(u32)
    }
    for enemy in gamestate.enemies {
        output_size += size_of(enemy.position)
        output_size += size_of(enemy.collision_radius)
        output_size += size_of(enemy.ai_state)
    }

    // Coins
    if len(gamestate.coins) > 0 {
        output_size += size_of(u8)
        output_size += size_of(u32)
    }
    for coin in gamestate.coins {
        output_size += size_of(coin.position)
    }
    
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

    write_thing_to_buffer(raw_output_buffer[:], &gamestate.character_start, &write_head)

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

    if len(gamestate.static_scenery) > 0 {
        block = .StaticScenery
        write_thing_to_buffer(raw_output_buffer[:], &block, &write_head)
        static_len := u32(len(gamestate.static_scenery))
        write_thing_to_buffer(raw_output_buffer[:], &static_len, &write_head)
    }
    for &scenery in gamestate.static_scenery {
        write_mesh_to_buffer(renderer, raw_output_buffer[:], &scenery, &write_head)
    }

    if len(gamestate.animated_scenery) > 0 {
        block = .AnimatedScenery
        write_thing_to_buffer(raw_output_buffer[:], &block, &write_head)
        anim_len := u32(len(gamestate.animated_scenery))
        write_thing_to_buffer(raw_output_buffer[:], &anim_len, &write_head)
    }
    for &scenery in gamestate.animated_scenery {
        write_mesh_to_buffer(renderer, raw_output_buffer[:], &scenery, &write_head)
    }

    if len(gamestate.enemies) > 0 {
        block = .Enemies
        write_thing_to_buffer(raw_output_buffer[:], &block, &write_head)
        enemy_len := u32(len(gamestate.enemies))
        write_thing_to_buffer(raw_output_buffer[:], &enemy_len, &write_head)
    }
    for &enemy in gamestate.enemies {
        write_thing_to_buffer(raw_output_buffer[:], &enemy.position, &write_head)
        write_thing_to_buffer(raw_output_buffer[:], &enemy.collision_radius, &write_head)
        write_thing_to_buffer(raw_output_buffer[:], &enemy.ai_state, &write_head)
    }

    if len(gamestate.coins) > 0 {
        block = .Coins
        write_thing_to_buffer(raw_output_buffer[:], &block, &write_head)
        l := u32(len(gamestate.coins))
        write_thing_to_buffer(raw_output_buffer[:], &l, &write_head)
    }
    for &coin in gamestate.coins {
        write_thing_to_buffer(raw_output_buffer[:], &coin.position, &write_head)
    }

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
            imgui.DragFloat3("Player spawn", &game_state.character_start, 0.1)
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

        terrain_piece_clone_idx: Maybe(int)
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

        static_to_clone_idx: Maybe(int)
        {
            objects := &game_state.static_scenery
            label : cstring = "Static scenery"
            editor_response := &game_state.editor_response
            response_type := EditorResponseType.MoveStaticScenery
            add_response_type := EditorResponseType.AddStaticScenery
            if imgui.CollapsingHeader(label) {
                imgui.PushID(label)
                if len(objects) == 0 {
                    imgui.Text("Nothing to see here!")
                }
                if imgui.Button("Add") {
                    editor_response^ = EditorResponse {
                        type = add_response_type,
                        index = 0
                    }
                }
                for &mesh, i in objects {
                    imgui.PushIDInt(c.int(i))
        
                    model := get_static_model(renderer, mesh.model)
                    gui_print_value(&builder, "Name", model.name)
                    gui_print_value(&builder, "Rotation", mesh.rotation)
    
                    imgui.DragFloat3("Position", &mesh.position, 0.1)
                    imgui.SliderFloat("Scale", &mesh.scale, 0.0, 50.0)
        
                    disable_button := false
                    move_text : cstring = "Move"
                    obj, obj_ok := editor_response.(EditorResponse)
                    if obj_ok {
                        if obj.type == response_type && obj.index == u32(i) {
                            disable_button = true
                            move_text = "Moving..."
                        }
                    }
        
                    imgui.BeginDisabled(disable_button)
                    if imgui.Button(move_text) {
                        editor_response^ = EditorResponse {
                            type = response_type,
                            index = u32(i)
                        }
                    }
                    imgui.SameLine()
                    if imgui.Button("Clone") {
                        static_to_clone_idx = i
                    }
                    imgui.SameLine()
                    if imgui.Button("Delete") {
                        unordered_remove(objects, i)
                        editor_response^ = nil
                    }
                    imgui.EndDisabled()
                    imgui.Separator()
        
                    imgui.PopID()
                }
                imgui.PopID()
            }
        }

        anim_to_clone_idx: Maybe(int)
        {
            objects := &game_state.animated_scenery
            label : cstring = "Animated scenery"
            editor_response := &game_state.editor_response
            response_type := EditorResponseType.MoveAnimatedScenery
            add_response_type := EditorResponseType.AddAnimatedScenery
            if imgui.CollapsingHeader(label) {
                imgui.PushID(label)
                if len(objects) == 0 {
                    imgui.Text("Nothing to see here!")
                }
                if imgui.Button("Add") {
                    editor_response^ = EditorResponse {
                        type = add_response_type,
                        index = 0
                    }
                }
                for &mesh, i in objects {
                    imgui.PushIDInt(c.int(i))
        
                    model := get_skinned_model(renderer, mesh.model)
                    gui_print_value(&builder, "Name", model.name)
                    gui_print_value(&builder, "Rotation", mesh.rotation)
    
                    imgui.DragFloat3("Position", &mesh.position, 0.1)
                    imgui.SliderFloat("Scale", &mesh.scale, 0.0, 50.0)
    
                    anim := &renderer.animations[model.first_animation_idx]
                    imgui.SliderFloat("Anim t", &mesh.anim_t, 0.0, get_animation_endtime(anim))
                    imgui.SliderFloat("Anim speed", &mesh.anim_speed, 0.0, 20.0)
        
                    disable_button := false
                    move_text : cstring = "Move"
                    obj, obj_ok := editor_response.(EditorResponse)
                    if obj_ok {
                        if obj.type == response_type && obj.index == u32(i) {
                            disable_button = true
                            move_text = "Moving..."
                        }
                    }

                    imgui.BeginDisabled(disable_button)
                    if imgui.Button(move_text) {
                        editor_response^ = EditorResponse {
                            type = response_type,
                            index = u32(i)
                        }
                    }
                    imgui.SameLine()
                    if imgui.Button("Clone") {
                        anim_to_clone_idx = i
                    }
                    imgui.SameLine()
                    if imgui.Button("Delete") {
                        unordered_remove(objects, i)
                        editor_response^ = nil
                    }
                    imgui.EndDisabled()
                    imgui.Separator()
        
                    imgui.PopID()
                }
                imgui.PopID()
            }
        }

        enemy_to_clone_idx: Maybe(int)
        {
            objects := &game_state.enemies
            label : cstring = "Enemies"
            editor_response := &game_state.editor_response
            response_type := EditorResponseType.MoveEnemy
            if imgui.CollapsingHeader(label) {
                imgui.PushID(label)
                if len(objects) == 0 {
                    imgui.Text("Nothing to see here!")
                }
                if imgui.Button("Add") {
                    new_enemy := default_enemy(game_state^)
                    append(&game_state.enemies, new_enemy)
                }
                for &mesh, i in objects {
                    imgui.PushIDInt(c.int(i))
                    
                    gui_print_value(&builder, "Collision state", mesh.collision_state)
                    
                    // AI state dropdown box
                    {
                        cstrs := ENEMY_STATE_CSTRINGS
                        selected := mesh.ai_state
                        if imgui.BeginCombo("AI state", cstrs[selected], {.HeightLarge}) {
                            for item, i in cstrs {
                                if imgui.Selectable(item) {
                                    mesh.ai_state = EnemyState(i)
                                    mesh.init_ai_state = mesh.ai_state
                                    mesh.velocity = {}
                                    mesh.home_position = mesh.position
                                }
                            }
                            imgui.EndCombo()
                        }
                    }
    
                    if imgui.DragFloat3("Position", &mesh.position, 0.1) {
                        mesh.velocity = {}
                    }
                    imgui.DragFloat3("Home position", &mesh.home_position, 0.1)
                    imgui.SliderFloat("Scale", &mesh.collision_radius, 0.0, 50.0)
                    {
                        imgui.Checkbox("Visualize home radius", &mesh.visualize_home)
                    }
        
                    disable_button := false
                    move_text : cstring = "Move"
                    obj, obj_ok := editor_response.(EditorResponse)
                    if obj_ok {
                        if obj.type == response_type && obj.index == u32(i) {
                            disable_button = true
                            move_text = "Moving..."
                        }
                    }
        
                    imgui.BeginDisabled(disable_button)
                    if imgui.Button(move_text) {
                        editor_response^ = EditorResponse {
                            type = response_type,
                            index = u32(i)
                        }
                    }
                    imgui.SameLine()
                    if imgui.Button("Clone") {
                        enemy_to_clone_idx = i
                    }
                    imgui.SameLine()
                    if imgui.Button("Delete") {
                        unordered_remove(objects, i)
                        editor_response^ = nil
                    }
                    imgui.EndDisabled()
                    {
                        imgui.SameLine()
                        idx, ok := game_state.selected_enemy.?
                        h := ok && i == idx
                        if imgui.Checkbox("Highlighted", &h) {
                            if ok && i == idx {
                                game_state.selected_enemy = nil
                            } else {
                                game_state.selected_enemy = i
                            }
                        }
                    }
                    imgui.Separator()
        
                    imgui.PopID()
                }
                imgui.PopID()
            }
        }

        coin_to_clone_idx: Maybe(int)
        {
            objects := &game_state.coins
            label : cstring = "Coins"
            editor_response := &game_state.editor_response
            response_type := EditorResponseType.MoveCoin
            if imgui.CollapsingHeader(label) {
                imgui.PushID(label)
                if len(objects) == 0 {
                    imgui.Text("Nothing to see here!")
                }
                if imgui.Button("Add") {
                    append(&game_state.coins, Coin {})
                }
                for &mesh, i in objects {
                    imgui.PushIDInt(c.int(i))
    
                    imgui.DragFloat3("Position", &mesh.position, 0.1)
        
                    disable_button := false
                    move_text : cstring = "Move"
                    obj, obj_ok := editor_response.(EditorResponse)
                    if obj_ok {
                        if obj.type == response_type && obj.index == u32(i) {
                            disable_button = true
                            move_text = "Moving..."
                        }
                    }
        
                    imgui.BeginDisabled(disable_button)
                    if imgui.Button(move_text) {
                        editor_response^ = EditorResponse {
                            type = response_type,
                            index = u32(i)
                        }
                    }
                    imgui.SameLine()
                    if imgui.Button("Clone") {
                        coin_to_clone_idx = i
                    }
                    imgui.SameLine()
                    if imgui.Button("Delete") {
                        unordered_remove(objects, i)
                        editor_response^ = nil
                    }
                    imgui.EndDisabled()
                    imgui.Separator()
        
                    imgui.PopID()
                }
                imgui.PopID()
            }
        }

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
        {
            things := &game_state.static_scenery
            clone_idx, clone_ok := static_to_clone_idx.?
            if clone_ok {
                append(things, things[clone_idx])
                new_idx := len(things) - 1
                game_state.editor_response = EditorResponse {
                    type = .MoveStaticScenery,
                    index = u32(new_idx)
                }
            }
        }
        {
            things := &game_state.animated_scenery
            clone_idx, clone_ok := anim_to_clone_idx.?
            if clone_ok {
                append(things, things[clone_idx])
                new_idx := len(things) - 1
                game_state.editor_response = EditorResponse {
                    type = .MoveAnimatedScenery,
                    index = u32(new_idx)
                }
            }
        }
        {
            things := &game_state.enemies
            clone_idx, clone_ok := enemy_to_clone_idx.?
            if clone_ok {
                append(things, things[clone_idx])
                new_idx := len(things) - 1
                game_state.editor_response = EditorResponse {
                    type = .MoveEnemy,
                    index = u32(new_idx)
                }
            }
        }
        {
            things := &game_state.coins
            clone_idx, clone_ok := coin_to_clone_idx.?
            if clone_ok {
                append(things, things[clone_idx])
                new_idx := len(things) - 1
                game_state.editor_response = EditorResponse {
                    type = .MoveCoin,
                    index = u32(new_idx)
                }
            }
        }
    }
    if show_editor {
        imgui.End()
    }
}

player_update :: proc(game_state: ^GameState, audio_system: ^AudioSystem, output_verbs: ^OutputVerbs, dt: f32) {
    scoped_event(&profiler, "Player update")

    char := &game_state.character

    // Is character taking damage
    taking_damage := !timer_expired(char.damage_timer, CHARACTER_INVULNERABILITY_DURATION * SECONDS_TO_NANOSECONDS)

    // Set current xy velocity (and character facing) to whatever user input is
    {
        // X and Z bc view space is x-right, y-up, z-back
        translate_vector := output_verbs.float2s[.PlayerTranslate]
        translate_vector_x := translate_vector.x
        translate_vector_z := translate_vector.y

        // Boolean (keyboard) input handling
        {
            flags := &char.control_flags

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
        world_invector = yaw_rotation_matrix(-game_state.viewport_camera.yaw) * world_invector
        if hlsl.length(world_invector) > 1.0 {
            world_invector = hlsl.normalize(world_invector)
        }

        // Handle sprint
        this_frame_move_speed := char.move_speed
        {
            amount, ok := output_verbs.floats[.Sprint]
            if ok {
                this_frame_move_speed = linalg.lerp(char.move_speed, char.sprint_speed, amount)
            }
            if .Sprint in output_verbs.bools {
                if output_verbs.bools[.Sprint] {
                    char.control_flags += {.Sprinting}
                } else {
                    char.control_flags -= {.Sprinting}
                }
            }
            if .Sprinting in char.control_flags {
                this_frame_move_speed = char.sprint_speed
            }
        }

        // Now we have a representation of the player's input vector in world space

        if !taking_damage {
            char.acceleration = {world_invector.x, world_invector.y, 0.0}
            accel_len := hlsl.length(char.acceleration)
            this_frame_move_speed *= accel_len
            if accel_len == 0 && char.collision.state == .Grounded {
                to_zero := hlsl.float2 {0.0, 0.0} - char.collision.velocity.xy
                char.collision.velocity.xy += char.deceleration_speed * to_zero
            }
            char.collision.velocity.xy += char.acceleration.xy
            if math.abs(hlsl.length(char.collision.velocity.xy)) > this_frame_move_speed {
                char.collision.velocity.xy = this_frame_move_speed * hlsl.normalize(char.collision.velocity.xy)
            }
            movement_dist := hlsl.length(char.collision.velocity.xy)
            char.anim_t += char.anim_speed * dt * movement_dist
        }

        if translate_vector_x != 0.0 || translate_vector_z != 0.0 {
            char.facing = hlsl.normalize(world_invector).xyz
        }
    }

    // Handle jump command
    {
        jumped, jump_ok := output_verbs.bools[.PlayerJump]
        if jump_ok {
            // If jump state changed...
            if jumped {
                // To jumping...
                if .AlreadyJumped in char.control_flags {
                    // Do thrown-enemy double-jump
                    held_enemy, is_holding_enemy := char.held_enemy.?
                    if is_holding_enemy {
                        char.held_enemy = nil

                        // Throw enemy downwards
                        append(&game_state.thrown_enemies, ThrownEnemy {
                            position = char.collision.position - {0.0, 0.0, 0.5},
                            velocity = {0.0, 0.0, -ENEMY_THROW_SPEED},
                            respawn_position = held_enemy.position,
                            respawn_home = held_enemy.home_position,
                            respawn_ai_state = held_enemy.init_ai_state,
                            collision_radius = 0.5,
                        })
                        char.collision.velocity.z = 1.3 * char.jump_speed

                        play_sound_effect(audio_system, game_state.jump_sound)
                    }
                } else {
                    // Do first jump
                    char.collision.velocity.z = char.jump_speed
                    char.control_flags += {.AlreadyJumped}

                    play_sound_effect(audio_system, game_state.jump_sound)
                }

                char.gravity_factor = 1.0
                char.collision.state = .Falling
            } else {
                // To not jumping...
                char.gravity_factor = 2.2
            }
        }
    }

    // Apply gravity to velocity, clamping downward speed if necessary
    char.collision.velocity += dt * char.gravity_factor * GRAVITY_ACCELERATION
    if char.collision.velocity.z < TERMINAL_VELOCITY {
        char.collision.velocity.z = TERMINAL_VELOCITY
    }

    // Compute motion interval
    motion_endpoint := char.collision.position + dt * char.collision.velocity
    motion_interval := Segment {
        start = char.collision.position,
        end = motion_endpoint
    }

    // Compute closest point to terrain along with
    // vector opposing player motion
    //collision_t, collision_normal, collided := dynamic_sphere_vs_terrain_t_with_normal(&char.collision, game_state.terrain_pieces[:], &motion_interval)

    closest_pt, triangle_normal := closest_pt_terrain_with_normal(motion_endpoint, game_state.triangle_meshes)
    collision_normal := hlsl.normalize(motion_endpoint - closest_pt)

    // Main player character state machine
    switch gravity_affected_sphere(
        game_state^,
        &char.collision,
        closest_pt,
        collision_normal,
        triangle_normal,
        motion_interval
    ) {
        case .None: {}
        case .Bump: {
            char.control_flags -= {.AlreadyJumped}
        }
        case .HitCeiling: {
        }
        case .HitFloor: {
        }
        case .PassedThroughGround: {
        }
    }

    // Teleport player back to spawn if hit death plane
    respawn := output_verbs.bools[.PlayerReset]
    respawn |= char.collision.position.z < -50.0
    respawn |= char.health == 0
    if respawn {
        char.collision.position = game_state.character_start
        char.collision.velocity = {}
        char.acceleration = {}
        char.health = CHARACTER_MAX_HEALTH
    }

    // Shoot command
    {
        res, have_shoot := output_verbs.bools[.PlayerShoot]
        if have_shoot {
            if res && char.air_vortex == nil {
                held_enemy, is_holding_enemy := char.held_enemy.?
                if is_holding_enemy {
                    // Insert into thrown enemies array
                    append(&game_state.thrown_enemies, ThrownEnemy {
                        position = char.collision.position + char.facing,
                        velocity = ENEMY_THROW_SPEED * char.facing,
                        respawn_position = held_enemy.position,
                        respawn_home = held_enemy.home_position,
                        respawn_ai_state = held_enemy.init_ai_state,
                        collision_radius = 0.5,
                    })
        
                    char.held_enemy = nil
                } else {
                    start_pos := char.collision.position
                    char.air_vortex = AirVortex {
                        collision = Sphere {
                            position = start_pos,
                            radius = 0.1
                        },
    
                        t = 0.0,
                    }
                }
                play_sound_effect(audio_system, game_state.shoot_sound)
            }
        }
    }

    // Check if we collected any coins
    {
        scoped_event(&profiler, "Test player against coins")
        coin_to_remove: Maybe(int)
        for coin, i in game_state.coins {
            s := Sphere {
                position = coin.position,
                radius = game_state.coin_collision_radius
            }
            if are_spheres_overlapping(s, char.collision) {
                play_sound_effect(audio_system, game_state.coin_sound)
                coin_to_remove = i
            }
        }
        cr, crok := coin_to_remove.?
        if crok {
            unordered_remove(&game_state.coins, cr)
        }
    }

    // Check if we're being hit by an enemy
    if !taking_damage {
        for enemy in game_state.enemies {
            s := Sphere {
                position = enemy.position,
                radius = enemy.collision_radius
            }
            if are_spheres_overlapping(s, char.collision) {
                char.collision.velocity.z = 3.0
                char.collision.state = .Falling
                char.damage_timer = time.now()
                char.health -= 1
                play_sound_effect(audio_system, game_state.ow_sound)
            }
        }
    }

    // @TODO: Maybe move this out of the player update proc? Maybe we don't need to...
    bullet, bok := &char.air_vortex.?
    if bok {
        // Bullet update
        col := char.collision
        bullet.t += dt
        bullet.collision.position = char.collision.position
        bullet.collision.radius = linalg.lerp(f32(0.0), BULLET_MAX_RADIUS, min(bullet.t / char.bullet_travel_time, 1.0))
        if bullet.collision.radius == BULLET_MAX_RADIUS {
            char.air_vortex = nil
        }
    }

    // Camera follow point chases player
    target_pt := char.collision.position
    game_state.camera_follow_point = exponential_smoothing(game_state.camera_follow_point, target_pt, game_state.camera_follow_speed, dt)
}

player_draw :: proc(game_state: ^GameState, gd: ^vkw.GraphicsDevice, renderer: ^Renderer) {
    scoped_event(&profiler, "Player draw")
    character := &game_state.character

    y := -character.facing
    z := hlsl.float3 {0.0, 0.0, 1.0}
    x := hlsl.cross(y, z)
    rotate_mat := basis_matrix(x, y, z)

    // @TODO: Remove this matmul as this is just to correct an error with the model
    rotate_mat *= yaw_rotation_matrix(-math.PI / 2.0)

    model := get_skinned_model(renderer, game_state.character.model)
    
    end := get_animation_endtime(&renderer.animations[model.first_animation_idx])
    for character.anim_t > end {
        character.anim_t -= end
    }
    ddata := SkinnedDraw {
        world_from_model = rotate_mat,
        anim_idx = 0,
        anim_t = character.anim_t,
    }
    col := &game_state.character.collision

    // Blink if taking damage
    do_draw := timer_expired(character.damage_timer, CHARACTER_INVULNERABILITY_DURATION * SECONDS_TO_NANOSECONDS) ||
             (gd.frame_count >> 4) % 2 == 0
    if do_draw {
        ddata.world_from_model[3][0] = col.position.x
        ddata.world_from_model[3][1] = col.position.y
        ddata.world_from_model[3][2] = col.position.z - col.radius
        draw_ps1_skinned_mesh(gd, renderer, game_state.character.model, &ddata)
    }

    // Draw enemy above player head
    held_enemy, is_holding_enemy := character.held_enemy.?
    if is_holding_enemy {
        bob := 0.2 * math.sin(game_state.time * 1.7)
        pos := character.collision.position + {0.0, 0.0, 1.5 + bob}
        mat := translation_matrix(pos)
        mat *= yaw_rotation_matrix(game_state.time)
        mat *= uniform_scaling_matrix(0.5)
        dd := StaticDraw {
            world_from_model = mat,
            flags = {.Glowing}
        }
        draw_ps1_static_mesh(gd, renderer, game_state.enemy_mesh, dd)

        // Light source
        l := default_point_light()
        l.color = {0.0, 1.0, 0.0}
        l.world_position = pos
        l.intensity = light_flicker(game_state.rng_seed, game_state.time)
        do_point_light(renderer, l)
    }
        
    // Air bullet draw
    {
        bullet, ok := game_state.character.air_vortex.?
        if ok {
            dd := DebugDraw {
                world_from_model = translation_matrix(bullet.collision.position) * uniform_scaling_matrix(bullet.collision.radius),
                color = {0.0, 1.0, 0.0, 0.2}
            }
            draw_debug_mesh(gd, renderer, game_state.sphere_mesh, &dd)

            // Make air bullet a point light source
            l := default_point_light()
            l.color = {0.0, 1.0, 0.0}
            l.world_position = bullet.collision.position
            do_point_light(renderer, l)
        }
    }

    // Debug draw logic
    if .ShowPlayerHitSphere in game_state.debug_vis_flags {
        dd: DebugDraw
        dd.world_from_model = translation_matrix(col.position) * scaling_matrix(col.radius)
        dd.color = {0.3, 0.4, 1.0, 0.5}
        draw_debug_mesh(gd, renderer, game_state.sphere_mesh, &dd)
    }
    if .ShowPlayerSpawn in game_state.debug_vis_flags {
        dd: DebugDraw
        dd.world_from_model = translation_matrix(game_state.character_start) * scaling_matrix(0.2)
        dd.color = {0.0, 1.0, 0.0, 0.5}
        draw_debug_mesh(gd, renderer, game_state.sphere_mesh, &dd)
    }
    if .ShowPlayerActivityRadius in game_state.debug_vis_flags {
        dd: DebugDraw
        dd.world_from_model = translation_matrix(col.position) * scaling_matrix(ENEMY_PLAYER_MIN_DISTANCE)
        dd.color = {0.0, 1.0, 0.5, 0.2}
        draw_debug_mesh(gd, renderer, game_state.sphere_mesh, &dd)
    }
}

ENEMY_HOME_RADIUS :: 4.0
ENEMY_LUNGE_SPEED :: 20.0
ENEMY_JUMP_SPEED :: 6.0                 // m/s
ENEMY_PLAYER_MIN_DISTANCE :: 50.0       // Meters
enemies_update :: proc(game_state: ^GameState, audio_system: ^AudioSystem, dt: f32) {
    scoped_event(&profiler, "Enemies update")
    char := &game_state.character
    enemy_to_remove: Maybe(int)
    for &enemy, i in game_state.enemies {
        scoped_event(&profiler, "Enemy loop iteration")
        dist_to_player := hlsl.distance(char.collision.position, enemy.position)
        // Early out if not close enough to player
        // if dist_to_player > ENEMY_PLAYER_MIN_DISTANCE {
        //     continue
        // }

        // Update

        // AI state specific logic
        can_react_to_player := false
        is_affected_by_gravity := false
        {
            scoped_event(&profiler, "AI specific logic")
            switch enemy.ai_state {
                case .BrainDead: {
                    enemy.velocity.xy = {}
                }
                case .Wandering: {
                    can_react_to_player = true
                    is_affected_by_gravity = true
                    sample_point := [2]f64 {f64(game_state.time), f64(i)}
                    t := 5.0 * dt * noise.noise_2d(game_state.rng_seed, sample_point)
                    rotq := z_rotate_quaternion(t)
                    enemy.facing = linalg.quaternion128_mul_vector3(rotq, enemy.facing)
    
                    enemy.velocity.xy = hlsl.normalize(enemy.facing.xy)
    
                    if time.diff(enemy.timer_start, time.now()) > time.Duration(5.0 * SECONDS_TO_NANOSECONDS) {
                        // Start resting
                        enemy.timer_start = time.now()
                        enemy.ai_state = .Resting
                    }
                }
                case .Hovering: {
                    offset := hlsl.float3 {0, 0, 1.5 * math.sin(game_state.time)}
                    enemy.position = enemy.home_position + offset
                }
                case .AlertedBounce: {
                    is_affected_by_gravity = true
                    if enemy.collision_state == .Grounded {
                        enemy.ai_state = .AlertedCharge
                        enemy.velocity.xy += enemy.facing.xy * ENEMY_LUNGE_SPEED
                        enemy.velocity.z = ENEMY_JUMP_SPEED / 2.0
                        enemy.collision_state = .Falling
                        play_sound_effect(audio_system, game_state.jump_sound)
                    }
                }
                case .AlertedCharge: {
                    is_affected_by_gravity = true
                    enemy.home_position = enemy.position
                    if enemy.collision_state == .Grounded {
                        enemy.ai_state = .Resting
                        enemy.timer_start = time.now()
                    }
                }
                case .Resting: {
                    if time.diff(enemy.timer_start, time.now()) > time.Duration(0.75 * SECONDS_TO_NANOSECONDS) {
                        // Start wandering
                        enemy.timer_start = time.now()
                        enemy.ai_state = .Wandering
                    }
                }
            }
        }

        if can_react_to_player {
            if dist_to_player < ENEMY_HOME_RADIUS {
                enemy.facing = char.collision.position - enemy.position
                enemy.facing.z = 0.0
                enemy.facing = hlsl.normalize(enemy.facing)
                enemy.velocity = {0.0, 0.0, ENEMY_JUMP_SPEED}
                enemy.ai_state = .AlertedBounce
                enemy.collision_state = .Falling
                enemy.timer_start = time.now()
                enemy.home_position = enemy.position
                play_sound_effect(audio_system, game_state.jump_sound)
            }
        }                               

        // Apply gravity to velocity, clamping downward speed if necessary
        if is_affected_by_gravity {
            enemy.velocity += dt * GRAVITY_ACCELERATION
            if enemy.velocity.z < TERMINAL_VELOCITY {
                enemy.velocity.z = TERMINAL_VELOCITY
            }
        }

        // Compute closest point to terrain along with
        // vector opposing enemy motion
        if is_affected_by_gravity {
            scoped_event(&profiler, "Is affected by gravity")
            phys_sphere := PhysicsSphere {
                Sphere {
                    position = enemy.position,
                    radius = enemy.collision_radius
                },
                enemy.velocity,
                .Falling
            }

            // Compute motion interval
            motion_endpoint := phys_sphere.position + dt * enemy.velocity
            motion_interval := Segment {
                start = phys_sphere.position,
                end = motion_endpoint
            }

            closest_pt, triangle_normal := closest_pt_terrain_with_normal(motion_endpoint, game_state.triangle_meshes)
            collision_normal := hlsl.normalize(motion_endpoint - closest_pt)
            dist := hlsl.distance(closest_pt, phys_sphere.position)

            switch gravity_affected_sphere(
                game_state^,
                &phys_sphere,
                closest_pt,
                collision_normal,
                triangle_normal,
                motion_interval
            ) {
                case .None: {}
                case .Bump: {}
                case .HitCeiling: {}
                case .HitFloor: {}
                case .PassedThroughGround: {}
            }

            // Write updated position to enemy
            enemy.position = phys_sphere.position
            enemy.velocity = phys_sphere.velocity
            enemy.collision_state = phys_sphere.state

            // Restrict enemy movement based on home position
            {
                disp := enemy.position - enemy.home_position
                l := hlsl.length(disp.xy)
                if l > ENEMY_HOME_RADIUS {
                    enemy.position += ENEMY_HOME_RADIUS * hlsl.normalize(enemy.home_position - enemy.position)
                }
            }
        }

        // Check if overlapping air bullet
        bullet, ok := char.air_vortex.?
        if ok {
            col := Sphere {
                position = enemy.position,
                radius = enemy.collision_radius * 2.0
            }
            if are_spheres_overlapping(bullet.collision, col) {
                char.held_enemy = game_state.enemies[i]
                enemy_to_remove = i
                char.air_vortex = nil
            }
        }
    }

    // Remove enemy
    {
        idx, ok := enemy_to_remove.?
        if ok {
            unordered_remove(&game_state.enemies, idx)
        }
    }

    // Simulate thrown enemies
    thrown_enemy_to_remove: Maybe(int)
    for &enemy, i in game_state.thrown_enemies {
        // Check if hitting terrain
        THROWN_ENEMY_COLLISION_WEIGHT :: 0.8
        closest_pt := closest_pt_terrain(enemy.position, game_state.triangle_meshes)
        if hlsl.distance(closest_pt, enemy.position) < enemy.collision_radius * THROWN_ENEMY_COLLISION_WEIGHT {
            thrown_enemy_to_remove = i
            
            // Respawn enemy
            e := default_enemy(game_state^)
            e.position = enemy.respawn_position
            e.home_position = enemy.respawn_home
            e.ai_state = enemy.respawn_ai_state
            e.init_ai_state = enemy.respawn_ai_state
            e.collision_radius = enemy.collision_radius
            append(&game_state.enemies, e)
        }

        enemy.position += dt * enemy.velocity
    }

    // Remove thrown enemy
    {
        idx, ok := thrown_enemy_to_remove.?
        if ok {
            unordered_remove(&game_state.thrown_enemies, idx)
        }
    }
}

enemies_draw :: proc(gd: ^vkw.GraphicsDevice, renderer: ^Renderer, game_state: GameState) {
    scoped_event(&profiler, "Enemies draw")
    // Live enemies
    for enemy, i in game_state.enemies {
        rot: hlsl.float4x4
        {
            y := -enemy.facing
            z := hlsl.float3 {0.0, 0.0, 1.0}
            x := hlsl.normalize(hlsl.cross(y, z))
            z = hlsl.normalize(hlsl.cross(x, y))
            rot = basis_matrix(x, y, z)
        }
        world_mat := translation_matrix(enemy.position) * rot * uniform_scaling_matrix(enemy.collision_radius)

        {
            flags: InstanceFlags
            idx, ok := game_state.selected_enemy.?
            highlighted := ok && i == idx
            if highlighted {
                flags += {.Highlighted}
            }
            dd := StaticDraw {
                world_from_model = world_mat,
                flags = flags
            }
            draw_ps1_static_mesh(gd, renderer, game_state.enemy_mesh, dd)
        }

        if enemy.visualize_home {
            dd := DebugDraw {
                world_from_model = translation_matrix(enemy.home_position) * uniform_scaling_matrix(ENEMY_HOME_RADIUS),
                color = {0.5, 0.5, 0.0, 0.8}
            }
            draw_debug_mesh(gd, renderer, game_state.sphere_mesh, &dd)
        }
    }

    // Thrown enemies
    for enemy in game_state.thrown_enemies {
        mat := translation_matrix(enemy.position) * uniform_scaling_matrix(enemy.collision_radius)
        dd := StaticDraw {
            world_from_model = mat,
            flags = {.Glowing}
        }
        draw_ps1_static_mesh(gd, renderer, game_state.enemy_mesh, dd)

        // Light source
        l := default_point_light()
        l.world_position = enemy.position
        l.color = {0.0, 1.0, 0.0}
        l.intensity = light_flicker(game_state.rng_seed, game_state.time)
        do_point_light(renderer, l)
    }
}

coins_draw :: proc(gd: ^vkw.GraphicsDevice, renderer: ^Renderer, game_state: GameState) {
    sb: strings.Builder
    strings.builder_init(&sb, context.temp_allocator)
    p_string := fmt.sbprintf(&sb, "Draw %v coins", len(game_state.coins))
    scoped_event(&profiler, p_string)

    coin_count := len(game_state.coins)

    post_mul := yaw_rotation_matrix(game_state.time) * uniform_scaling_matrix(0.6)
    z_offset := 0.25 * math.sin(game_state.time)
    draw_datas := make([dynamic]StaticDraw, coin_count, context.temp_allocator)
    for i in 0..<coin_count {
        scoped_event(&profiler, "Individual coin draw")
        coin := &game_state.coins[i]
        pos := coin.position
        pos.z += z_offset
        dd := &draw_datas[i]
        dd.world_from_model = post_mul
        dd.world_from_model[3][0] = pos.x
        dd.world_from_model[3][1] = pos.y
        dd.world_from_model[3][2] = pos.z

        if .ShowCoinRadius in game_state.debug_vis_flags {
            dd: DebugDraw
            dd.world_from_model = translation_matrix(coin.position) * scaling_matrix(game_state.coin_collision_radius)
            dd.color = {0.0, 0.0, 1.0, 0.4}
            draw_debug_mesh(gd, renderer, game_state.sphere_mesh, &dd)
        }
    }
    draw_ps1_static_meshes(gd, renderer, game_state.coin_mesh, draw_datas[:])
}


// @TODO: This should be two separate functions
camera_update :: proc(
    game_state: ^GameState,
    output_verbs: ^OutputVerbs,
    dt: f32,
) -> hlsl.float4x4 {
    using game_state.viewport_camera

    camera_rotation: [2]f32 = {0.0, 0.0}

    if .Follow in control_flags {
        HEMISPHERE_START_POS :: hlsl.float4 {1.0, 0.0, 0.0, 0.0}

        target.distance -= output_verbs.floats[.CameraFollowDistance]
        target.distance = math.clamp(target.distance, 1.0, 100.0)

        game_state.viewport_camera.target.position = game_state.camera_follow_point
        game_state.viewport_camera.target.position.z += 1.0

        camera_rotation += output_verbs.float2s[.RotateCamera] * dt

        relmotion_coords, ok3 := output_verbs.int2s[.MouseMotionRel]
        if ok3 {
            MOUSE_SENSITIVITY :: 0.001
            if .MouseLook in game_state.viewport_camera.control_flags {
                camera_rotation += MOUSE_SENSITIVITY * {f32(relmotion_coords.x), f32(relmotion_coords.y)}
            }
        }

        game_state.viewport_camera.yaw += camera_rotation.x
        game_state.viewport_camera.pitch += camera_rotation.y
        for game_state.viewport_camera.yaw < -2.0 * math.PI {
            game_state.viewport_camera.yaw += 2.0 * math.PI
        }
        for game_state.viewport_camera.yaw > 2.0 * math.PI {
            game_state.viewport_camera.yaw -= 2.0 * math.PI
        }
        if game_state.viewport_camera.pitch <= -math.PI / 2.0 {
            game_state.viewport_camera.pitch = -math.PI / 2.0 + 0.0001
        }
        if game_state.viewport_camera.pitch >= math.PI / 2.0 {
            game_state.viewport_camera.pitch = math.PI / 2.0 - 0.0001
        }
        
        pitchmat := roll_rotation_matrix(-game_state.viewport_camera.pitch)
        yawmat := yaw_rotation_matrix(-game_state.viewport_camera.yaw)
        pos_offset := game_state.viewport_camera.target.distance * hlsl.normalize(yawmat * hlsl.normalize(pitchmat * HEMISPHERE_START_POS))

        desired_position := game_state.camera_follow_point + pos_offset.xyz
        dir := hlsl.normalize(game_state.camera_follow_point - desired_position)
        interval := Segment {
            start = game_state.camera_follow_point,
            end = desired_position
        }
        s := Sphere {
            position = game_state.camera_follow_point,
            radius = collision_radius
        }
        hit_t, hit := dynamic_sphere_vs_terrain_t(&s, game_state.triangle_meshes, &interval)
        if hit {
            desired_position = interval.start + hit_t * (interval.end - interval.start)
        }

        game_state.viewport_camera.position = desired_position

        return lookat_view_from_world(game_state.viewport_camera)
    } else {
        camera_direction: hlsl.float3 = {0.0, 0.0, 0.0}
        camera_speed_mod : f32 = 1.0
    
        // Input handling part
        if .Sprint in output_verbs.bools {
            if output_verbs.bools[.Sprint] {
                control_flags += {.Speed}
            } else {
                control_flags -= {.Speed}
            }
        }
        if .Crawl in output_verbs.bools {
            if output_verbs.bools[.Crawl] {
                control_flags += {.Slow}
            } else {
                control_flags -= {.Slow}
            }
        }
    
        if .TranslateFreecamUp in output_verbs.bools {
            if output_verbs.bools[.TranslateFreecamUp] {
                control_flags += {.MoveUp}
            } else {
                control_flags -= {.MoveUp}
            }
        }
        if .TranslateFreecamDown in output_verbs.bools {
            if output_verbs.bools[.TranslateFreecamDown] {
                control_flags += {.MoveDown}
            } else {
                control_flags -= {.MoveDown}
            }
        }
        if .TranslateFreecamLeft in output_verbs.bools {
            if output_verbs.bools[.TranslateFreecamLeft] {
                control_flags += {.MoveLeft}
            } else {
                control_flags -= {.MoveLeft}
            }
        }
        if .TranslateFreecamRight in output_verbs.bools {
            if output_verbs.bools[.TranslateFreecamRight] {
                control_flags += {.MoveRight}
            } else {
                control_flags -= {.MoveRight}
            }
        }
        if .TranslateFreecamBack in output_verbs.bools {
            if output_verbs.bools[.TranslateFreecamBack] {
                control_flags += {.MoveBackward}
            } else {
                control_flags -= {.MoveBackward}
            }
        }
        if .TranslateFreecamForward in output_verbs.bools {
            if output_verbs.bools[.TranslateFreecamForward] {
                control_flags += {.MoveForward}
            } else {
                control_flags -= {.MoveForward}
            }
        }
    
        relmotion_coords, ok3 := output_verbs.int2s[.MouseMotionRel]
        if ok3 {
            MOUSE_SENSITIVITY :: 0.001
            if .MouseLook in game_state.viewport_camera.control_flags {
                camera_rotation += MOUSE_SENSITIVITY * {f32(relmotion_coords.x), f32(relmotion_coords.y)}
            }
        }
    
        camera_rotation += output_verbs.float2s[.RotateCamera]
        camera_direction.x += output_verbs.floats[.TranslateFreecamX]
    
        // Not a sign error. In view-space, -Z is forward
        camera_direction.z -= output_verbs.floats[.TranslateFreecamY]
    
        camera_speed_mod += game_state.freecam_speed_multiplier * output_verbs.floats[.Sprint]
        //camera_speed_mod += game_state.freecam_slow_multiplier * output_verbs.floats[.Crawl]
    
    
        CAMERA_SPEED :: 10
        per_frame_speed := CAMERA_SPEED * dt
    
        if .Speed in control_flags {
            camera_speed_mod *= game_state.freecam_speed_multiplier
        }
        if .Slow in control_flags {
            camera_speed_mod *= game_state.freecam_slow_multiplier
        }
    
        game_state.viewport_camera.yaw += camera_rotation.x
        game_state.viewport_camera.pitch += camera_rotation.y
        for game_state.viewport_camera.yaw < -2.0 * math.PI {
            game_state.viewport_camera.yaw += 2.0 * math.PI
        }
        for game_state.viewport_camera.yaw > 2.0 * math.PI {
            game_state.viewport_camera.yaw -= 2.0 * math.PI
        }
        if game_state.viewport_camera.pitch < -math.PI / 2.0 {
            game_state.viewport_camera.pitch = -math.PI / 2.0
        }
        if game_state.viewport_camera.pitch > math.PI / 2.0 {
            game_state.viewport_camera.pitch = math.PI / 2.0
        }
    
        control_flags_dir: hlsl.float3
        if .MoveUp in control_flags {
            control_flags_dir += {0.0, 1.0, 0.0}
        }
        if .MoveDown in control_flags {
            control_flags_dir += {0.0, -1.0, 0.0}
        }
        if .MoveLeft in control_flags {
            control_flags_dir += {-1.0, 0.0, 0.0}
        }
        if .MoveRight in control_flags {
            control_flags_dir += {1.0, 0.0, 0.0}   
        }
        if .MoveBackward in control_flags {
            control_flags_dir += {0.0, 0.0, 1.0}
        }
        if .MoveForward in control_flags {
            control_flags_dir += {0.0, 0.0, -1.0}
        }
        if control_flags_dir != {0.0, 0.0, 0.0} {
            camera_direction += hlsl.normalize(control_flags_dir)
        }
    
        if camera_direction != {0.0, 0.0, 0.0} {
            camera_direction = hlsl.float3(camera_speed_mod) * hlsl.float3(per_frame_speed) * camera_direction
        }
    
        // Compute temporary camera matrix for orienting player inputted direction vector
        world_from_view := hlsl.inverse(camera_view_from_world(game_state.viewport_camera))
        camera_direction4 := hlsl.float4{camera_direction.x, camera_direction.y, camera_direction.z, 0.0}
        game_state.viewport_camera.position += (world_from_view * camera_direction4).xyz
    
        // Collision test the camera's bounding sphere against the terrain
        if game_state.freecam_collision {
            scoped_event(&profiler, "Collision with terrain")
            camera_collision_point: hlsl.float3
            closest_dist := math.INF_F32
            for _, &piece in game_state.triangle_meshes {
                candidate := closest_pt_triangles(position, &piece)
                candidate_dist := hlsl.distance(candidate, position)
                if candidate_dist < closest_dist {
                    camera_collision_point = candidate
                    closest_dist = candidate_dist
                }
            }
    
            if game_state.freecam_collision {
                dist := hlsl.distance(camera_collision_point, position)
                if dist < game_state.viewport_camera.collision_radius {
                    diff := game_state.viewport_camera.collision_radius - dist
                    position += diff * hlsl.normalize(position - camera_collision_point)
                }
            }
        }

        return camera_view_from_world(game_state.viewport_camera)
    }
}
