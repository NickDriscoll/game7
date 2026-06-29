package main

import "base:runtime"

import "core:c"
import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:math"
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

DEFAULT_LOOKAT_DISTANCE :: 2.0

UndoEditPlayerSpawn :: struct {
    old_pos: hlsl.float3,
}

UndoCommand :: union {
    UndoEditPlayerSpawn
}

Window :: struct {
    position: [2]i32,
    resolution: [2]u32,
    display_resolution: [2]u32,
    present_mode: vk.PresentModeKHR,
    window: ^sdl2.Window,
    minimized: bool,
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

    // Engine subsystems
    vgd: vkw.VulkanGraphicsDevice,
    renderer: Renderer,
    input_system: InputSystem,
    audio_system: AudioSystem,
    gui: ImguiState,
    network: Network,

    // There will be two of these in order to support
    // tick-rate/frame-rate independence
    game_state: GameState,

    app_options: AppOptions,

    // Editor state
    edit_verb: EditVerb,
    previous_edit_verb: EditVerb,
    selected_entity: Maybe(EntityID),
    current_level: string,
    savename_buffer: [1024]c.char,
    last_placed_position: hlsl.float3,
    coin_paint_radius: f32,
    coin_z_offset: f32,
    dont_delete_collision: bool,
    new_enemy_state: EnemyState,

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
    logfile: Maybe(string)
    want_rt := true
    {
        context.logger = log.create_console_logger(log_level)
        argc := len(os.args)
        i := 1  // Start at one to skip executable path arg
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
            } else if arg == "--logfile" || arg == "-lf" {
                if i + 1 < argc && !strings.contains(os.args[i + 1], "-") {
                    filepath := os.args[i + 1]
                    logfile = filepath
                } else {
                    logfile = "game7.log"
                }
            } else if arg == "-nort" {
                want_rt = false
            } else {
                log.warnf("Unrecognized argument: %v", arg)
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
        init_profiler(&profiler, profile_name, app.global_allocator)
    }
    scoped_event(&profiler, "App startup")

    // Set up logger
    logfile_path, do_file_logging := logfile.?
    if do_file_logging {
        f, err := os.open(logfile_path, {.Write,.Create})
        if err != nil {
            log.errorf("Error opening logfile: %v", err)
        }
        assert(err == nil)
        app.logger = log.create_file_logger(f, log_level)

        // Log a message with the unconditional console logger
        log.infof("Log messages with be written to %v", logfile_path)
    } else {
        app.logger = log.create_console_logger(log_level)
    }
    context.logger = app.logger

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
    cfg, config_err := load_user_config(USER_CONFIG_FILENAME, app.global_allocator)
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
        library_path : cstring = nil
        when ODIN_OS == .Darwin {
            library_path = "./libvulkan.1.4.350.dylib"
        }
        if sdl2.Vulkan_LoadLibrary(library_path) != 0 {
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
        }

        // Determine SDL window flags
        flags : sdl2.WindowFlags = {.VULKAN,.RESIZABLE}
        if app.user_config.flags[.ExclusiveFullscreen] {
            flags += {.FULLSCREEN}
        } else if app.user_config.flags[.BorderlessFullscreen] {
            flags += {.BORDERLESS}
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
            flags
        )
        sdl2.SetWindowAlwaysOnTop(app.window.window, sdl2.bool(app.user_config.flags[.AlwaysOnTop]))

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
        app.renderer = init_renderer(&app.vgd, want_rt)
        if !app.renderer.do_raytracing && want_rt {
            log.warn("Raytracing features are not supported by your GPU.")
        }

        //Dear ImGUI init
        app.gui = imgui_init(&app.vgd, app.user_config, app.window.resolution, app.global_allocator)
        if app.gui.show_gui {
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
            load_level_file(app, start_path)
        }

        // Init input system
        app.input_system = init_input_system(app.global_allocator)
        is_lookat := app.game_state.viewport_cameras[0] in app.game_state.lookat_controllers
        if is_lookat {
            app.input_system.key_mappings[VerbRecipient.PlayerOne] = &app.game_state.character_key_mappings
        } else {
            app.input_system.key_mappings[VerbRecipient.PlayerOne] = &app.game_state.freecam_key_mappings
        }
        app.input_system.key_mappings[VerbRecipient.System] = &app.game_state.system_key_mappings
        app.input_system.mouse_mappings[VerbRecipient.System] = &app.game_state.mouse_mappings
        app.input_system.ctrl_key_mappings = &app.game_state.ctrl_key_mappings
        app.input_system.system_button_mappings = &app.game_state.system_button_mappings
        for recipient in VerbRecipient {
            app.input_system.button_mappings[recipient] = &app.game_state.button_mappings[recipient]
        }

        app.current_time = time.now()          // Time in nanoseconds since UNIX epoch
        app.previous_time = time.time_add(app.current_time, time.Duration(-1_000_000)) //current_time - time.Time{_nsec = 1}
        app.saved_mouse_coords = hlsl.int2 {0, 0}
    }

    // Init network subsystem
    app.network = network_init(app.user_config)

    app.coin_paint_radius = 1.0
    app.coin_z_offset = 1.0
    app.dont_delete_collision = true

    return true
}

//@(disabled=!ODIN_DEBUG)
app_shutdown :: proc(app: ^App) {
    scoped_event(&profiler, "Shutdown")
    log.destroy_console_logger(context.logger)
    gui_cleanup(&app.vgd, &app.gui)
    destroy_audio_system(&app.audio_system)
    {
        scoped_event(&profiler, "Quit Vulkan")
        vkw.quit_vulkan(&app.vgd)
    }
    sdl2.DestroyWindow(app.window.window)
    sdl2.Quit()

    if len(app.global_track.allocation_map) > 0 {
        log.debugf("=== %v allocations not freed from global allocator: ===\n", len(app.global_track.allocation_map))
        for _, entry in app.global_track.allocation_map {
            log.debugf("- %v bytes @ %v\n", entry.size, entry.location)
        }
    }
    if len(app.global_track.bad_free_array) > 0 {
        log.debugf("=== %v incorrect frees from global allocator: ===\n", len(app.global_track.bad_free_array))
        for entry in app.global_track.bad_free_array {
            log.debugf("- %p @ %v\n", entry.memory, entry.location)
        }
    }

    if len(app.scene_track.allocation_map) > 0 {
        log.debugf("=== %v allocations not freed from scene allocator: ===\n", len(app.scene_track.allocation_map))
        for _, entry in app.scene_track.allocation_map {
            log.debugf("- %v bytes @ %v\n", entry.size, entry.location)
        }
    }
    if len(app.scene_track.bad_free_array) > 0 {
        log.debugf("=== %v incorrect frees from scene allocator: ===\n", len(app.scene_track.bad_free_array))
        for entry in app.scene_track.bad_free_array {
            log.debugf("- %p @ %v\n", entry.memory, entry.location)
        }
    }

    mem.tracking_allocator_destroy(&app.global_track)
    mem.tracking_allocator_destroy(&app.scene_track)
    mem.tracking_allocator_destroy(&app.temp_track)

    quit_profiler(&profiler)
}

new_scene :: proc(app: ^App, scene_allocator := context.allocator) {
    vkw.device_wait_idle(&app.vgd)

    // Have to free rendering resources before scene_allocator is reset
    renderer_free_resources(&app.renderer)
    free_all(scene_allocator)
    audio_new_scene(&app.audio_system, scene_allocator)
    renderer_new_scene(&app.renderer, scene_allocator)
    gamestate_new_scene(&app.game_state, &app.vgd, &app.renderer, &app.user_config, scene_allocator)
    app.selected_entity = nil
    app.current_level = ""

    // Add default collision plane
    id := gamestate_next_id(&app.game_state)
    app.game_state.transforms[id] = Transform {
        position = {0.0, 0.0, 0.0},
        scale = 1.0
    }
    app.game_state.triangle_meshes[id] = load_static_triangle_mesh(
        "data/models/plane.glb",
        IDENTITY_MATRIX4x4,
        app.per_scene_allocator
    )
    app.game_state.static_models[id] = StaticModelInstance {
        handle = app.game_state.plane_mesh,
    }
}

do_user_menus :: proc(app: ^App, allocator := context.allocator) -> (VerbType, string) {
    retval : VerbType = nil
    retstr: string

    // Handle menu stack
    @static last_was_menu := false
    if queue.len(app.gui.menu_stack) > 0 {
        active_menu := queue.front_ptr(&app.gui.menu_stack)
        app.gui.menu_player_idx = active_menu.player_idx

        // Renderer and input state
        app.renderer.uniforms.fade_to_black = 0.4
        app.renderer.uniforms.flags += {.BlackAndWhite}
        app.input_system.button_mappings[active_menu.player_idx] = &app.game_state.menu_button_mappings[active_menu.player_idx]
        app.input_system.key_mappings[active_menu.player_idx] = &app.game_state.character_menu_key_mappings

        retval, retstr = gui_user_menu(app.gui, active_menu.items[:], allocator)
        last_was_menu = true
    } else if last_was_menu {
        app.renderer.uniforms.fade_to_black = 1.0
        app.renderer.uniforms.flags -= {.BlackAndWhite}
        app.input_system.button_mappings[app.gui.menu_player_idx] = &app.game_state.button_mappings[app.gui.menu_player_idx]
        app.input_system.key_mappings[app.gui.menu_player_idx] = &app.game_state.character_key_mappings
        app.game_state.paused = false
        last_was_menu = false
    }

    return retval, retstr
}

EditFlag :: enum {
    MovePlayerSpawn,
    MoveSelectedEntity
}
EditFlags :: bit_set[EditFlag]

EditVerb :: enum {
    None = 0,
    Select,
    Delete,
    AddCollision,
    EditDirectionalLights,
    PaintCoins,
    PlaceEnemy,
    PlaceHoveringEnemy,
    EditPlayerSpawn,
    //PlaceMacGuffen,
}
@rodata EDIT_VERB_STRINGS : [EditVerb]cstring = {
    .None = "None",
    .Select = "Select",
    .Delete = "Delete Entity",
    .AddCollision = "Add Collision mesh",
    .EditDirectionalLights = "Edit directional lights",
    .PaintCoins = "Paint coins",
    .PlaceEnemy = "Place enemy",
    .PlaceHoveringEnemy = "Place hovering enemy",
    .EditPlayerSpawn = "Move player spawn"
}

scene_editor :: proc(
    app: ^App,
    scene_allocator := context.allocator
) {
    scoped_event(&profiler, "Scene editor update")

    builder: strings.Builder
    strings.builder_init(&builder, context.temp_allocator)
    io := imgui.GetIO()

    show_editor := app.gui.show_gui && app.user_config.flags[.SceneEditor]
    if show_editor {
        defer imgui.End()
        if imgui.Begin("Scene editor", &app.user_config.flags[.SceneEditor]) {
            {
                @static b := false
                imgui.Checkbox("I acknowledge that the undo feature is very broken", &b)
                imgui.BeginDisabled(!b)
                if imgui.Button("Undo") {

                }
                imgui.EndDisabled()
                imgui.Separator()
            }

            if imgui.Button("Delete all coins") {
                for len(app.game_state.coins) > 0 {
                    delete_coin(&app.game_state, 0)
                }
            }

            // Edit verb selection
            verb_changed := false
            {
                imgui.Text("Active edit verb:")
                for label, verb in EDIT_VERB_STRINGS {
                    if imgui.RadioButton(label, app.edit_verb == verb) {
                        app.previous_edit_verb = app.edit_verb
                        app.edit_verb = verb
                        verb_changed = true
                    }
                }
            }
            imgui.Separator()

            // Clear certain states when verbs are unselected
            if verb_changed {
                old_id, exists := app.selected_entity.?
                if exists {
                    static_m, has_static := &app.game_state.static_models[old_id]
                    if has_static {
                        static_m.flags -= {.Highlighted}
                    }

                    skinned_m, has_skinned := &app.game_state.skinned_models[old_id]
                    if has_skinned {
                        skinned_m.flags -= {.Highlighted}
                    }
                }
                app.selected_entity = nil
            }

            selected_entity_options :: proc(game_state: ^GameState, renderer: ^Renderer, selected_entity: ^Maybe(EntityID)) {
                id, ok := selected_entity.?
                eid := c.int(id)
                cam_id := game_state.viewport_cameras[0]
                _, has_cam := &game_state.cameras[cam_id]
                assert(has_cam)
                lookat_controller, lookat_ok := &game_state.lookat_controllers[cam_id]

                if imgui.SliderInt("Selected Entity", &eid, 0, c.int(game_state._next_id - 1)) {
                    new_id := EntityID(eid)
                    selected_entity^ = new_id
                    id = new_id

                    if !lookat_ok {
                        focal_tform := &game_state.transforms[id]
                        game_state.lookat_controllers[cam_id] = LookatController {
                            current_focal_point = focal_tform.position,
                            distance = DEFAULT_LOOKAT_DISTANCE
                        }
                    }

                    lookat_controller.target = new_id
                }

                if ok {
                    imgui.Text("Selected #%i", c.int(id))
                    tform, has_tform := &game_state.transforms[id]
                    if !has_tform {
                        // Entity must have been deleted
                        selected_entity^ = nil
                        return
                    }
                    old_tform := tform^
                    moved := imgui.DragFloat3("Position", &tform.position, 0.2)
                    moved |= imgui.DragFloat("Scale", &tform.scale, 0.2)

                    moving_something := .MoveSelectedEntity in game_state.edit_flags
                    imgui.BeginDisabled(moving_something)
                    label : cstring = "Move"
                    if moving_something {
                        label = "Moving..."
                    }
                    if imgui.Button(label) {
                        game_state.edit_flags += {.MoveSelectedEntity}
                    }
                    imgui.EndDisabled()

                    ai, ai_ok := &game_state.enemy_ais[id]
                    if ai_ok {
                        gui_dropdown_enum("AI state", &ai.state, context.temp_allocator)
                    }

                    hovering_ai, hovering_ok := &game_state.hovering_enemies[id]
                    if hovering_ok {
                        imgui.DragFloat3("Home position", &hovering_ai.home_position, 0.1)
                    }

                    mesh, mesh_ok := &game_state.triangle_meshes[id]
                    if mesh_ok {
                        if moved {
                            event := MovedEntityEvent {
                                id = id,
                                old_tform = old_tform
                            }
                            append(&game_state.moved_collision, event)
                        }
                        imgui.Text("Selected collision has %i triangles.", len(mesh.triangles))
                    }

                    if imgui.CollapsingHeader("Graphics data") {
                        model_instance, model_ok := &game_state.static_models[id]
                        if model_ok {
                            model := get_static_model(renderer, model_instance.handle)

                            imgui.Text("Model primitives:")
                            for prim in model.primitives {
                                mat := renderer.materials[prim.material]
                                mat_changed := false

                                mat_changed |= imgui.ColorPicker4("Material base color", &mat.base_color)
                                if mat_changed {
                                    renderer.dirty_flags += {.Material}
                                }
                            }
                        }
                    }

                    if imgui.Button("Lock-on") {
                       if !lookat_ok {
                            focal_tform := &game_state.transforms[id]
                            game_state.lookat_controllers[cam_id] = LookatController {
                                current_focal_point = focal_tform.position,
                                distance = DEFAULT_LOOKAT_DISTANCE
                            }
                        }

                        lookat_controller.target = id
                    }
                    imgui.SameLine()
                    if imgui.Button("Delete") {
                        delete_entity(game_state, id)
                        selected_entity^ = nil
                    }
                }
            }

            // Per-verb options menu
            @static draw_spawn := false
            imgui.Text("Edit controls:")
            switch app.edit_verb {
                case .None: { imgui.Text("No edit verb selected.") }
                case .Select: {
                    {
                        b := .ShowBoundingSpheres in app.game_state.debug_vis_flags
                        if imgui.Checkbox("Show bounding spheres", &b) {
                            app.game_state.debug_vis_flags ~= {.ShowBoundingSpheres}
                        }
                    }
                    selected_entity_options(&app.game_state, &app.renderer, &app.selected_entity)
                }
                case .AddCollision: {
                    model_strings := make([dynamic]cstring, 0, 64, context.temp_allocator)
                    selected: c.int
                    if gui_list_files("./data/models", &model_strings, &selected, "Choose model", context.temp_allocator) {
                        path := fmt.sbprintf(&builder, "./data/models/%v", model_strings[selected])
                        cpath := strings.to_cstring(&builder)
                        // positions := get_glb_positions(cpath, scene_allocator)
                        // trimesh := new_static_triangle_mesh(positions[:], IDENTITY_MATRIX4x4, scene_allocator)
                        // model := load_gltf_static_model(&app.vgd, &app.renderer, cpath, scene_allocator)

                        new_id := gamestate_next_id(&app.game_state)
                        app.game_state.transforms[new_id] = {
                            scale = 1.0
                        }
                        app.game_state.triangle_meshes[new_id] = load_static_triangle_mesh(path, IDENTITY_MATRIX4x4, scene_allocator)
                        app.game_state.static_models[new_id] = StaticModelInstance {
                            handle = load_gltf_static_model(&app.vgd, &app.renderer, cpath, scene_allocator),
                        }
                    }
                    strings.builder_reset(&builder)
                }
                case .EditDirectionalLights: {
                    disabled := app.renderer.directional_light_count == MAX_DIRECTIONAL_LIGHTS
                    imgui.BeginDisabled(disabled)
                    label : cstring = "Add new directional light"
                    if disabled {
                        label = "Can't add any more directional lights"
                    }
                    if imgui.Button(label) {
                        ratio := f32(app.renderer.directional_light_count) / MAX_DIRECTIONAL_LIGHTS
                        app.renderer.directional_light_count += 1
                        app.renderer.directional_lights[app.renderer.directional_light_count - 1] = {
                            pitch = -math.PI / 4.0,
                            yaw = 2.0 * math.PI * ratio,
                            color = {1.0, 1.0, 1.0}
                        }
                    }
                    imgui.EndDisabled()
                    imgui.Separator()

                    to_delete: Maybe(int)
                    for i in 0..<app.renderer.directional_light_count {
                        light := &app.renderer.directional_lights[i]

                        imgui.PushIDInt(c.int(i))
                        if imgui.Button("Delete this light") {
                            to_delete = int(i)
                        }
                        imgui.DragFloat("Yaw angle", &light.yaw, 0.05)
                        imgui.DragFloat("Pitch angle", &light.pitch, 0.05)
                        if imgui.CollapsingHeader("Color picker") { imgui.ColorPicker3("Light color", &light.color) }
                        imgui.Separator()

                        for light.pitch > 2.0 * math.PI {
                            light.pitch -= 2.0 * math.PI
                        }
                        for light.pitch < -2.0 * math.PI {
                            light.pitch += 2.0 * math.PI
                        }
                        for light.yaw < 0.0 {
                            light.yaw += 2.0 * math.PI
                        }
                        for light.yaw > 2.0 * math.PI {
                            light.yaw -= 2.0 * math.PI
                        }

                        imgui.PopID()
                    }

                    if del_idx, ok := to_delete.?; ok {
                        count := app.renderer.directional_light_count
                        app.renderer.directional_lights[del_idx] = app.renderer.directional_lights[count - 1]
                        app.renderer.directional_light_count -= 1
                    }
                }
                case .Delete: {
                    {
                        b := .ShowBoundingSpheres in app.game_state.debug_vis_flags
                        if imgui.Checkbox("Show bounding spheres", &b) {
                            app.game_state.debug_vis_flags ~= {.ShowBoundingSpheres}
                        }
                    }
                    imgui.Checkbox("Don't delete collision geometry", &app.dont_delete_collision)
                }
                case .PaintCoins: {
                    imgui.DragFloat("Coin paint radius", &app.coin_paint_radius, 0.0, 50.0)
                    imgui.DragFloat("Coin z offset", &app.coin_z_offset, 0.0, 50.0)
                }
                case .PlaceEnemy: {
                    gui_dropdown_enum("AI state###0", &app.new_enemy_state, context.temp_allocator)
                    selected_entity_options(&app.game_state, &app.renderer, &app.selected_entity)
                }
                case .PlaceHoveringEnemy: {
                    selected_entity_options(&app.game_state, &app.renderer, &app.selected_entity)
                }
                case .EditPlayerSpawn: {
                    imgui.Text("Click on the terrain to place player spawn.")

                    imgui.DragFloat3("Set player spawn", &app.game_state.level_start, 0.1)

                    imgui.Checkbox("Show player spawn", &draw_spawn)
                    if draw_spawn {
                        mmat := translation_matrix(app.game_state.level_start) * uniform_scaling_matrix(0.2)
                        ddraw := DebugDraw {
                            world_from_model = mmat,
                            color = {0.0, 1.0, 0.0, 0.4}
                        }
                        draw_debug_mesh(&app.vgd, &app.renderer, app.game_state.sphere_mesh, &ddraw)
                    }

                    label : cstring = "Move player spawn"
                    moving := .MovePlayerSpawn in app.game_state.edit_flags
                    if moving {
                        label = "Moving player spawn..."
                    }
                    imgui.BeginDisabled(moving)
                    if imgui.Button(label) {
                        app.game_state.edit_flags ~= {.MovePlayerSpawn}
                    }
                    imgui.EndDisabled()

                    imgui.Separator()
                }
            }
            imgui.Separator()
        }
    }

    maybe_show_bounding_spheres :: proc(app: ^App) {
        if .ShowBoundingSpheres in app.game_state.debug_vis_flags {
            for id, instance in app.game_state.static_models {
                tform := &app.game_state.transforms[id]
                model := get_static_model(&app.renderer, instance.handle)
                pos := instance.pos_offset + tform.position + model.bounding_sphere.position
                scale := model.bounding_sphere.radius * tform.scale
                color := hlsl.float4{1.0, 1.0, 0.0, 0.2}
                selected_id, id_ok := app.selected_entity.?
                if id_ok && selected_id == id {
                    color = {0.0, 1.0, 0.0, 0.2}
                }
                ddraw := DebugDraw {
                    world_from_model = translation_matrix(pos) * uniform_scaling_matrix(scale),
                    color = color,
                }
                draw_debug_mesh(&app.vgd, &app.renderer, app.game_state.sphere_mesh, &ddraw)
            }

            for id, instance in app.game_state.skinned_models {
                tform := &app.game_state.transforms[id]
                model := get_skinned_model(&app.renderer, instance.handle)
                pos := instance.pos_offset + tform.position + model.bounding_sphere.position
                scale := model.bounding_sphere.radius * tform.scale
                color := hlsl.float4{1.0, 1.0, 0.0, 0.2}
                selected_id, id_ok := app.selected_entity.?
                if id_ok && selected_id == id {
                    color = {0.0, 1.0, 0.0, 0.2}
                }
                ddraw := DebugDraw {
                    world_from_model = translation_matrix(pos) * uniform_scaling_matrix(scale),
                    color = color,
                }
                draw_debug_mesh(&app.vgd, &app.renderer, app.game_state.sphere_mesh, &ddraw)

            }
        }
    }
    get_clicked_entity :: proc(app: ^App, filter_terrain: bool) -> (closest_id: EntityID, closest_t: f32) {
        dims : [4]f32 = {
            cast(f32)app.renderer.dockspace_dimensions.offset.x,
            cast(f32)app.renderer.dockspace_dimensions.offset.y,
            cast(f32)app.renderer.dockspace_dimensions.extent.width,
            cast(f32)app.renderer.dockspace_dimensions.extent.height,
        }
        // @TODO: Clean up the view_ray apis
        ray := view_ray(app.game_state, app.game_state.viewport_cameras[0], app.input_system.mouse_location, dims)

        closest_t = math.INF_F32
        for id, instance in app.game_state.static_models {
            tri_mesh, has_trimesh := app.game_state.triangle_meshes[id]
            if filter_terrain && has_trimesh {
                continue
            }
            if has_trimesh {
                t, intersected := intersect_ray_triangles_t(ray, tri_mesh)
                if intersected && t < closest_t {
                    closest_t = t
                    closest_id = id
                }
            } else {
                model := get_static_model(&app.renderer, instance.handle)
                tform := &app.game_state.transforms[id]
                world_space_sphere_pos := instance.pos_offset + tform.position + model.bounding_sphere.position
                s := Sphere {
                    position = world_space_sphere_pos,
                    radius = tform.scale * model.bounding_sphere.radius
                }
                t, res := intersect_ray_sphere_t(ray, s)
                if res == .OutsideHit {
                    if closest_t > t {
                        closest_t = t
                        closest_id = id
                    }
                }
            }
        }
        return
    }

    switch app.edit_verb {
        case .None: {}
        case .EditDirectionalLights: {}
        case .Select: {
            moving := .MoveSelectedEntity in app.game_state.edit_flags
            if !moving && .MouseClicked in app.input_system.state_flags {
                closest_id, closest_t := get_clicked_entity(app, false)

                old_id, exists := app.selected_entity.?
                if exists {
                    old_m := &app.game_state.static_models[old_id]
                    old_m.flags -= {.Highlighted}
                }
                if closest_t < math.INF_F32 {
                    m := &app.game_state.static_models[closest_id]
                    m.flags += {.Highlighted}
                    app.selected_entity = closest_id
                } else {
                    app.selected_entity = nil
                }
            }

            maybe_show_bounding_spheres(app)
        }
        case .AddCollision: {

        }
        case .Delete: {
            if .MouseHeld in app.input_system.state_flags {
                collision_pt, n, _, hit := do_mouse_raycast_with_normal(
                    app.game_state,
                    app.renderer,
                    app.input_system,
                )
                id, t := get_clicked_entity(app, app.dont_delete_collision)
                if t < math.INF_F32 {
                    delete_entity(&app.game_state, id)
                }

                if hit {
                    do_point_light(&app.renderer, PointLight {
                        world_position = collision_pt + 0.01 * n,
                        intensity = light_flicker(app.game_state.rng_seed, app.game_state.time),
                        color = {1.0, 1.0, 0.5},
                    })
                }
            }


            maybe_show_bounding_spheres(app)
        }
        case .PaintCoins: {
            if .MouseHeld in app.input_system.state_flags {
                collision_pt, collided_id, hit := do_mouse_raycast(
                    app.game_state,
                    app.renderer,
                    app.input_system,
                )
                if hit {
                    far_enough_away := hlsl.distance(app.last_placed_position, collision_pt) >= app.coin_paint_radius
                    if far_enough_away {
                        coin_pos := collision_pt
                        coin_pos.z += app.coin_z_offset
                        new_coin_id := new_coin(&app.game_state, coin_pos)
                        app.last_placed_position = collision_pt
                        app.game_state.parents[new_coin_id] = collided_id
                    }
                }
            }
        }
        case .PlaceEnemy: {
            if .MouseClicked in app.input_system.state_flags {
                collision_pt, _, hit := do_mouse_raycast(
                    app.game_state,
                    app.renderer,
                    app.input_system,
                )
                if hit {
                    pos := collision_pt
                    pos.z += 1.0
                    new_id := new_enemy(&app.game_state, pos, 0.6, app.new_enemy_state)
                    app.selected_entity = new_id
                }
            }
        }
        case .PlaceHoveringEnemy: {
            if .MouseClicked in app.input_system.state_flags {
                collision_pt, _, hit := do_mouse_raycast(
                    app.game_state,
                    app.renderer,
                    app.input_system,
                )
                if hit {
                    pos := collision_pt
                    pos.z += 1.0
                    new_id := new_hovering_enemy(&app.game_state, pos, 0.6)
                    app.selected_entity = new_id
                }
            }
        }
        case .EditPlayerSpawn: {
            if .MovePlayerSpawn in app.game_state.edit_flags {
                collision_pt, _, hit := do_mouse_raycast(
                    app.game_state,
                    app.renderer,
                    app.input_system,
                )
                if hit && !io.WantCaptureMouse {
                    app.game_state.level_start = collision_pt
                    if .MouseClicked in app.input_system.state_flags {
                        app.game_state.edit_flags -= {.MovePlayerSpawn}
                    }
                }
            }
        }
    }
}