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

import imgui "odin-imgui"
import vk "vendor:vulkan"
import vkw "desktop_vulkan_wrapper"

USER_CONFIG_FILENAME :: "user.cfg"

TITLE_WITHOUT_IMGUI :: "KataWARi"
TITLE_WITH_IMGUI :: "KataWARi -- Press ESC to hide developer GUI"
DEFAULT_RESOLUTION :: hlsl.uint2 {1280, 720}

MAXIMUM_FRAME_DT :: 1.0 / 30.0

SECONDS_TO_NANOSECONDS :: 1_000_000_000
MILLISECONDS_TO_NANOSECONDS :: 1_000_000

IDENTITY_MATRIX3x3 :: hlsl.float3x3 {
    1.0, 0.0, 0.0,
    0.0, 1.0, 0.0,
    0.0, 0.0, 1.0
}
IDENTITY_MATRIX4x4 :: hlsl.float4x4 {
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0,
}

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
    context.logger = log.create_console_logger(log_level)

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

@thread_local profiler: Profiler

main :: proc() {
    // Initialize app state and subsystems
    app: App
    app_init_ok := app_startup(&app)
    if !app_init_ok {
        log.error("Failed to init app struct")
        return
    }
    defer app_shutdown(&app)
    scoped_event(&profiler, "Main proc")

    // context is per-scope, so set the allocators here for the rest of main's scope
    context.allocator = app.per_scene_allocator
    context.temp_allocator = app.per_frame_allocator

    log.info("App initialization complete. Entering main loop")

    do_main_loop := true
    for do_main_loop {
        scoped_event(&profiler, "Main frame loop")

        // Time
        app.current_time = time.now()
        nanosecond_dt := time.diff(app.previous_time, app.current_time)
        last_frame_dt := f32(nanosecond_dt / 1000) / 1_000_000
        dt := min(last_frame_dt, MAXIMUM_FRAME_DT)
        scaled_dt := app.game_state.timescale * dt
        app.previous_time = app.current_time

        // @TODO: Wrap this value at some point?
        app.game_state.time += scaled_dt

        // Save user configuration every 100ms
        if app.user_config.autosave && time.diff(app.user_config.last_saved, app.current_time) >= 100_000_000 {
            scoped_event(&profiler, "Auto-save user config")
            tform := &app.game_state.transforms[app.game_state.viewport_camera_id]
            camera := &app.game_state.cameras[app.game_state.viewport_camera_id]
            following := app.game_state.viewport_camera_id in app.game_state.lookat_controllers
            app.user_config.strs[.StartLevel] = app.game_state.current_level
            update_user_cfg_camera(&app.user_config, tform.position, following, camera^)
            save_user_config(&app.user_config, USER_CONFIG_FILENAME)
            app.user_config.last_saved = app.current_time
        }

        // Load new level before any other per-frame work begins
        {
            level, ok := app.load_new_level.?
            if ok {
                builder: strings.Builder
                strings.builder_init(&builder, context.temp_allocator)
                fmt.sbprintf(&builder, "data/levels/%v", level)
                path := strings.to_string(builder)
                load_level_file(&app.vgd, &app.renderer, &app.audio_system, &app.game_state, &app.user_config, path)
                app.load_new_level = nil
            }
        }

        // Start a new Dear ImGUI frame and get an io reference
        begin_gui(&app.imgui_state)
        io := imgui.GetIO()
        io.DeltaTime = last_frame_dt
        app.renderer.uniforms.time += scaled_dt

        new_frame(&app.renderer)

        scene_editor(&app.game_state, &app.vgd, &app.renderer, &app.imgui_state, &app.user_config)

        output_verbs := poll_sdl2_events(&app.input_system)

        // Quit if user wants it
        do_main_loop = !output_verbs.bools[.Quit]

        if .PerfProfile in app.app_options && app.vgd.frame_count >= 144 * 2 {
            do_main_loop = false
        }

        // Tell Dear ImGUI about inputs
        {
            scoped_event(&profiler, "Tell Dear ImGUI about events")

            camera := &app.game_state.cameras[app.game_state.viewport_camera_id]

            if output_verbs.bools[.ToggleImgui] {
                app.imgui_state.show_gui = !app.imgui_state.show_gui
                app.user_config.flags[.ImguiEnabled] = app.imgui_state.show_gui
                if app.imgui_state.show_gui {
                    sdl2.SetWindowTitle(app.window.window, TITLE_WITH_IMGUI)
                } else {
                    sdl2.SetWindowTitle(app.window.window, TITLE_WITHOUT_IMGUI)
                }
            }

            mlook_coords, ok := output_verbs.int2s[.ToggleMouseLook]
            if ok && mlook_coords != {0, 0} {
                mlook := !(.MouseLook in camera.flags)
                // Do nothing if Dear ImGUI wants mouse input
                if !(mlook && io.WantCaptureMouse) {
                    sdl2.SetRelativeMouseMode(sdl2.bool(mlook))
                    if mlook {
                        app.saved_mouse_coords.x = i32(mlook_coords.x)
                        app.saved_mouse_coords.y = i32(mlook_coords.y)
                    } else {
                        sdl2.WarpMouseInWindow(app.window.window, app.saved_mouse_coords.x, app.saved_mouse_coords.y)
                    }
                    // The ~ is "symmetric difference" for bit_sets
                    // Basically like XOR
                    camera.flags ~= {.MouseLook}
                }
            }

            if .MouseLook not_in camera.flags {
                x, y: c.int
                sdl2.GetMouseState(&x, &y)
                imgui.IO_AddMousePosEvent(io, f32(x), f32(y))
            } else {
                sdl2.WarpMouseInWindow(app.window.window, app.saved_mouse_coords.x, app.saved_mouse_coords.y)
            }

        }

        {
            docknode := imgui.DockBuilderGetCentralNode(app.imgui_state.dockspace_id)
            app.renderer.viewport_dimensions.offset.x = cast(i32)docknode.Pos.x
            app.renderer.viewport_dimensions.offset.y = cast(i32)docknode.Pos.y
            app.renderer.viewport_dimensions.extent.width = cast(u32)docknode.Size.x
            app.renderer.viewport_dimensions.extent.height = cast(u32)docknode.Size.y

            camera := &app.game_state.cameras[app.game_state.viewport_camera_id]
            camera.aspect_ratio = docknode.Size.x / docknode.Size.y
        }

        // Update

        // Misc imgui window for testing
        @static minimum_frametime : c.int = 33
        @static move_player := false
        if app.imgui_state.show_gui && app.user_config.flags[.ShowDebugMenu] {
            if imgui.Begin("Hacking window", &app.user_config.flags[.ShowDebugMenu]) {
                scoped_event(&profiler, "Show debug menu")
                imgui.Text("Frame #%i", app.vgd.frame_count)
                imgui.Separator()

                {
                    //player := &app.game_state.character
                    tform := &app.game_state.transforms[app.game_state.player_id]
                    collision := &app.game_state.spherical_bodies[app.game_state.player_id]
                    player := &app.game_state.character_controllers[app.game_state.player_id]

                    sb: strings.Builder
                    strings.builder_init(&sb, context.temp_allocator)
                    defer strings.builder_destroy(&sb)

                    flag := .ShowPlayerHitSphere in app.game_state.debug_vis_flags
                    if imgui.Checkbox("Show player collision", &flag) {
                        app.game_state.debug_vis_flags ~= {.ShowPlayerHitSphere}
                        if flag {
                            app.game_state.debug_models[app.game_state.player_id] = DebugModelInstance {
                                handle = app.game_state.sphere_mesh,
                                scale = collision.radius,
                                color = {0.2, 0.0, 1.0, 0.5}
                            }
                        } else {
                            delete_key(&app.game_state.debug_models, app.game_state.player_id)
                        }
                    }
                    flag = .ShowPlayerActivityRadius in app.game_state.debug_vis_flags
                    if imgui.Checkbox("Show player activity radius", &flag) {
                        app.game_state.debug_vis_flags ~= {.ShowPlayerActivityRadius}
                    }
                    flag = .ShowCoinRadius in app.game_state.debug_vis_flags
                    if imgui.Checkbox("Show coin radius", &flag) {
                        app.game_state.debug_vis_flags ~= {.ShowCoinRadius}
                    }

                    gui_print_value(&sb, "Player position", tform.position)
                    gui_print_value(&sb, "Player velocity", collision.velocity)
                    gui_print_value(&sb, "Player acceleration", player.acceleration)
                    gui_print_value(&sb, "Player state", collision.state)

                    imgui.SliderFloat("Player move speed", &player.move_speed, 1.0, 50.0)
                    imgui.SliderFloat("Player sprint speed", &player.sprint_speed, 1.0, 50.0)
                    imgui.SliderFloat("Player deceleration speed", &player.deceleration_speed, 0.01, 2.0)
                    imgui.SliderFloat("Player jump speed", &player.jump_speed, 1.0, 50.0)
                    imgui.SliderFloat("Player anim speed", &player.anim_speed, 0.0, 2.0)
                    imgui.SliderFloat("Bullet travel time", &player.bullet_travel_time, 0.0, 1.0)
                    imgui.SliderFloat("Coin radius", &app.game_state.coin_collision_radius, 0.1, 1.0)
                    if imgui.Button("Reset player") {
                        output_verbs.bools[.PlayerReset] = true
                    }
                    imgui.SameLine()
                    imgui.BeginDisabled(move_player)
                    move_text : cstring = "Move player"
                    if move_player {
                        move_text = "Moving player..."
                    }
                    if imgui.Button(move_text) {
                        move_player = true
                    }
                    imgui.EndDisabled()
                }

                imgui.SliderFloat("Distortion Strength", &app.renderer.uniforms.distortion_strength, 0.0, 1.0)
                imgui.SliderFloat("Timescale", &app.game_state.timescale, 0.0, 2.0)
                imgui.SameLine()
                if imgui.Button("Reset") {
                    app.game_state.timescale = 1.0
                }

                {
                    b := .LimitCPU in app.app_options
                    if imgui.Checkbox("Enable CPU Limiter", &b) {
                        app.app_options ~= {.LimitCPU}
                    }
                }
                imgui.SameLine()
                HelpMarker(
                    "Enabling this setting forces the main thread " +
                    "to sleep for (minimum_frametime - this_frames_duration) milliseconds " +
                    "at the end of the main loop, more-or-less capping the framerate."
                )
                imgui.SliderInt("Minimum frametime", &minimum_frametime, 2, 50)

                imgui.Separator()
            }
            imgui.End()
        }

        // React to main menu bar interaction
        @static show_load_modal := false
        @static show_save_modal := false
        do_fullscreen := false
        switch gui_main_menu_bar(&app.imgui_state, &app.game_state, &app.user_config) {
            case .Exit: do_main_loop = false
            case .LoadLevel: {
                show_load_modal = true
            }
            case .SaveLevel: {
                sb: strings.Builder
                strings.builder_init(&sb, context.temp_allocator)
                path := fmt.sbprintf(&sb, "data/levels/%v.lvl", app.game_state.current_level)
                save_level_file(&app.game_state, &app.renderer, app.audio_system, path)
            }
            case .SaveLevelAs: {
                show_save_modal = true
            }
            case .ToggleAlwaysOnTop: {
                sdl2.SetWindowAlwaysOnTop(app.window.window, sdl2.bool(app.user_config.flags[.AlwaysOnTop]))
            }
            case .ToggleBorderlessFullscreen: {
                do_fullscreen = true
            }
            case .ToggleExclusiveFullscreen: {
                app.game_state.exclusive_fullscreen = !app.game_state.exclusive_fullscreen
                app.game_state.borderless_fullscreen = false
                xpos, ypos: c.int
                flags : sdl2.WindowFlags = nil
                app.window.resolution = DEFAULT_RESOLUTION
                if app.game_state.exclusive_fullscreen {
                    flags += {.FULLSCREEN}
                    app.window.resolution = app.window.display_resolution
                } else {
                    app.window.resolution = DEFAULT_RESOLUTION
                    xpos = c.int(app.user_config.ints[.WindowX])
                    ypos = c.int(app.user_config.ints[.WindowY])
                }
                io.DisplaySize.x = f32(app.window.resolution.x)
                io.DisplaySize.y = f32(app.window.resolution.y)

                sdl2.SetWindowSize(app.window.window, c.int(app.window.resolution.x), c.int(app.window.resolution.y))
                sdl2.SetWindowFullscreen(app.window.window, flags)
                sdl2.SetWindowResizable(app.window.window, !app.game_state.exclusive_fullscreen)

                app.vgd.resize_window = true
            }
            case .None: {}
        }

        if output_verbs.bools[.FullscreenHotkey] {
            do_fullscreen = true
        }

        if do_fullscreen {
            app.game_state.borderless_fullscreen = !app.game_state.borderless_fullscreen
            app.game_state.exclusive_fullscreen = false
            xpos, ypos: c.int
            if app.game_state.borderless_fullscreen {
                app.window.resolution = app.window.display_resolution
            } else {
                app.window.resolution = {u32(app.user_config.ints[.WindowWidth]), u32(app.user_config.ints[.WindowHeight])}
                xpos = c.int(app.user_config.ints[.WindowX])
                ypos = c.int(app.user_config.ints[.WindowY])
            }
            io.DisplaySize.x = f32(app.window.resolution.x)
            io.DisplaySize.y = f32(app.window.resolution.y)

            sdl2.SetWindowBordered(app.window.window, !app.game_state.borderless_fullscreen)
            sdl2.SetWindowPosition(app.window.window, xpos, ypos)
            sdl2.SetWindowSize(app.window.window, c.int(app.window.resolution.x), c.int(app.window.resolution.y))
            sdl2.SetWindowResizable(app.window.window, !app.game_state.borderless_fullscreen)

            app.vgd.resize_window = true
        }

        if show_load_modal {
            popup_text : cstring = "Level select"
            imgui.OpenPopup(popup_text)

            center := imgui.GetMainViewport().Size / 2.0
            imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
            imgui.SetNextWindowSize(imgui.GetMainViewport().Size - 200.0)
            if imgui.BeginPopupModal(popup_text, &show_load_modal, {.NoMove,.NoResize}) {
                selected_item: c.int
                list_items := make([dynamic]cstring, 0, 16, context.temp_allocator)
                if gui_list_files("./data/levels/", &list_items, &selected_item, popup_text) {
                    // Load selected level
                    app.load_new_level = strings.clone(string(list_items[selected_item]), context.allocator)
                    show_load_modal = false
                    imgui.CloseCurrentPopup()
                }
                imgui.Separator()
                if imgui.Button("Back") {
                    show_load_modal = false
                    imgui.CloseCurrentPopup()
                }
                imgui.EndPopup()
            }
        }

        if show_save_modal {
            popup_text : cstring = "Save level"
            imgui.OpenPopup(popup_text)

            center := imgui.GetMainViewport().Size / 2.0
            imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
            imgui.SetNextWindowSize(imgui.GetMainViewport().Size - 200.0)
            if imgui.BeginPopupModal(popup_text, &show_save_modal, {.NoMove,.NoResize}) {
                level_savename: string
                builder: strings.Builder
                strings.builder_init(&builder, context.temp_allocator)

                selected_item: c.int
                list_items := make([dynamic]cstring, 0, 16, context.temp_allocator)
                if gui_list_files("./data/levels/", &list_items, &selected_item, popup_text) {
                    // Save selected level
                    level_savename = fmt.sbprintf(&builder, "data/levels/%v", list_items[selected_item])
                    show_save_modal = false
                    imgui.CloseCurrentPopup()
                }
                imgui.InputText("Level savename", cstring(&app.game_state.savename_buffer[0]), len(app.game_state.savename_buffer))
                if imgui.Button("Save") {
                    s := strings.string_from_null_terminated_ptr(&app.game_state.savename_buffer[0], len(app.game_state.savename_buffer))
                    level_savename = fmt.sbprintf(&builder, "data/levels/%v", s)
                    app.game_state.savename_buffer[0] = 0
                    show_save_modal = false
                    imgui.CloseCurrentPopup()
                }

                imgui.Separator()
                if imgui.Button("Back") {
                    show_save_modal = false
                    imgui.CloseCurrentPopup()
                }

                if len(level_savename) > 0 {
                    save_level_file(&app.game_state, &app.renderer, app.audio_system, level_savename)
                }

                imgui.EndPopup()
            }
        }

        if app.imgui_state.show_gui && app.user_config.flags[.CameraConfig] {
            camera_gui(
                &app.game_state,
                app.game_state.viewport_camera_id,
                &app.input_system,
                &app.user_config,
                &app.user_config.flags[.CameraConfig]
            )
        }

        if app.imgui_state.show_gui && app.user_config.flags[.WindowConfig] {
            app.vgd.resize_window |= window_config(app.imgui_state, &app.window, app.user_config)
        }

        if app.imgui_state.show_gui && app.user_config.flags[.GraphicsSettings] {
            graphics_gui(app.vgd, &app.renderer, &app.user_config.flags[.GraphicsSettings])
        }
        if app.imgui_state.show_gui && app.user_config.flags[.AudioPanel] {
            audio_gui(&app.game_state, &app.audio_system, &app.user_config, &app.user_config.flags[.AudioPanel])
        }
        // Input remapping GUI
        if app.imgui_state.show_gui && app.user_config.flags[.InputConfig] {
            input_gui(&app.input_system, &app.user_config.flags[.InputConfig])
        }
        // Imgui Demo
        if app.imgui_state.show_gui && app.user_config.flags[.ShowImguiDemo] {
            imgui.ShowDemoWindow(&app.user_config.flags[.ShowImguiDemo])
        }

        // Handle current editor state
        // {
        //     move_positionable :: proc(
        //         game_state: ^GameState,
        //         input_system: InputSystem,
        //         viewport_dimensions: vk.Rect2D,
        //         position: ^hlsl.float3
        //     ) -> bool {
        //         collision_pt: hlsl.float3
        //         hit := false
        //         io := imgui.GetIO()
        //         if !io.WantCaptureMouse {
        //             dims : [4]f32 = {
        //                 cast(f32)viewport_dimensions.offset.x,
        //                 cast(f32)viewport_dimensions.offset.y,
        //                 cast(f32)viewport_dimensions.extent.width,
        //                 cast(f32)viewport_dimensions.extent.height,
        //             }
        //             collision_pt, hit = do_mouse_raycast(
        //                 game_state.viewport_camera,
        //                 game_state.triangle_meshes,
        //                 input_system.mouse_location,
        //                 dims
        //             )
        //             if hit {
        //                 position^ = collision_pt
        //             }

        //             if input_system.mouse_clicked {
        //                 game_state.editor_response = nil
        //             }
        //         }
        //         return hit
        //     }

        //     pick_path :: proc(
        //         modal_title: cstring,
        //         path: string,
        //         builder: ^strings.Builder,
        //         resp: ^Maybe(EditorResponse)
        //     ) -> (cstring, bool) {
        //         result: cstring
        //         ok := false

        //         imgui.OpenPopup(modal_title)
        //         center := imgui.GetMainViewport().Size / 2.0
        //         imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
        //         imgui.SetNextWindowSize(imgui.GetMainViewport().Size - 200.0)

        //         if imgui.BeginPopupModal(modal_title, nil, {.NoMove,.NoResize}) {
        //             selected_item: c.int
        //             list_items := make([dynamic]cstring, 0, 16, context.temp_allocator)
        //             if gui_list_files(path, &list_items, &selected_item, "models") {
        //                 fmt.sbprintf(builder, "%v/%v", path, list_items[selected_item])
        //                 path_cstring, _ := strings.to_cstring(builder)

        //                 result = path_cstring
        //                 ok = true
        //                 resp^ = nil
        //                 imgui.CloseCurrentPopup()
        //             }
        //             imgui.Separator()
        //             if imgui.Button("Return") {
        //                 resp^ = nil
        //                 imgui.CloseCurrentPopup()
        //             }
        //             imgui.EndPopup()
        //         }
        //         strings.builder_reset(builder)
        //         return result, ok
        //     }

        //     resp, edit_ok := game_state.editor_response.(EditorResponse)
        //     if edit_ok {
        //         builder: strings.Builder
        //         strings.builder_init(&builder, context.temp_allocator)
        //         #partial switch resp.type {
        //             case .AddTerrainPiece: {
        //                 path, ok := pick_path("Add terrain piece", "data/models", &builder, &game_state.editor_response)
        //                 if ok {
        //                     position := hlsl.float3 {}
        //                     rotation := quaternion128 {}
        //                     scale : f32 = 1.0
        //                     mmat := translation_matrix(position) * linalg.to_matrix4(rotation) * uniform_scaling_matrix(scale)
        //                     model := load_gltf_static_model(&app.vgd, &renderer, path)

        //                     positions := get_glb_positions(path)
        //                     collision := new_static_triangle_mesh(positions[:], mmat)

        //                     id := gamestate_next_id(&game_state)
        //                     game_state.triangle_meshes[id] = collision
        //                     game_state.transforms[id] = Transform {
        //                         position = position,
        //                         rotation = rotation,
        //                         scale = scale
        //                     }
        //                     game_state.static_models[id] = model

        //                     // append(&game_state.terrain_pieces, TerrainPiece {
        //                     //     collision = collision,
        //                     //     position = position,
        //                     //     rotation = rotation,
        //                     //     scale = scale,
        //                     //     model = model,
        //                     // })
        //                 }
        //             }
        //             case .AddStaticScenery: {
        //                 path, ok := pick_path("Add static scenery", "data/models", &builder, &game_state.editor_response)
        //                 if ok {
        //                     position := hlsl.float3 {}
        //                     rotation := quaternion128 {}
        //                     scale : f32 = 1.0
        //                     mmat := translation_matrix(position) * linalg.to_matrix4(rotation) * uniform_scaling_matrix(scale)
        //                     model := load_gltf_static_model(&app.vgd, &renderer, path)

        //                     append(&game_state.static_scenery, StaticScenery {
        //                         position = position,
        //                         rotation = rotation,
        //                         scale = scale,
        //                         model = model,
        //                     })
        //                 }
        //             }
        //             case .AddAnimatedScenery: {
        //                 path, ok := pick_path("Add animated scenery", "data/models", &builder, &game_state.editor_response)
        //                 if ok {
        //                     model := load_gltf_skinned_model(&app.vgd, &renderer, path, scene_allocator)
        //                     position := hlsl.float3 {}
        //                     rotation := quaternion128 {}
        //                     scale : f32 = 1.0
        //                     append(&game_state.animated_scenery, AnimatedScenery {
        //                         position = position,
        //                         rotation = rotation,
        //                         scale = scale,
        //                         model = model,
        //                         anim_speed = 1.0,
        //                     })
        //                 }
        //             }
        //             case .MoveTerrainPiece: {
        //                 position := &game_state.terrain_pieces[resp.index].position
        //                 move_positionable(
        //                     &game_state,
        //                     input_system,
        //                     renderer.viewport_dimensions,
        //                     position
        //                 )
        //             }
        //             case .MoveStaticScenery: {
        //                 position := &game_state.static_scenery[resp.index].position
        //                 move_positionable(
        //                     &game_state,
        //                     input_system,
        //                     renderer.viewport_dimensions,
        //                     position
        //                 )
        //             }
        //             case .MoveAnimatedScenery: {
        //                 position := &game_state.animated_scenery[resp.index].position
        //                 move_positionable(
        //                     &game_state,
        //                     input_system,
        //                     renderer.viewport_dimensions,
        //                     position
        //                 )
        //             }
        //             case .MoveEnemy: {
        //                 enemy := &game_state.enemies[resp.index]
        //                 if move_positionable(
        //                     &game_state,
        //                     input_system,
        //                     renderer.viewport_dimensions,
        //                     &enemy.position
        //                 ) {
        //                     e := &game_state.enemies[resp.index]
        //                     e.velocity = {}
        //                     e.position.z += 1.0
        //                     e.home_position = enemy.position
        //                 }
        //             }
        //             case .MoveCoin: {
        //                 coin := &game_state.coins[resp.index]
        //                 if move_positionable(&game_state, input_system, renderer.viewport_dimensions, &coin.position) {
        //                     coin.position.z += 1.0
        //                 }
        //             }
        //             case .MovePlayerSpawn: {
        //                 move_positionable(&game_state, input_system, renderer.viewport_dimensions, &game_state.character_start)
        //             }
        //             case: {}
        //         }
        //     }
        // }

        // Memory viewer
        when ODIN_DEBUG {
            if app.imgui_state.show_gui && app.user_config.flags[.ShowAllocatorStats] {
                if imgui.Begin("Allocator stats", &app.user_config.flags[.ShowAllocatorStats]) {
                    imgui.Text("Global allocator stats")
                    imgui.Text("Total global memory allocated: %i", app.global_track.current_memory_allocated)
                    imgui.Text("Peak global memory allocated: %i", app.global_track.peak_memory_allocated)
                    imgui.Separator()
                    imgui.Text("Per-scene allocator stats")
                    imgui.Text("Total per-scene memory allocated: %i", app.scene_track.current_memory_allocated)
                    imgui.Text("Peak per-scene memory allocated: %i", app.scene_track.peak_memory_allocated)
                    imgui.Separator()
                }
                imgui.End()
            }
        }

        game_tick(&app.game_state, &app.vgd, &app.renderer, output_verbs, &app.audio_system, scaled_dt)

        // Move player hackiness
        if move_player && !io.WantCaptureMouse {
            scoped_event(&profiler, "Move player cheat")
            tform := &app.game_state.transforms[app.game_state.player_id]
            col := &app.game_state.spherical_bodies[app.game_state.player_id]
            dims : [4]f32 = {
                cast(f32)app.renderer.viewport_dimensions.offset.x,
                cast(f32)app.renderer.viewport_dimensions.offset.y,
                cast(f32)app.renderer.viewport_dimensions.extent.width,
                cast(f32)app.renderer.viewport_dimensions.extent.height,
            }
            collision_pt, hit := do_mouse_raycast(
                app.game_state,
                app.game_state.viewport_camera_id,
                app.game_state.triangle_meshes,
                app.input_system.mouse_location,
                dims
            )
            if hit {
                tform.position = collision_pt
                tform.position.z += col.radius
            }

            if app.input_system.mouse_clicked {
                move_player = false
            }
        }

        // Camera update
        {
            scoped_event(&profiler, "Camera update")

            tform := &app.game_state.transforms[app.game_state.viewport_camera_id]
            camera := &app.game_state.cameras[app.game_state.viewport_camera_id]
            lookat_controller, is_lookat := &app.game_state.lookat_controllers[app.game_state.viewport_camera_id]
            current_view_from_world: hlsl.float4x4 
            if is_lookat {
                lookat_camera_update(&app.game_state, output_verbs, app.game_state.viewport_camera_id, dt)
                current_view_from_world = lookat_view_from_world(tform^, lookat_controller.current_focal_point)
            } else {
                freecam_update(&app.game_state, output_verbs, app.game_state.viewport_camera_id, dt)
                current_view_from_world = freecam_view_from_world(tform^, camera^)
            }

            projection_from_view := camera_projection_from_view(camera^)
            app.renderer.uniforms.clip_from_world =
                projection_from_view *
                current_view_from_world

            vfw := hlsl.float3x3(current_view_from_world)
            vfw4 := hlsl.float4x4(vfw)
            app.renderer.uniforms.clip_from_skybox = projection_from_view * vfw4;

            app.renderer.uniforms.view_position.xyz = tform.position
            app.renderer.uniforms.view_position.a = 1.0
        }

        // Draw static models
        {
            scoped_event(&profiler, "Draw static models")
            for id, model in app.game_state.static_models {
                tform := &app.game_state.transforms[id]
    
                mat := get_transform_matrix(tform^)
                mat[3][0] += model.pos_offset.x
                mat[3][1] += model.pos_offset.y
                mat[3][2] += model.pos_offset.z
                draw := StaticDraw {
                    world_from_model = mat,
                    flags = model.flags
                }
                draw_ps1_static_mesh(&app.vgd, &app.renderer, model.handle, draw)
    
                if .Glowing in model.flags {
                    // Light source
                    l := default_point_light()
                    l.world_position = tform.position
                    l.color = {0.0, 1.0, 0.0}
                    l.intensity = light_flicker(app.game_state.rng_seed, app.game_state.time)
                    do_point_light(&app.renderer, l)
                }
            }
        }

        {
            scoped_event(&profiler, "Draw skinned models")
            // Draw skinned models
            for id, model in app.game_state.skinned_models {
                tform := &app.game_state.transforms[id]
    
                mat := get_transform_matrix(tform^)
                mat[3][0] += model.pos_offset.x
                mat[3][1] += model.pos_offset.y
                mat[3][2] += model.pos_offset.z
                draw := SkinnedDraw {
                    world_from_model = mat,
                    anim_idx = model.anim_idx,
                    anim_t = model.anim_t,
                    //flags = model.flags
                }
                draw_ps1_skinned_mesh(&app.vgd, &app.renderer, model.handle, &draw)
    
                if .Glowing in model.flags {
                    // Light source
                    l := default_point_light()
                    l.world_position = tform.position
                    l.color = {0.0, 1.0, 0.0}
                    l.intensity = light_flicker(app.game_state.rng_seed, app.game_state.time)
                    do_point_light(&app.renderer, l)
                }
            }
        }

        {
            scoped_event(&profiler, "Draw debug models")
            // Draw debug models
            for id, model in app.game_state.debug_models {
                tform := &app.game_state.transforms[id]
    
                mat := get_transform_matrix(tform^, model.scale)
                mat[3][0] += model.pos_offset.x
                mat[3][1] += model.pos_offset.y
                mat[3][2] += model.pos_offset.z
                draw := DebugDraw {
                    world_from_model = mat,
                    color = model.color
                }
                draw_debug_mesh(&app.vgd, &app.renderer, app.game_state.sphere_mesh, &draw)
            }
        }

        // Window update
        {
            scoped_event(&profiler, "Window update")
            new_size, ok := output_verbs.int2s[.ResizeWindow]
            if ok {
                app.window.resolution.x = u32(new_size.x)
                app.window.resolution.y = u32(new_size.y)
                app.vgd.resize_window = true
            }

            new_pos, ok2 := output_verbs.int2s[.MoveWindow]
            if ok2 {
                app.user_config.ints[.WindowX] = i64(new_pos.x)
                app.user_config.ints[.WindowY] = i64(new_pos.y)
            }
        }

        audio_tick(&app.audio_system)

        @static window_minimized := false
        {
            value, ok := output_verbs.bools[.MinimizeWindow]
            if ok {
                window_minimized = value
                if !value {
                    app.vgd.resize_window = true
                }
            }
        }

        // Render
        if !window_minimized {
            scoped_event(&profiler, "Everything from remaking the window to presenting the swapchain")
            full_swapchain_remake :: proc(gd: ^vkw.GraphicsDevice, renderer: ^Renderer, user_config: ^UserConfiguration, window: Window) {
                scoped_event(&profiler, "full_swapchain_remake")
                io := imgui.GetIO()

                info := vkw.SwapchainInfo {
                    dimensions = {
                        uint(window.resolution.x),
                        uint(window.resolution.y)
                    },
                    present_mode = window.present_mode
                }
                if !vkw.resize_window(gd, info) {
                    log.error("Failed to resize window")
                }
                resize_framebuffers(gd, renderer, window.resolution)
                is_fullscreen := user_config.flags[.BorderlessFullscreen] || user_config.flags[.ExclusiveFullscreen]
                if !is_fullscreen {
                    user_config.ints[.WindowWidth] = i64(window.resolution.x)
                    user_config.ints[.WindowHeight] = i64(window.resolution.y)
                }
                io.DisplaySize.x = f32(window.resolution.x)
                io.DisplaySize.y = f32(window.resolution.y)
            }

            // Resize swapchain if necessary
            if app.vgd.resize_window {
                full_swapchain_remake(&app.vgd, &app.renderer, &app.user_config, app.window)
                app.vgd.resize_window = false
            }

            // Sync point where we wait if there are already 2 frames in the gfx queue
            {
                scoped_event(&profiler, "CPU wait on GPU")
                vkw.wait_frames_in_flight(&app.vgd, app.renderer.gfx_timeline)
            }

            gfx_cb_idx := vkw.begin_gfx_command_buffer(&app.vgd)

            // Increment timeline semaphore upon command buffer completion
            vkw.add_signal_op(&app.vgd, &app.renderer.gfx_sync, app.renderer.gfx_timeline, app.vgd.frame_count + 1)

            // Acquire swapchain image and try to handle result
            swapchain_image_idx, acquire_result := vkw.acquire_swapchain_image(&app.vgd, gfx_cb_idx, &app.renderer.gfx_sync)
            #partial switch acquire_result {
                case .SUCCESS: {}
                case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR: {
                    full_swapchain_remake(&app.vgd, &app.renderer, &app.user_config, app.window)
                }
                case: {
                    log.errorf("Swapchain image acquire failed: %v", acquire_result)
                }
            }

            framebuffer := swapchain_framebuffer(&app.vgd, swapchain_image_idx, app.window.resolution)

            // Main render call
            render_scene(
                &app.vgd,
                gfx_cb_idx,
                &app.renderer,
                &framebuffer
            )

            // Draw Dear Imgui
            framebuffer.color_load_op = .LOAD
            render_imgui(&app.vgd, gfx_cb_idx, &app.imgui_state, &framebuffer)

            // Submit gfx command buffer and present swapchain image
            {
                scoped_event(&profiler, "Submit to gfx queue and present")
                present_res := vkw.submit_gfx_and_present(&app.vgd, gfx_cb_idx, &app.renderer.gfx_sync, &swapchain_image_idx)
                if present_res == .SUBOPTIMAL_KHR || present_res == .ERROR_OUT_OF_DATE_KHR {
                    full_swapchain_remake(&app.vgd, &app.renderer, &app.user_config, app.window)
                }
            }
        } else {
            gui_cancel_frame(&app.imgui_state)
        }

        // End-of-frame cleanup
        {
            scoped_event(&profiler, "End-of-frame cleanup")
            // CLear temp allocator for next frame
            when ODIN_DEBUG {
                if app.vgd.frame_count % 100 == 0 {
                    //log.infof("%v bytes of temp allocator used on frame %v", temp_track.current_memory_allocated, app.vgd.frame_count)
                }
            }
            free_all(context.temp_allocator)

            // Clear sync info for next frame
            vkw.clear_sync_info(&app.renderer.gfx_sync)
            vkw.clear_sync_info(&app.renderer.compute_sync)
        }

        // CPU limiter
        if .LimitCPU in app.app_options {
            scoped_event(&profiler, "CPU Limiter")
            min_time := time.time_add(
                app.current_time,
                time.Duration(MILLISECONDS_TO_NANOSECONDS * minimum_frametime)
            )
            sleep_duration := time.diff(time.now(), min_time)
            time.sleep(sleep_duration)
        }
    }

    vkw.device_wait_idle(&app.vgd)
    log.info("Returning from main()")
}
