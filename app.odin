package main

import "base:runtime"

import "core:c"
import "core:fmt"
import "core:log"
import "core:math/linalg/hlsl"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"

import "vendor:sdl2"
import vk "vendor:vulkan"
import vkw "desktop_vulkan_wrapper"
import imgui "odin-imgui"


Window :: struct {
    position: [2]i32,
    resolution: [2]u32,
    display_resolution: [2]u32,
    present_mode: vk.PresentModeKHR,
    flags: sdl2.WindowFlags,
    window: ^sdl2.Window,
}

AppOption :: enum {
    LimitCPU,
    PerfProfile
}
AppOptions :: bit_set[AppOption]

App :: struct {
    logger: log.Logger,

    global_allocator: mem.Allocator,
    per_scene_allocator: mem.Allocator,
    per_frame_allocator: mem.Allocator,
    per_scene_arena: vmem.Arena,
    per_frame_arena: vmem.Arena,

    // Tracking allocators for debug builds
    global_track: mem.Tracking_Allocator,
    scene_track: mem.Tracking_Allocator,
    temp_track: mem.Tracking_Allocator,

    vgd: vkw.GraphicsDevice,
    renderer: Renderer,
    input_system: InputSystem,
    audio_system: AudioSystem,
    imgui_state: ImguiState,

    // There will be two of these in order to support
    // tick-rate/frame-rate independence
    game_state: GameState,

    app_options: AppOptions,

    current_time: time.Time,
    previous_time: time.Time,
    load_new_level: Maybe(string),
    saved_mouse_coords: hlsl.int2,
    user_config: UserConfiguration,
    window: Window,
}

app_startup :: proc(app: ^App) -> bool {
    // Parse command-line arguments
    log_level := log.Level.Info
    profile_name := "game7.spall"
    want_rt := true
    {
        context.logger = log.create_console_logger(log_level)
        argc := len(os.args)
        i := 0
        for i < len(os.args) {
            arg := os.args[i]
            if arg == "--log-level" || arg == "-l" {
                if i + 1 < argc {
                    switch os.args[i + 1] {
                        case "DEBUG": log_level = .Debug
                        case "INFO": log_level = .Info
                        case "WARNING": log_level = .Warning
                        case "ERROR": log_level = .Error
                        case "FATAL": log_level = .Fatal
                        case: log.warnf(
                            "Unrecognized --log-level \"%v\". Using default (%v)",
                            os.args[i + 1],
                            log_level,
                        )
                    }
                    i += 1
                }
            } else if arg == "--profile" || arg == "-p" {
                app.app_options += {.PerfProfile}
                if i + 1 < argc && !strings.contains(os.args[i + 1], "-") {
                    profile_name = os.args[i + 1]
                    i += 1
                }
            } else if arg == "-nort" {
                want_rt = false
            }
            i += 1
        }
        log.destroy_console_logger(context.logger)
    }

    // Set up global allocator
    app.global_allocator = runtime.heap_allocator()
    when ODIN_DEBUG {
        // Set up the tracking allocator if this is a debug build
        mem.tracking_allocator_init(&app.global_track, app.global_allocator)
        app.global_allocator = mem.tracking_allocator(&app.global_track)
    }
    context.allocator = app.global_allocator

    if .PerfProfile in app.app_options {
        profiler = init_profiler(profile_name, app.global_allocator)
    }
    scoped_event(&profiler, "App startup")

    // Set up logger
    app.logger = log.create_console_logger(log_level)
    context.logger = app.logger

    {
        scoped_event(&profiler, "App initialization")

        log.info("Initiating swag mode...")


        // Set up per-scene allocator
        {
            scoped_event(&profiler, "Create per-scene allocator")
            err := vmem.arena_init_growing(&app.per_scene_arena)
            if err != nil {
                log.errorf("Error initing virtual arena: %v", err)
            }

            app.per_scene_allocator = vmem.arena_allocator(&app.per_scene_arena)
        }

        // Set up per-frame temp allocator
        {
            scoped_event(&profiler, "Create per-frame allocator")
            err := vmem.arena_init_growing(&app.per_frame_arena)
            if err != nil {
                log.errorf("Error initing virtual arena: %v", err)
            }
            app.per_frame_allocator = vmem.arena_allocator(&app.per_frame_arena)
        }
        context.temp_allocator = app.per_frame_allocator

        when ODIN_DEBUG {
            // Set up the tracking allocator if this is a debug build
            mem.tracking_allocator_init(&app.scene_track, app.per_scene_allocator)
            app.per_scene_allocator = mem.tracking_allocator(&app.scene_track)
            mem.tracking_allocator_init(&app.temp_track, app.per_frame_allocator)
            app.per_frame_allocator = mem.tracking_allocator(&app.temp_track)
        }

        // Load user configuration
        cfg, config_err := load_user_config(USER_CONFIG_FILENAME)
        if config_err != nil {
            log.errorf("Failed to load user config: %v", config_err)
        }
        app.user_config = cfg

        // Initialize SDL2
        {
            scoped_event(&profiler, "Initialize SDL2")
            sdl2.Init({.AUDIO, .EVENTS, .GAMECONTROLLER, .VIDEO})
            log.info("Initialized SDL2")
        }

        // Use SDL2 to dynamically link against the Vulkan loader
        // This allows sdl2.Vulkan_GetVkGetInstanceProcAddr() to return a real address
        {
            scoped_event(&profiler, "sdl2.Vulkan_LoadLibrary()")
            if sdl2.Vulkan_LoadLibrary(nil) != 0 {
                s := sdl2.GetErrorString()
                log.fatalf("Failed to link Vulkan loader: %v", s)
                return false
            }
        }

        {
            scoped_event(&profiler, "Window setup")

            // Determine window resolution
            {
                desktop_display_mode: sdl2.DisplayMode
                if sdl2.GetDesktopDisplayMode(0, &desktop_display_mode) != 0 {
                    log.error("Error getting desktop display mode.")
                }
                app.window.display_resolution = hlsl.uint2 {
                    u32(desktop_display_mode.w),
                    u32(desktop_display_mode.h),
                }
                app.window.resolution = DEFAULT_RESOLUTION
                if app.user_config.flags[.ExclusiveFullscreen] || app.user_config.flags[.BorderlessFullscreen] {
                    app.window.resolution = app.window.display_resolution
                }
                if .WindowWidth in app.user_config.ints && .WindowHeight in app.user_config.ints {
                    x := app.user_config.ints[.WindowWidth]
                    y := app.user_config.ints[.WindowHeight]
                    app.window.resolution = {u32(x), u32(y)}
                }
                app.window.present_mode = .FIFO
            }

            // Determine SDL window flags
            app.window.flags = {.VULKAN,.RESIZABLE}
            if app.user_config.flags[.ExclusiveFullscreen] {
                app.window.flags += {.FULLSCREEN}
            } else if app.user_config.flags[.BorderlessFullscreen] {
                app.window.flags += {.BORDERLESS}
            }

            // Determine SDL window position
            app.window.position.x = sdl2.WINDOWPOS_CENTERED
            app.window.position.y = sdl2.WINDOWPOS_CENTERED
            if .WindowX in app.user_config.ints && .WindowY in app.user_config.ints {
                app.window.position.x = i32(app.user_config.ints[.WindowX])
                app.window.position.y = i32(app.user_config.ints[.WindowY])
            } else {
                app.user_config.ints[.WindowX] = i64(sdl2.WINDOWPOS_CENTERED)
                app.user_config.ints[.WindowY] = i64(sdl2.WINDOWPOS_CENTERED)
            }

            app.window.window = sdl2.CreateWindow(
                TITLE_WITHOUT_IMGUI,
                app.window.position.x,
                app.window.position.y,
                i32(app.window.resolution.x),
                i32(app.window.resolution.y),
                app.window.flags
            )
            sdl2.SetWindowAlwaysOnTop(app.window.window, sdl2.bool(app.user_config.flags[.AlwaysOnTop]))
        }

        // Initialize graphics device
        init_params := vkw.InitParameters {
            app_name = "Game7",
            frames_in_flight = FRAMES_IN_FLIGHT,
            desired_features = {.Window,.Raytracing},
            vk_get_instance_proc_addr = sdl2.Vulkan_GetVkGetInstanceProcAddr(),
        }
        {
            scoped_event(&profiler, "Init Vulkan")
            res: vk.Result
            app.vgd, res = vkw.init_vulkan(init_params)
            if res != .SUCCESS {
                log.errorf("Failed to initialize Vulkan : %v", res)
                return false
            }
        }

        {
            // Initialize the state required for rendering to the window
            {
                scoped_event(&profiler, "vkw.init_sdl2_window()")
                app.window.present_mode = .FIFO
                if !vkw.init_sdl2_window(&app.vgd, app.window.window, app.window.present_mode) {
                    e := sdl2.GetError()
                    log.fatalf("Couldn't init SDL2 surface: %v", e)
                    return false
                }
            }
        }


        // Now that we're done with global allocations, switch context.allocator to scene_allocator
        context.allocator = app.per_scene_allocator

        // Initialize the renderer
        app.renderer = init_renderer(&app.vgd, app.window.resolution, want_rt)
        if !app.renderer.do_raytracing {
            log.warn("Raytracing features are not supported by your GPU.")
        }

        //Dear ImGUI init
        app.imgui_state = imgui_init(&app.vgd, app.user_config, app.window.resolution)
        if app.imgui_state.show_gui {
            sdl2.SetWindowTitle(app.window.window, TITLE_WITH_IMGUI)
        }

        // Init audio system
        init_audio_system(&app.audio_system, app.user_config, app.global_allocator, app.per_scene_allocator)
        toggle_device_playback(&app.audio_system, true)

        // Main app structure storing the game's overall state
        app.game_state = init_gamestate(&app.vgd, &app.renderer, &app.audio_system, &app.user_config, app.global_allocator)

        {
            start_level := "test02"
            s, ok := app.user_config.strs[.StartLevel]
            if ok {
                start_level = s
            }
            sb: strings.Builder
            strings.builder_init(&sb, app.per_frame_allocator)
            start_path := fmt.sbprintf(&sb, "data/levels/%v.lvl", start_level)
            load_level_file(&app.vgd, &app.renderer, &app.audio_system, &app.game_state, &app.user_config, start_path)
        }

        // Init input system
        context.allocator = app.global_allocator
        is_lookat := app.game_state.viewport_camera_id in app.game_state.lookat_controllers
        if is_lookat {
            app.input_system = init_input_system(&app.game_state.character_key_mappings, &app.game_state.mouse_mappings, &app.game_state.button_mappings)
        } else {
            app.input_system = init_input_system(&app.game_state.freecam_key_mappings, &app.game_state.mouse_mappings, &app.game_state.button_mappings)
        }

        app.current_time = time.now()          // Time in nanoseconds since UNIX epoch
        app.previous_time = time.time_add(app.current_time, time.Duration(-1_000_000)) //current_time - time.Time{_nsec = 1}
        app.saved_mouse_coords = hlsl.int2 {0, 0}
    }

    return true
}

//@(disabled=!ODIN_DEBUG)
app_shutdown :: proc(app: ^App) {
    scoped_event(&profiler, "Shutdown")
    log.destroy_console_logger(context.logger)
    gui_cleanup(&app.vgd, &app.imgui_state)
    destroy_audio_system(&app.audio_system)
    {
        scoped_event(&profiler, "Quit Vulkan")
        vkw.quit_vulkan(&app.vgd)
    }
    sdl2.DestroyWindow(app.window.window)
    sdl2.Quit()
    
    if len(app.global_track.allocation_map) > 0 {
        fmt.eprintf("=== %v allocations not freed from global allocator: ===\n", len(app.global_track.allocation_map))
        for _, entry in app.global_track.allocation_map {
            fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
        }
    }
    if len(app.global_track.bad_free_array) > 0 {
        fmt.eprintf("=== %v incorrect frees from global allocator: ===\n", len(app.global_track.bad_free_array))
        for entry in app.global_track.bad_free_array {
            fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
        }
    }
    
    if len(app.scene_track.allocation_map) > 0 {
        fmt.eprintf("=== %v allocations not freed from scene allocator: ===\n", len(app.scene_track.allocation_map))
        for _, entry in app.scene_track.allocation_map {
            fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
        }
    }
    if len(app.scene_track.bad_free_array) > 0 {
        fmt.eprintf("=== %v incorrect frees from scene allocator: ===\n", len(app.scene_track.bad_free_array))
        for entry in app.scene_track.bad_free_array {
            fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
        }
    }

    mem.tracking_allocator_destroy(&app.global_track)
    mem.tracking_allocator_destroy(&app.scene_track)
    mem.tracking_allocator_destroy(&app.temp_track)

    quit_profiler(&profiler)
}



// EditorResponseType :: enum {
//     MoveTerrainPiece,
//     MoveStaticScenery,
//     MoveAnimatedScenery,
//     MoveEnemy,
//     MoveCoin,
//     MovePlayerSpawn,
//     AddTerrainPiece,
//     AddStaticScenery,
//     AddAnimatedScenery,
//     AddCoin
// }
// EditorResponse :: struct {
//     type: EditorResponseType,
//     index: u32
// }

EditVerb :: enum {
    None = 0,
    Select,
    Delete,
    AddCollision,
    PaintCoins,
    PlaceEnemy,
    //PlaceMacGuffen,
}

scene_editor :: proc(
    game_state: ^GameState,
    gd: ^vkw.GraphicsDevice,
    renderer: ^Renderer,
    gui: ^ImguiState,
    user_config: ^UserConfiguration,
    scene_allocator := context.allocator
) {
    scoped_event(&profiler, "Scene editor update")

    builder: strings.Builder
    strings.builder_init(&builder, context.temp_allocator)
    io := imgui.GetIO()

    show_editor := gui.show_gui && user_config.flags[.SceneEditor]
    if show_editor {
        defer imgui.End()
        if imgui.Begin("Scene editor", &user_config.flags[.SceneEditor]) {

            // Spawn point editor
            {
                imgui.DragFloat3("Player spawn", &game_state.level_start, 0.1)
                flag := .ShowPlayerSpawn in game_state.debug_vis_flags
                if imgui.Checkbox("Show player spawn", &flag) {
                    game_state.debug_vis_flags ~= {.ShowPlayerSpawn}
                }
    
                // resp, ok := game_state.editor_response.(EditorResponse)
                // disable := false
                // move_text : cstring = "Move player spawn"
                // if ok {
                //     if resp.type == .MovePlayerSpawn {
                //         disable = true
                //         move_text = "Moving player spawn..."
                //     }
                // }
                // imgui.BeginDisabled(disable)
                // if imgui.Button(move_text) {
                //     game_state.editor_response = EditorResponse {
                //         type = .MovePlayerSpawn,
                //         index = 0
                //     }
                // }
                // imgui.EndDisabled()
    
                imgui.Separator()
            }
    
            if imgui.Button("Delete all coins") {
                for len(game_state.coins) > 0 {
                    delete_coin(game_state, 0)
                }
            }
    
            // Edit verb selection
            {
                imgui.Text("Active edit verb")
                // @TODO: Use reflection here
                if imgui.RadioButton("None", game_state.edit_verb == .None) {
                    game_state.previous_edit_verb = game_state.edit_verb
                    game_state.edit_verb = .None
                }
                if imgui.RadioButton("Select", game_state.edit_verb == .Select) {
                    game_state.previous_edit_verb = game_state.edit_verb
                    game_state.edit_verb = .Select
                }
                if imgui.RadioButton("Add collision", game_state.edit_verb == .AddCollision) {
                    game_state.previous_edit_verb = game_state.edit_verb
                    game_state.edit_verb = .AddCollision
                }
                if imgui.RadioButton("Delete", game_state.edit_verb == .Delete) {
                    game_state.previous_edit_verb = game_state.edit_verb
                    game_state.edit_verb = .Delete
                }
                if imgui.RadioButton("Paint coins", game_state.edit_verb == .PaintCoins) {
                    game_state.previous_edit_verb = game_state.edit_verb
                    game_state.edit_verb = .PaintCoins
                }
                if imgui.RadioButton("Place enemy", game_state.edit_verb == .PlaceEnemy) {
                    game_state.previous_edit_verb = game_state.edit_verb
                    game_state.edit_verb = .PlaceEnemy
                }
            }
            imgui.Separator()

            // Clear certain states when verbs are unselected
            if game_state.edit_verb != .Select && game_state.previous_edit_verb == .Select {
                old_id, exists := game_state.selected_entity.?
                if exists {
                    old_m := &game_state.static_models[old_id]
                    old_m.flags -= {.Highlighted}
                }
                game_state.selected_entity = nil
            }

            selected_entity_options :: proc(game_state: ^GameState, renderer: ^Renderer) {
                id, ok := game_state.selected_entity.?
                eid := c.int(id)

                lookat_controller, lookat_ok := &game_state.lookat_controllers[game_state.viewport_camera_id]
                imgui.BeginDisabled(!lookat_ok)
                if imgui.SliderInt("Selected Entity", &eid, 0, c.int(game_state._next_id - 1)) {
                    new_id := EntityID(eid)
                    lookat_controller.target = new_id
                    game_state.selected_entity = new_id
                    id = new_id
                }
                imgui.EndDisabled()

                if ok {
                    imgui.Text("Selected #%i", c.int(id))
                    tform, has_tform := &game_state.transforms[id]
                    assert(has_tform)
                    moved := imgui.DragFloat3("Position", &tform.position, 0.2)
                    moved |= imgui.DragFloat("Scale", &tform.scale, 0.2)

                    ai, ai_ok := &game_state.enemy_ais[id]
                    if ai_ok {
                        gui_dropdown_enum("AI state", &ai.state, context.temp_allocator)
                    }
                    
                    mesh, mesh_ok := &game_state.triangle_meshes[id]
                    if mesh_ok {
                        if moved {
                            mmat := get_transform_matrix(tform^)
                            rebuild_static_triangle_mesh(mesh, mmat)
                        }
                        imgui.Text("Selected collision has %i triangles.", len(mesh.triangles))
                    }

                    if imgui.CollapsingHeader("Graphics data") {
                        model_instance, model_ok := &game_state.static_models[id]
                        if model_ok {
                            model := get_static_model(renderer^, model_instance.handle)
                            
                            imgui.Text("Model primitives:")
                            for prim in model.primitives {
                                mat := get_material(renderer^, prim.material)
                                mat_changed := false

                                mat_changed |= imgui.ColorPicker4("Material base color", &mat.base_color)
                                if mat_changed {
                                    renderer.dirty_flags += {.Material}
                                }
                            }
                        }
                    }

                    imgui.BeginDisabled(!lookat_ok)
                    if imgui.Button("Lock-on") {
                        lookat_controller.target = id
                    }
                    imgui.EndDisabled()
                    imgui.SameLine()
                    if imgui.Button("Delete") {
                        delete_entity(game_state, id)
                        game_state.selected_entity = nil
                    }
                }
            }
    
            // Per-verb options menu
            imgui.Text("Edit controls:")
            switch game_state.edit_verb {
                case .None: { imgui.Text("No edit verb selected.") }
                case .Select: {
                    {
                        b := .ShowBoundingSpheres in game_state.debug_vis_flags
                        if imgui.Checkbox("Show bounding spheres", &b) {
                            game_state.debug_vis_flags ~= {.ShowBoundingSpheres}
                        }
                    }
                    selected_entity_options(game_state, renderer)
                }
                case .AddCollision: {
                    model_strings := make([dynamic]cstring, 0, 64, context.temp_allocator)
                    selected: c.int
                    if gui_list_files("./data/models", &model_strings, &selected, "Choose model", context.temp_allocator) {
                        path := fmt.sbprintf(&builder, "./data/models/%v", model_strings[selected])
                        cpath := strings.to_cstring(&builder)
                        positions := get_glb_positions(cpath, scene_allocator)
                        trimesh := new_static_triangle_mesh(positions[:], IDENTITY_MATRIX4x4, scene_allocator)
                        model := load_gltf_static_model(gd, renderer, cpath, scene_allocator)

                        new_id := gamestate_next_id(game_state)
                        game_state.transforms[new_id] = {
                            scale = 1.0
                        }
                        game_state.triangle_meshes[new_id] = trimesh
                        game_state.static_models[new_id] = StaticModelInstance {
                            handle = model,
                        }
                    }
                    strings.builder_reset(&builder)
                }
                case .Delete: {
                    {
                        b := .ShowBoundingSpheres in game_state.debug_vis_flags
                        if imgui.Checkbox("Show bounding spheres", &b) {
                            game_state.debug_vis_flags ~= {.ShowBoundingSpheres}
                        }
                    }
                    imgui.Checkbox("Don't delete collision geometry", &game_state.dont_delete_collision)
                }
                case .PaintCoins: {
                    imgui.DragFloat("Coin paint radius", &game_state.coin_paint_radius, 0.0, 50.0)
                    imgui.DragFloat("Coin z offset", &game_state.coin_z_offset, 0.0, 50.0)
                }
                case .PlaceEnemy: {
                    selected_entity_options(game_state, renderer)
                }
            }
            imgui.Separator()
    
            // Entity view
            // {
            //     for id in 0..<game_state._next_id {
            //         eid := EntityID(id)
            //         transform, exists := &game_state.transforms[eid]
            //         if exists {
            //             fmt.sbprintf(&builder, "Entity #%v", id)
            //             cs := strings.to_cstring(&builder)
            //             if imgui.CollapsingHeader(cs) {
                            
            //             }
            //             strings.builder_reset(&builder)
            //         }
            //     }
            // }
            // imgui.Separator()
    
            // Raw component view
            // {
            //     for id, ai in game_state.enemy_ais {
            //         imgui.Text("EnemyAI with id %i", id)
            //         label := fmt.sbprintf(&builder, "%#v", ai)
            //         cs := strings.to_cstring(&builder)
            //         imgui.Text(cs)
            //         strings.builder_reset(&builder)
            //     }
            // }
    
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
    }
}