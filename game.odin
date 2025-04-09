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

DebugVisualizationFlags :: bit_set[enum {
    ShowPlayerSpawn,
    ShowPlayerHitSphere
}]

// SerializedInstance :: struct {
//     position: [3]f32,
//     rotation: quaternion128,
//     scale: f32
// }
// SerializedMesh :: struct {
//     name: string,
//     instance_count: u32,
//     instances: []SerializedInstance,
// }
// LevelFileFormat :: struct {
//     character_start: hlsl.float3,
//     terrain: []SerializedMesh,
//     static_scenery: []SerializedMesh,
//     animated_scenery: []SerializedMesh,
// }

load_level_file :: proc(gd: ^vkw.Graphics_Device, renderer: ^Renderer, gamestate: ^GameState, path: string) -> bool {
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

    read_head : u32 = 0

    // Character start
    gamestate.character_start = read_thing_from_buffer(lvl_bytes, type_of(gamestate.character_start), &read_head)

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
        append(&gamestate.terrain_pieces, TerrainPiece {
            collision = collision,
            position = position,
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

        append(&gamestate.static_scenery, StaticScenery {
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
        
        append(&gamestate.animated_scenery, AnimatedScenery {
            model = model,
            position = position,
            rotation = rotation,
            scale = scale,
            anim_idx = 0,
            anim_t = 0.0,
            anim_speed = 1.0,
        })
    }

    return true
}

write_level_file :: proc(gamestate: ^GameState) {
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
    lvl_file, lvl_err := create_write_file("data/levels/hardcoded_test.lvl")
    if lvl_err != nil {
        log.errorf("Error opening level file: %v", lvl_err)
    }
    defer os.close(lvl_file)

    _, err := os.write(lvl_file, raw_output_buffer[:])
    if err != nil {
        log.errorf("Error writing level data: %v", err)
    }

    log.info("Finished saving level.")
}

// Megastruct for all game-specific data
GameState :: struct {
    character: Character,
    viewport_camera: Camera,

    // Scene/Level data
    terrain_pieces: [dynamic]TerrainPiece,
    static_scenery: [dynamic]StaticScenery,
    animated_scenery: [dynamic]AnimatedScenery,
    character_start: hlsl.float3,

    // Icosphere mesh for visualizing spherical collision and points
    sphere_mesh: ^StaticModelData,

    debug_vis_flags: DebugVisualizationFlags,

    // Editor state
    editor_response: Maybe(EditorResponse),


    camera_follow_point: hlsl.float3,
    camera_follow_speed: f32,
    timescale: f32,

    freecam_collision: bool,
    freecam_speed_multiplier: f32,
    freecam_slow_multiplier: f32,

    borderless_fullscreen: bool,
    exclusive_fullscreen: bool,
}

init_gamestate :: proc() -> GameState {
    game_state: GameState


    return game_state
}

delete_game :: proc(using g: ^GameState) {
    for &piece in terrain_pieces do delete_terrain_piece(&piece)
    delete(terrain_pieces)
}


EditorResponseType :: enum {
    MoveTerrainPiece,
    MoveStaticScenery,
    MoveAnimatedScenery,
    MovePlayerSpawn,
    AddAnimatedScenery
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
    io := imgui.GetIO()

    builder: strings.Builder
    strings.builder_init(&builder, context.temp_allocator)

    show_editor := gui.show_gui && user_config.flags["scene_editor"]
    if show_editor && imgui.Begin("Scene editor", &user_config.flags["scene_editor"]) {
        // Spawn point editor
        {
            imgui.Text("Player spawn is at (%f, %f, %f)", game_state.character_start.x, game_state.character_start.y, game_state.character_start.z)
            flag := .ShowPlayerSpawn in game_state.debug_vis_flags
            if imgui.Checkbox("Show player spawn", &flag) do game_state.debug_vis_flags ~= {.ShowPlayerSpawn}
            imgui.Separator()
        }

        filewalk_proc :: proc(
            info: os.File_Info,
            in_err: os.Error,
            user_data: rawptr
        ) -> (err: os.Error, skip_dir: bool) {
            if !info.is_dir {
                item_array := cast(^[dynamic]cstring)user_data
                append(item_array, strings.clone_to_cstring(info.name, context.temp_allocator))
            }

            err = nil
            skip_dir = false
            return
        }
        list_items := make([dynamic]cstring, 0, 16, context.temp_allocator)

        // @TODO: Is this a bug in the filepath package?
        // The File_Info structs are supposed to be allocated
        // with context.temp_allocator, but it appears that it
        // actually uses context.allocator
        old_alloc := context.allocator
        context.allocator = context.temp_allocator
        walk_error := filepath.walk("./data/models", filewalk_proc, &list_items)
        context.allocator = old_alloc

        if walk_error != nil {
            log.errorf("Error walking models dir: %v", walk_error)
        }

        // Show listbox
        current_item : c.int = 0
        if imgui.ListBox("glb files", &current_item, &list_items[0], c.int(len(list_items)), 15) {
            // Insert selected item into animated scenery list
            log.infof("You clicked item #%v", current_item)
            fmt.sbprintf(&builder, "data/models/%v", list_items[current_item])
            path_cstring, _ := strings.to_cstring(&builder)

            // Try to load as a skinned model
            // Load as a static model if loading as skinned fails
            model := load_gltf_skinned_model(gd, renderer, path_cstring)
            if model != nil {
                append(&game_state.animated_scenery, AnimatedScenery {
                    model = model,
                    scale = 1.0,
                    anim_speed = 1.0
                })
            } else {
                model2 := load_gltf_static_model(gd, renderer, path_cstring)
                append(&game_state.static_scenery, StaticScenery {
                    model = model2,
                    scale = 1.0,
                })
            }

            strings.builder_reset(&builder)
        }
        imgui.Separator()

        idk_proc :: proc(
            renderer: ^Renderer,
            objects: ^[dynamic]$T,
            label: cstring,
            editor_response: ^Maybe(EditorResponse),
            response_type: EditorResponseType,
            builder: ^strings.Builder
        ) -> Maybe(int) {
            clone_idx: Maybe(int)
            if imgui.CollapsingHeader(label) {
                imgui.PushID(label)
                if len(objects) == 0 {
                    imgui.Text("Nothing to see here!")
                }
                for &mesh, i in objects {
                    imgui.PushIDInt(c.int(i))
        
                    fmt.sbprintf(builder, "%v", mesh.model.name)
                    imgui.Text(strings.to_cstring(builder))
                    strings.builder_reset(builder)
        
                    fmt.sbprintf(builder, "Position %v", mesh.position)
                    imgui.Text(strings.to_cstring(builder))
                    strings.builder_reset(builder)
                    
                    fmt.sbprintf(builder, "Rotation: %v", mesh.rotation)
                    strings.builder_reset(builder)
                    imgui.Text(strings.to_cstring(builder))

                    imgui.DragFloat3("Position", &mesh.position, 0.1)

                    imgui.SliderFloat("Scale", &mesh.scale, 0.0, 50.0)

                    when T == AnimatedScenery {
                        anim := &renderer.animations[mesh.model.first_animation_idx]
                        imgui.SliderFloat("Anim t", &mesh.anim_t, 0.0, get_animation_endtime(anim))
                        imgui.SliderFloat("Anim speed", &mesh.anim_speed, 0.0, 20.0)
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
        
                    if disable_button do imgui.BeginDisabled()
                    if imgui.Button(move_text) {
                        editor_response^ = EditorResponse {
                            type = response_type,
                            index = u32(i)
                        }
                    }
                    imgui.SameLine()
                    if imgui.Button("Clone") {
                        clone_idx = i
                    }
                    imgui.SameLine()
                    if imgui.Button("Delete") {
                        unordered_remove(objects, i)
                        editor_response^ = nil
                    }
                    if disable_button do imgui.EndDisabled()
                    imgui.Separator()
        
                    imgui.PopID()
                }
                imgui.PopID()
            }
            return clone_idx
        }

        // Terrain pieces
        // terrain_piece_clone_idx := idk_proc(
        //     renderer,
        //     &game_state.terrain_pieces,
        //     "Terrain pieces",
        //     &game_state.editor_response,
        //     .MoveTerrainPiece,
        //     &builder
        // )
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
        
                    if disable_button do imgui.BeginDisabled()
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
                    if disable_button do imgui.EndDisabled()
                    imgui.Separator()
        
                    imgui.PopID()
                }
                imgui.PopID()
            }
        }

        // Static meshes
        static_to_clone_idx := idk_proc(
            renderer,
            &game_state.static_scenery,
            "Static scenery",
            &game_state.editor_response,
            .MoveStaticScenery,
            &builder
        )

        // Animated meshes
        anim_to_clone_idx := idk_proc(
            renderer,
            &game_state.animated_scenery,
            "Animated scenery",
            &game_state.editor_response,
            .MoveAnimatedScenery,
            &builder
        )

        // Do object clone
        {
            clone_idx, clone_ok := terrain_piece_clone_idx.?
            if clone_ok {
                append(&game_state.terrain_pieces, game_state.terrain_pieces[clone_idx])
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
    acceleration: hlsl.float3,
    deceleration_speed: f32,
    facing: hlsl.float3,
    move_speed: f32,
    jump_speed: f32,
    remaining_jumps: u32,
    anim_t: f32,
    anim_speed: f32,
    control_flags: CharacterFlags,
    mesh_data: ^SkinnedModelData,
}

player_update :: proc(game_state: ^GameState, output_verbs: ^OutputVerbs, dt: f32) {
    if output_verbs.bools[.PlayerReset] {
        game_state.character.collision.position = game_state.character_start
        game_state.character.velocity = {}
        game_state.character.acceleration = {}
    }

    GRAVITY_ACCELERATION : hlsl.float3 : {0.0, 0.0, 2.0 * -9.8}           // m/s^2
    TERMINAL_VELOCITY :: -100000.0                                  // m/s

    // Set current xy velocity (and character facing) to whatever user input is
    {
        // X and Z bc view space is x-right, y-up, z-back
        v := output_verbs.float2s[.PlayerTranslate]
        xv := v.x
        zv := v.y

        // Boolean input handling
        {
            r, ok := output_verbs.bools[.PlayerTranslateLeft]
            if ok {
                if r {
                    game_state.character.control_flags += {.MovingLeft}
                } else {
                    game_state.character.control_flags -= {.MovingLeft}
                }
            }
            r, ok = output_verbs.bools[.PlayerTranslateRight]
            if ok {
                if r {
                    game_state.character.control_flags += {.MovingRight}
                } else {
                    game_state.character.control_flags -= {.MovingRight}
                }
            }
            r, ok = output_verbs.bools[.PlayerTranslateBack]
            if ok {
                if r {
                    game_state.character.control_flags += {.MovingBack}
                } else {
                    game_state.character.control_flags -= {.MovingBack}
                }
            }
            r, ok = output_verbs.bools[.PlayerTranslateForward]
            if ok {
                if r {
                    game_state.character.control_flags += {.MovingForward}
                } else {
                    game_state.character.control_flags -= {.MovingForward}
                }
            }
        }
        if .MovingLeft in game_state.character.control_flags do xv += -1.0
        if .MovingRight in game_state.character.control_flags do xv += 1.0
        if .MovingBack in game_state.character.control_flags do zv += -1.0
        if .MovingForward in game_state.character.control_flags do zv += 1.0

        // Input vector is in view space, so we transform to world space
        world_invector := hlsl.float4 {-zv, xv, 0.0, 0.0}
        world_invector = yaw_rotation_matrix(-game_state.viewport_camera.yaw) * world_invector
        if hlsl.length(world_invector) > 1.0 {
            world_invector = hlsl.normalize(world_invector)
        }

        // Now we have a representation of the player's input vector in world space

        game_state.character.acceleration = {world_invector.x, world_invector.y, 0.0}
        if hlsl.length(game_state.character.acceleration) == 0 {
            to_zero := hlsl.float2 {0.0, 0.0} - game_state.character.velocity.xy
            game_state.character.velocity.xy += game_state.character.deceleration_speed * to_zero
        }
        game_state.character.velocity.xy += game_state.character.acceleration.xy
        if math.abs(hlsl.length(game_state.character.velocity.xy)) > game_state.character.move_speed {
            game_state.character.velocity.xy = game_state.character.move_speed * hlsl.normalize(game_state.character.velocity.xy)
        }
        movement_dist := hlsl.length(game_state.character.velocity.xy)
        game_state.character.anim_t += game_state.character.anim_speed * dt * movement_dist

        if xv != 0.0 || zv != 0.0 {
            game_state.character.facing = -hlsl.normalize(world_invector).xyz
        }
    }

    // Handle jump command
    if output_verbs.bools[.PlayerJump] && game_state.character.remaining_jumps > 0 {
        game_state.character.velocity.z = game_state.character.jump_speed
        game_state.character.state = .Falling
        game_state.character.remaining_jumps -= 1
    }

    // Main player character state machine
    switch game_state.character.state {
        case .Grounded: {
            //Check if we need to bump ourselves up or down
            if game_state.character.velocity.z <= 0.0 {
                tolerance_segment := Segment {
                    start = game_state.character.collision.position + {0.0, 0.0, 0.0},
                    end = game_state.character.collision.position + {0.0, 0.0, -game_state.character.collision.radius - 0.1}
                }
                tolerance_t, normal, okt := intersect_segment_terrain_with_normal(&tolerance_segment, game_state.terrain_pieces[:])
                tolerance_point := tolerance_segment.start + tolerance_t * (tolerance_segment.end - tolerance_segment.start)
                if okt {
                    game_state.character.collision.position = tolerance_point + {0.0, 0.0, game_state.character.collision.radius}
                    if hlsl.dot(normal, hlsl.float3{0.0, 0.0, 1.0}) >= 0.5 {
                        game_state.character.velocity.z = 0.0
                        game_state.character.state = .Grounded
                    }
                } else {
                    game_state.character.state = .Falling
                }
            }

            // Compute motion interval
            motion_endpoint := game_state.character.collision.position + dt * game_state.character.velocity
            motion_interval := Segment {
                start = game_state.character.collision.position,
                end = motion_endpoint
            }

            // Push out of ground
            //p, n := closest_pt_terrain_with_normal(motion_endpoint, game_state.terrain_pieces[:])
            p := closest_pt_terrain(motion_endpoint, game_state.terrain_pieces[:])
            n := hlsl.normalize(motion_endpoint - p)
            dist := hlsl.distance(p, game_state.character.collision.position)
            if dist < game_state.character.collision.radius {
                remaining_dist := game_state.character.collision.radius - dist
                if hlsl.dot(n, hlsl.float3{0.0, 0.0, 1.0}) < 0.5 {
                    game_state.character.collision.position = motion_endpoint + remaining_dist * n
                } else {
                    game_state.character.collision.position = motion_endpoint
                    
                }
            } else {
                game_state.character.collision.position = motion_endpoint
            }
        }
        case .Falling: {
            // Apply gravity to velocity, clamping downward speed if necessary
            game_state.character.velocity += dt * GRAVITY_ACCELERATION
            if game_state.character.velocity.z < TERMINAL_VELOCITY {
                game_state.character.velocity.z = TERMINAL_VELOCITY
            }
    
            // Compute motion interval
            motion_endpoint := game_state.character.collision.position + dt * game_state.character.velocity
            motion_interval := Segment {
                start = game_state.character.collision.position,
                end = motion_endpoint
            }

            // Check if player canceled jump early
            not_canceled, ok := output_verbs.bools[.PlayerJump]
            if ok && !not_canceled && game_state.character.velocity.z > 0.0 {
                game_state.character.velocity.z *= 0.1
            }

            // Then do collision test against triangles
            //closest_pt, n := closest_pt_terrain_with_normal(motion_endpoint, game_state.terrain_pieces[:])
            closest_pt := closest_pt_terrain(motion_endpoint, game_state.terrain_pieces[:])
            n := hlsl.normalize(motion_endpoint - closest_pt)

            d := hlsl.distance(game_state.character.collision.position, closest_pt)
            hit := d < game_state.character.collision.radius

            if hit {
                // Hit terrain
                remaining_d := game_state.character.collision.radius - d
                game_state.character.collision.position = motion_endpoint + remaining_d * n
                n_dot := hlsl.dot(n, hlsl.float3{0.0, 0.0, 1.0})
                if n_dot >= 0.5 && game_state.character.velocity.z < 0.0 {
                    // Floor
                    game_state.character.remaining_jumps = CHARACTER_TOTAL_JUMPS
                    game_state.character.velocity = {}
                    game_state.character.state = .Grounded
                } else if n_dot < -0.1 && game_state.character.velocity.z > 0.0 {
                    // Ceiling
                    game_state.character.velocity.z = 0.0
                }
            } else {
                // Didn't hit anything, still falling.
                game_state.character.collision.position = motion_endpoint
            }
        }
    }

    // Camera follow point chases player
    target_pt := game_state.character.collision.position
    game_state.camera_follow_point = exponential_smoothing(game_state.camera_follow_point, target_pt, game_state.camera_follow_speed, dt)
}

player_draw :: proc(using game_state: ^GameState, gd: ^vkw.Graphics_Device, renderer: ^Renderer) {
    y := character.facing
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

        return lookat_view_from_world(&game_state.viewport_camera)
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
                dist := hlsl.distance(camera_collision_point, position)
                if dist < game_state.viewport_camera.collision_radius {
                    diff := game_state.viewport_camera.collision_radius - dist
                    position += diff * hlsl.normalize(position - camera_collision_point)
                }
            }
        }

        return camera_view_from_world(&game_state.viewport_camera)
    }
}
