package main

import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/linalg/hlsl"
import "core:mem"
import "core:os"
import "core:os/os2"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "vendor:sdl2"

import vkw "desktop_vulkan_wrapper"
import imgui "odin-imgui"

TerrainPiece :: struct {
    collision: StaticTriangleCollision,
    position: hlsl.float3,
    rotation: quaternion128,
    scale: f32,
    model: ^StaticModelData,
}

delete_terrain_piece :: proc(using t: ^TerrainPiece) {
    delete_static_triangles(&collision)
}

StaticScenery :: struct {
    model: ^StaticModelData,
    position: hlsl.float3,
    rotation: quaternion128,
    scale: f32,
}

AnimatedScenery :: struct {
    model: ^SkinnedModelData,
    position: hlsl.float3,
    rotation: quaternion128,
    scale: f32,
    anim_idx: u32,
    anim_t: f32,
    anim_speed: f32,
}

CHARACTER_TOTAL_JUMPS :: 2
CharacterState :: enum {
    Grounded,
    Falling
}
CharacterFlags :: bit_set[enum {
    MovingLeft,
    MovingRight,
    MovingBack,
    MovingForward,
}]
Character :: struct {
    collision: Sphere,
    state: CharacterState,
    velocity: hlsl.float3,
    gravity_factor: f32,
    acceleration: hlsl.float3,
    deceleration_speed: f32,
    facing: hlsl.float3,
    move_speed: f32,
    sprint_speed: f32,
    jump_speed: f32,
    remaining_jumps: u32,
    anim_t: f32,
    anim_speed: f32,
    control_flags: CharacterFlags,
    mesh_data: ^SkinnedModelData,
}

EnemyState :: enum {
    Unbothered
}
Enemy :: struct {
    position: hlsl.float3,
    collision_radius: f32,
    rotation: quaternion128,
    scale: f32,

    state: EnemyState,
}

DebugVisualizationFlags :: bit_set[enum {
    ShowPlayerSpawn,
    ShowPlayerHitSphere
}]

AirBullet :: struct {
    collision: Sphere,
    path_start: hlsl.float3,
    path_end: hlsl.float3,
    t: f32,
}

// Megastruct for all game-specific data
GameState :: struct {
    character: Character,
    viewport_camera: Camera,

    air_bullet: Maybe(AirBullet),
    bullet_travel_time: f32,

    // Scene/Level data
    terrain_pieces: [dynamic]TerrainPiece,
    static_scenery: [dynamic]StaticScenery,
    animated_scenery: [dynamic]AnimatedScenery,
    enemies: [dynamic]Enemy,
    character_start: hlsl.float3,

    // Icosphere mesh for visualizing spherical collision and points
    sphere_mesh: ^StaticModelData,

    enemy_mesh: ^StaticModelData,

    debug_vis_flags: DebugVisualizationFlags,

    // Editor state
    editor_response: Maybe(EditorResponse),
    current_level_path: string,
    savename_buffer: [1024]c.char,

    bgm_id: uint,


    camera_follow_point: hlsl.float3,
    camera_follow_speed: f32,
    timescale: f32,

    freecam_collision: bool,
    freecam_speed_multiplier: f32,
    freecam_slow_multiplier: f32,

    borderless_fullscreen: bool,
    exclusive_fullscreen: bool,
}

init_gamestate :: proc(
    gd: ^vkw.Graphics_Device,
    renderer: ^Renderer,
    user_config: ^UserConfiguration,
) -> GameState {
    game_state: GameState
    game_state.freecam_collision = user_config.flags[.FreecamCollision]
    game_state.borderless_fullscreen = user_config.flags[.BorderlessFullscreen]
    game_state.exclusive_fullscreen = user_config.flags[.ExclusiveFullscreen]
    game_state.timescale = 1.0
    game_state.bullet_travel_time = 0.144

    // Load icosphere mesh for debug visualization
    game_state.sphere_mesh = load_gltf_static_model(gd, renderer, "data/models/icosphere.glb")

    // Load enemy mesh
    game_state.enemy_mesh = load_gltf_static_model(gd, renderer, "data/models/majoras_moon.glb")
    
    // Load animated test glTF model
    skinned_model: ^SkinnedModelData
    {
        path : cstring = "data/models/CesiumMan.glb"
        skinned_model = load_gltf_skinned_model(gd, renderer, path)
    }

    game_state.character = Character {
        collision = {
            position = game_state.character_start,
            radius = 0.8
        },
        velocity = {},
        gravity_factor = 1.0,
        deceleration_speed = 0.1,
        state = .Falling,
        facing = {0.0, 1.0, 0.0},
        move_speed = 7.0,
        sprint_speed = 14.0,
        jump_speed = 10.0,
        remaining_jumps = 2,
        anim_speed = 0.856,
        mesh_data = skinned_model
    }

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
            distance = 8.0
        },
    }
    game_state.freecam_speed_multiplier = 5.0
    game_state.freecam_slow_multiplier = 1.0 / 5.0
    if user_config.flags[.FollowCam] do game_state.viewport_camera.control_flags += {.Follow}

    game_state.camera_follow_point = game_state.character.collision.position
    game_state.camera_follow_speed = 6.0

    return game_state
}

delete_game :: proc(using g: ^GameState) {
    for &piece in terrain_pieces do delete_terrain_piece(&piece)
    delete(terrain_pieces)
}

load_level_file :: proc(
    gd: ^vkw.Graphics_Device,
    renderer: ^Renderer,
    audio_system: ^AudioSystem,
    game_state: ^GameState,
    user_config: ^UserConfiguration,
    path: string
) -> bool {
    // Audio lock while loading level data
    sdl2.LockAudioDevice(audio_system.device_id)
    defer sdl2.UnlockAudioDevice(audio_system.device_id)

    free_all(context.allocator)
    audio_new_scene(audio_system)
    renderer_new_scene(renderer)
    game_state^ = init_gamestate(gd, renderer, user_config)

    lvl_bytes, lvl_err := os2.read_entire_file(path, context.temp_allocator)
    if lvl_err != nil {
        log.errorf("Error reading entire level file: %v", lvl_err)
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

    // @TODO: Read this from level file
    game_state.bgm_id, _ = open_music_file(audio_system, "data/audio/rc2_museum.ogg")

    read_head : u32 = 0

    // Character start
    game_state.character_start = read_thing_from_buffer(lvl_bytes, type_of(game_state.character_start), &read_head)
    game_state.character.collision.position = game_state.character_start
    game_state.camera_follow_point = game_state.character.collision.position

    // Terrain pieces
    ter_len := read_thing_from_buffer(lvl_bytes, u32, &read_head)
    for _ in 0..<ter_len {
        name := read_string_from_buffer(lvl_bytes, &read_head)
        path_builder: strings.Builder
        strings.builder_init(&path_builder, context.temp_allocator)
        fmt.sbprintf(&path_builder, "data/models/%v", name)
        path, _ := strings.to_cstring(&path_builder)
        model := load_gltf_static_model(gd, renderer, path)

        position := read_thing_from_buffer(lvl_bytes, hlsl.float3, &read_head)
        rotation := read_thing_from_buffer(lvl_bytes, quaternion128, &read_head)
        scale := read_thing_from_buffer(lvl_bytes, f32, &read_head)
        mmat := translation_matrix(position) * linalg.to_matrix4(rotation) * uniform_scaling_matrix(scale)
        
        positions := get_glb_positions(path)
        collision := new_static_triangle_mesh(positions[:], mmat)
        append(&game_state.terrain_pieces, TerrainPiece {
            collision = collision,
            position = position,
            rotation = rotation,
            scale = scale,
            model = model,
        })
    }

    // Static scenery
    stat_len := read_thing_from_buffer(lvl_bytes, u32, &read_head)
    for _ in 0..<stat_len {
        name := read_string_from_buffer(lvl_bytes, &read_head)
        path_builder: strings.Builder
        strings.builder_init(&path_builder, context.temp_allocator)
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
    }

    // Animated scenery
    anim_len := read_thing_from_buffer(lvl_bytes, u32, &read_head)
    for _ in 0..<anim_len {
        name := read_string_from_buffer(lvl_bytes, &read_head)
        path_builder: strings.Builder
        strings.builder_init(&path_builder, context.temp_allocator)
        fmt.sbprintf(&path_builder, "data/models/%v", name)
        path, _ := strings.to_cstring(&path_builder)
        model := load_gltf_skinned_model(gd, renderer, path)

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
    }

    path_clone, err := strings.clone(path)
    if err != nil {
        log.errorf("Error allocating current_level_path string: %v", err)
    }
    game_state.current_level_path = path_clone
    return true
}

write_level_file :: proc(gamestate: ^GameState, path: string) {
    // @TODO: Apply deduplication

    output_size := 0

    output_size += size_of(gamestate.character_start)

    output_size += size_of(u32)
    for piece in gamestate.terrain_pieces {
        output_size += size_of(u32)
        output_size += len(piece.model.name)
        output_size += size_of(piece.position)
        output_size += size_of(piece.rotation)
        output_size += size_of(piece.scale)
    }

    output_size += size_of(u32)
    for scenery in gamestate.static_scenery {
        output_size += size_of(u32)
        output_size += len(scenery.model.name)
        output_size += size_of(scenery.position)
        output_size += size_of(scenery.rotation)
        output_size += size_of(scenery.scale)
    }

    output_size += size_of(u32)
    for scenery in gamestate.animated_scenery {
        output_size += size_of(u32)
        output_size += len(scenery.model.name)
        output_size += size_of(scenery.position)
        output_size += size_of(scenery.rotation)
        output_size += size_of(scenery.scale)
    }
    
    write_head : u32 = 0
    raw_output_buffer := make([dynamic]byte, output_size, context.temp_allocator)

    write_thing_to_buffer :: proc(buffer: []byte, ptr: ^$T, head: ^u32) {
        amount := size_of(T)
        mem.copy_non_overlapping(&buffer[head^], ptr, amount)
        head^ += u32(amount)
    }

    write_thing_to_buffer(raw_output_buffer[:], &gamestate.character_start, &write_head)

    ter_len := u32(len(gamestate.terrain_pieces))
    write_thing_to_buffer(raw_output_buffer[:], &ter_len, &write_head)
    for &piece in gamestate.terrain_pieces {
        name := &piece.model.name
        name_len := u32(len(name))
        write_thing_to_buffer(raw_output_buffer[:], &name_len, &write_head)
        
        mem.copy_non_overlapping(&raw_output_buffer[write_head], raw_data(name^), int(name_len))
        write_head += name_len

        write_thing_to_buffer(raw_output_buffer[:], &piece.position, &write_head)
        write_thing_to_buffer(raw_output_buffer[:], &piece.rotation, &write_head)
        write_thing_to_buffer(raw_output_buffer[:], &piece.scale, &write_head)
    }

    static_len := u32(len(gamestate.static_scenery))
    write_thing_to_buffer(raw_output_buffer[:], &static_len, &write_head)
    for &scenery in gamestate.static_scenery {
        name := &scenery.model.name
        name_len := u32(len(name))
        write_thing_to_buffer(raw_output_buffer[:], &name_len, &write_head)
        
        mem.copy_non_overlapping(&raw_output_buffer[write_head], raw_data(name^), int(name_len))
        write_head += name_len

        write_thing_to_buffer(raw_output_buffer[:], &scenery.position, &write_head)
        write_thing_to_buffer(raw_output_buffer[:], &scenery.rotation, &write_head)
        write_thing_to_buffer(raw_output_buffer[:], &scenery.scale, &write_head)
    }

    anim_len := u32(len(gamestate.animated_scenery))
    write_thing_to_buffer(raw_output_buffer[:], &anim_len, &write_head)
    for &scenery in gamestate.animated_scenery {
        name := &scenery.model.name
        name_len := u32(len(name))
        write_thing_to_buffer(raw_output_buffer[:], &name_len, &write_head)
        
        mem.copy_non_overlapping(&raw_output_buffer[write_head], raw_data(name^), int(name_len))
        write_head += name_len

        write_thing_to_buffer(raw_output_buffer[:], &scenery.position, &write_head)
        write_thing_to_buffer(raw_output_buffer[:], &scenery.rotation, &write_head)
        write_thing_to_buffer(raw_output_buffer[:], &scenery.scale, &write_head)
    }


    //lvl_file, lvl_err := os2.open("data/levels/hardcoded_test.lvl", {.Write,.Create,.Trunc})
    lvl_file, lvl_err := create_write_file(path)
    if lvl_err != nil {
        log.errorf("Error opening level file: %v", lvl_err)
    }
    defer os.close(lvl_file)

    _, err := os.write(lvl_file, raw_output_buffer[:])
    if err != nil {
        log.errorf("Error writing level data: %v", err)
    }

    path_clone, p_err := strings.clone(path)
    if p_err != nil {
        log.errorf("Error allocating current_level_path string: %v", err)
    }
    gamestate.current_level_path = path_clone

    log.infof("Finished saving level to \"%v\"", path)
}

new_level :: proc(game_state: ^GameState, scene_allocator := context.allocator) {
    free_all(scene_allocator)


}

EditorResponseType :: enum {
    MoveTerrainPiece,
    MoveStaticScenery,
    MoveAnimatedScenery,
    MoveEnemy,
    MovePlayerSpawn,
    AddTerrainPiece,
    AddStaticScenery,
    AddAnimatedScenery,
}
EditorResponse :: struct {
    type: EditorResponseType,
    index: u32
}

scene_editor :: proc(
    game_state: ^GameState,
    gd: ^vkw.Graphics_Device,
    renderer: ^Renderer,
    gui: ^ImguiState,
    user_config: ^UserConfiguration
) {
    builder: strings.Builder
    strings.builder_init(&builder, context.temp_allocator)
    io := imgui.GetIO()

    show_editor := gui.show_gui && user_config.flags[.SceneEditor]
    if show_editor && imgui.Begin("Scene editor", &user_config.flags[.SceneEditor]) {
        // Spawn point editor
        {
            imgui.DragFloat3("Player spawn", &game_state.character_start, 0.1)
            flag := .ShowPlayerSpawn in game_state.debug_vis_flags
            if imgui.Checkbox("Show player spawn", &flag) do game_state.debug_vis_flags ~= {.ShowPlayerSpawn}
            
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
        {
            objects := &game_state.terrain_pieces
            label : cstring = "Terrain pieces"
            editor_response := &game_state.editor_response
            response_type := EditorResponseType.MoveTerrainPiece
            if imgui.CollapsingHeader(label) {
                imgui.PushID(label)
                if len(objects) == 0 {
                    imgui.Text("Nothing to see here!")
                }
                if imgui.Button("Add") {
                    editor_response^ = EditorResponse {
                        type = .AddTerrainPiece,
                        index = 0
                    }
                }
                imgui.Separator()
                for &mesh, i in objects {
                    imgui.PushIDInt(c.int(i))
        
                    fmt.sbprintf(&builder, "%v", mesh.model.name)
                    imgui.Text(strings.to_cstring(&builder))
                    strings.builder_reset(&builder)
        
                    fmt.sbprintf(&builder, "Position %v", mesh.position)
                    imgui.Text(strings.to_cstring(&builder))
                    strings.builder_reset(&builder)
                    
                    fmt.sbprintf(&builder, "Rotation: %v", mesh.rotation)
                    strings.builder_reset(&builder)
                    imgui.Text(strings.to_cstring(&builder))
    
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
                        terrain_piece_clone_idx = i
                    }
                    imgui.SameLine()
                    if imgui.Button("Delete") {
                        unordered_remove(objects, i)
                        game_state.editor_response = nil
                    }
                    if imgui.Button("Rebuild collision mesh") {
                        rot := linalg.to_matrix4(mesh.rotation)
                        mm := translation_matrix(mesh.position) * rot * scaling_matrix(mesh.scale)
                        rebuild_static_triangle_mesh(&game_state.terrain_pieces[i].collision, mm)
                    }
                    imgui.EndDisabled()
                    imgui.Separator()
        
                    imgui.PopID()
                }
                imgui.PopID()
            }
        }

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
        
                    fmt.sbprintf(&builder, "%v", mesh.model.name)
                    imgui.Text(strings.to_cstring(&builder))
                    strings.builder_reset(&builder)
        
                    fmt.sbprintf(&builder, "Position %v", mesh.position)
                    imgui.Text(strings.to_cstring(&builder))
                    strings.builder_reset(&builder)
                    
                    fmt.sbprintf(&builder, "Rotation: %v", mesh.rotation)
                    strings.builder_reset(&builder)
                    imgui.Text(strings.to_cstring(&builder))
    
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
        
                    fmt.sbprintf(&builder, "%v", mesh.model.name)
                    imgui.Text(strings.to_cstring(&builder))
                    strings.builder_reset(&builder)
        
                    fmt.sbprintf(&builder, "Position %v", mesh.position)
                    imgui.Text(strings.to_cstring(&builder))
                    strings.builder_reset(&builder)
                    
                    fmt.sbprintf(&builder, "Rotation: %v", mesh.rotation)
                    strings.builder_reset(&builder)
                    imgui.Text(strings.to_cstring(&builder))
    
                    imgui.DragFloat3("Position", &mesh.position, 0.1)
    
                    imgui.SliderFloat("Scale", &mesh.scale, 0.0, 50.0)
    
                    anim := &renderer.animations[mesh.model.first_animation_idx]
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
                    new_enemy := Enemy {
                        position = {},
                        collision_radius = 0.8,
                        rotation = {},
                        scale = 1.0,
                        state = .Unbothered
                    }
                    append(&game_state.enemies, new_enemy)
                }
                for &mesh, i in objects {
                    imgui.PushIDInt(c.int(i))
        
                    fmt.sbprintf(&builder, "Position %v", mesh.position)
                    imgui.Text(strings.to_cstring(&builder))
                    strings.builder_reset(&builder)
                    
                    fmt.sbprintf(&builder, "Rotation: %v", mesh.rotation)
                    strings.builder_reset(&builder)
                    imgui.Text(strings.to_cstring(&builder))
    
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
                        enemy_to_clone_idx = i
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
        {
            clone_idx, clone_ok := terrain_piece_clone_idx.?
            if clone_ok {
                new_terrain_piece := game_state.terrain_pieces[clone_idx]
                new_terrain_piece.collision = copy_static_triangle_mesh(game_state.terrain_pieces[clone_idx].collision)

                append(&game_state.terrain_pieces, new_terrain_piece)
                new_idx := len(game_state.terrain_pieces) - 1
                game_state.editor_response = EditorResponse {
                    type = .MoveTerrainPiece,
                    index = u32(new_idx)
                }
            }
        }
        {
            clone_idx, clone_ok := static_to_clone_idx.?
            if clone_ok {
                append(&game_state.static_scenery, game_state.static_scenery[clone_idx])
                new_idx := len(game_state.static_scenery) - 1
                game_state.editor_response = EditorResponse {
                    type = .MoveStaticScenery,
                    index = u32(new_idx)
                }
            }
        }
        {
            clone_idx, clone_ok := anim_to_clone_idx.?
            if clone_ok {
                append(&game_state.animated_scenery, game_state.animated_scenery[clone_idx])
                new_idx := len(game_state.animated_scenery) - 1
                game_state.editor_response = EditorResponse {
                    type = .MoveAnimatedScenery,
                    index = u32(new_idx)
                }
            }
        }
    }
    if show_editor do imgui.End()
}

player_update :: proc(game_state: ^GameState, output_verbs: ^OutputVerbs, dt: f32) {
    char := &game_state.character

    if output_verbs.bools[.PlayerReset] {
        char.collision.position = game_state.character_start
        char.velocity = {}
        char.acceleration = {}
    }

    GRAVITY_ACCELERATION : hlsl.float3 : {0.0, 0.0, 2.0 * -9.8}           // m/s^2
    TERMINAL_VELOCITY :: -100000.0                                  // m/s

    // Handle sprint
    this_frame_move_speed := char.move_speed
    {
        amount, ok := output_verbs.floats[.Sprint]
        if ok {
            this_frame_move_speed = linalg.lerp(char.move_speed, char.sprint_speed, amount)
        }
    }

    // Set current xy velocity (and character facing) to whatever user input is
    {
        // X and Z bc view space is x-right, y-up, z-back
        v := output_verbs.float2s[.PlayerTranslate]
        xv := v.x
        zv := v.y

        // Boolean input handling
        {
            flags := &char.control_flags

            r, ok := output_verbs.bools[.PlayerTranslateLeft]
            if ok {
                if r {
                    flags^ += {.MovingLeft}
                } else {
                    flags^ -= {.MovingLeft}
                }
            }
            r, ok = output_verbs.bools[.PlayerTranslateRight]
            if ok {
                if r {
                    flags^ += {.MovingRight}
                } else {
                    flags^ -= {.MovingRight}
                }
            }
            r, ok = output_verbs.bools[.PlayerTranslateBack]
            if ok {
                if r {
                    flags^ += {.MovingBack}
                } else {
                    flags^ -= {.MovingBack}
                }
            }
            r, ok = output_verbs.bools[.PlayerTranslateForward]
            if ok {
                if r {
                    flags^ += {.MovingForward}
                } else {
                    flags^ -= {.MovingForward}
                }
            }
            if .MovingLeft in flags^ do xv += -1.0
            if .MovingRight in flags^ do xv += 1.0
            if .MovingBack in flags^ do zv += -1.0
            if .MovingForward in flags^ do zv += 1.0
        }

        // Input vector is in view space, so we transform to world space
        world_invector := hlsl.float4 {-zv, xv, 0.0, 0.0}
        world_invector = yaw_rotation_matrix(-game_state.viewport_camera.yaw) * world_invector
        if hlsl.length(world_invector) > 1.0 {
            world_invector = hlsl.normalize(world_invector)
        }

        // Now we have a representation of the player's input vector in world space

        char.acceleration = {world_invector.x, world_invector.y, 0.0}
        if hlsl.length(char.acceleration) == 0 {
            to_zero := hlsl.float2 {0.0, 0.0} - char.velocity.xy
            char.velocity.xy += char.deceleration_speed * to_zero
        }
        char.velocity.xy += char.acceleration.xy
        if math.abs(hlsl.length(char.velocity.xy)) > this_frame_move_speed {
            char.velocity.xy = this_frame_move_speed * hlsl.normalize(char.velocity.xy)
        }
        movement_dist := hlsl.length(char.velocity.xy)
        char.anim_t += char.anim_speed * dt * movement_dist

        if xv != 0.0 || zv != 0.0 {
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
                if char.remaining_jumps > 0 {
                    char.velocity.z = char.jump_speed
                    char.state = .Falling
                    char.remaining_jumps -= 1
                }
                char.gravity_factor = 1.0
            } else {
                // To not jumping...
                char.gravity_factor = 2.2
            }
        }
    }

    // Apply gravity to velocity, clamping downward speed if necessary
    char.velocity += dt * char.gravity_factor * GRAVITY_ACCELERATION
    if char.velocity.z < TERMINAL_VELOCITY {
        char.velocity.z = TERMINAL_VELOCITY
    }

    // Compute motion interval
    motion_endpoint := char.collision.position + dt * char.velocity
    motion_interval := Segment {
        start = char.collision.position,
        end = motion_endpoint
    }

    // Compute closest point to terrain along with
    // vector opposing player mo
    closest_pt := closest_pt_terrain(motion_endpoint, game_state.terrain_pieces[:])
    collision_normal := hlsl.normalize(motion_endpoint - closest_pt)

    // Main player character state machine
    switch char.state {
        case .Grounded: {
            // Push out of ground
            dist := hlsl.distance(closest_pt, char.collision.position)
            if dist < char.collision.radius {
                remaining_dist := char.collision.radius - dist
                if hlsl.dot(collision_normal, hlsl.float3{0.0, 0.0, 1.0}) < 0.5 {
                    char.collision.position = motion_endpoint + remaining_dist * collision_normal
                } else {
                    char.collision.position = motion_endpoint
                    
                }
            } else {
                char.collision.position = motion_endpoint
            }
    
            //Check if we need to bump ourselves up or down
            {
                tolerance_segment := Segment {
                    start = char.collision.position + {0.0, 0.0, 0.0},
                    end = char.collision.position + {0.0, 0.0, -char.collision.radius - 0.1}
                }
                tolerance_t, normal, okt := intersect_segment_terrain_with_normal(&tolerance_segment, game_state.terrain_pieces[:])
                tolerance_point := tolerance_segment.start + tolerance_t * (tolerance_segment.end - tolerance_segment.start)
                if okt {
                    char.collision.position = tolerance_point + {0.0, 0.0, char.collision.radius}
                    if hlsl.dot(normal, hlsl.float3{0.0, 0.0, 1.0}) >= 0.5 {
                        char.velocity.z = 0.0
                        char.state = .Grounded
                    }
                } else {
                    char.state = .Falling
                }
            }
        }
        case .Falling: {
            // Then do collision test against triangles

            d := hlsl.distance(char.collision.position, closest_pt)
            hit := d < char.collision.radius

            if hit {
                // Hit terrain
                remaining_d := char.collision.radius - d
                char.collision.position = motion_endpoint + remaining_d * collision_normal
                n_dot := hlsl.dot(collision_normal, hlsl.float3{0.0, 0.0, 1.0})
                if n_dot >= 0.5 && char.velocity.z < 0.0 {
                    // Floor
                    char.remaining_jumps = CHARACTER_TOTAL_JUMPS
                    char.state = .Grounded
                } else if n_dot < -0.1 && char.velocity.z > 0.0 {
                    // Ceiling
                    char.velocity.z = 0.0
                }
            } else {
                // Didn't hit anything, still falling.
                char.collision.position = motion_endpoint
            }
        }
    }

    // Shoot bullet
    if output_verbs.bools[.PlayerShoot] {
        start_pos := char.collision.position
        game_state.air_bullet = AirBullet {
            collision = Sphere {
                position = start_pos,
                radius = 0.1
            },

            t = 0.0,
            path_start = start_pos,
            path_end = start_pos + 2.0 * char.facing,
        }
    }

    // @TODO: Maybe move this out of the player update proc? Maybe we don't need to...
    bullet, bok := &game_state.air_bullet.?
    if bok && bullet.t <= game_state.bullet_travel_time{
        // Bullet update
        col := char.collision
        bullet.t += dt
        endpoint := col.position + 2.5 * char.facing
        bullet.collision.position = linalg.lerp(bullet.path_start, bullet.path_end, bullet.t / game_state.bullet_travel_time)
    } else {
        game_state.air_bullet = nil
    }

    // Camera follow point chases player
    target_pt := char.collision.position
    game_state.camera_follow_point = exponential_smoothing(game_state.camera_follow_point, target_pt, game_state.camera_follow_speed, dt)
}

player_draw :: proc(using game_state: ^GameState, gd: ^vkw.Graphics_Device, renderer: ^Renderer) {
    y := -character.facing
    z := hlsl.float3 {0.0, 0.0, 1.0}
    x := hlsl.cross(y, z)
    rotate_mat := hlsl.float4x4 {
        x[0], y[0], z[0], 0.0,
        x[1], y[1], z[1], 0.0,
        x[2], y[2], z[2], 0.0,
        0.0, 0.0, 0.0, 1.0,
    }

    // @TODO: Remove this matmul as this is just to correct an error with the model
    rotate_mat *= yaw_rotation_matrix(-math.PI / 2.0)
    
    end := get_animation_endtime(&renderer.animations[game_state.character.mesh_data.first_animation_idx])
    for character.anim_t > end {
        character.anim_t -= end
    }
    ddata := SkinnedDraw {
        world_from_model = rotate_mat,
        anim_idx = 0,
        anim_t = character.anim_t,
    }

    col := &game_state.character.collision
    ddata.world_from_model[3][0] = col.position.x
    ddata.world_from_model[3][1] = col.position.y
    ddata.world_from_model[3][2] = col.position.z - col.radius
    draw_ps1_skinned_mesh(gd, renderer, game_state.character.mesh_data, &ddata)

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
}

enemies_update :: proc(game_state: ^GameState) {
    
}






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
        for game_state.viewport_camera.yaw < -2.0 * math.PI do game_state.viewport_camera.yaw += 2.0 * math.PI
        for game_state.viewport_camera.yaw > 2.0 * math.PI do game_state.viewport_camera.yaw -= 2.0 * math.PI
        if game_state.viewport_camera.pitch <= -math.PI / 2.0 do game_state.viewport_camera.pitch = -math.PI / 2.0 + 0.0001
        if game_state.viewport_camera.pitch >= math.PI / 2.0 do game_state.viewport_camera.pitch = math.PI / 2.0 - 0.0001
        
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
        hit_t, hit := dynamic_sphere_vs_terrain_t(&s, game_state.terrain_pieces[:], &interval)
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
    
        camera_rotation += output_verbs.float2s[.RotateCamera]
        camera_direction.x += output_verbs.floats[.TranslateFreecamX]
    
        // Not a sign error. In view-space, -Z is forward
        camera_direction.z -= output_verbs.floats[.TranslateFreecamY]
    
        camera_speed_mod += game_state.freecam_speed_multiplier * output_verbs.floats[.Sprint]
        //camera_speed_mod += game_state.freecam_slow_multiplier * output_verbs.floats[.Crawl]
    
    
        CAMERA_SPEED :: 10
        per_frame_speed := CAMERA_SPEED * dt
    
        if .Speed in control_flags do camera_speed_mod *= game_state.freecam_speed_multiplier
        if .Slow in control_flags do camera_speed_mod *= game_state.freecam_slow_multiplier
    
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
        world_from_view := hlsl.inverse(camera_view_from_world(game_state.viewport_camera))
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
