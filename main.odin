package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/linalg/hlsl"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import "vendor:cgltf"
import "vendor:sdl2"

import imgui "odin-imgui"
import vk "vendor:vulkan"
import vkw "desktop_vulkan_wrapper"
import hm "desktop_vulkan_wrapper/handlemap"

USER_CONFIG_FILENAME :: "user.cfg"
TITLE_WITHOUT_IMGUI :: "KataWARi"
TITLE_WITH_IMGUI :: "KataWARi -- Press ESC to hide developer GUI"
DEFAULT_RESOLUTION :: hlsl.uint2 {1280, 720}

MAXIMUM_FRAME_DT :: 1.0 / 30.0

SCENE_ARENA_SZIE :: 16 * 1024 * 1024         // Memory pool for per-scene allocations
TEMP_ARENA_SIZE :: 64 * 1024            // Guessing 64KB necessary size for per-frame allocations

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

main :: proc() {
    // Set up global allocator
    global_allocator := runtime.heap_allocator()
    when ODIN_DEBUG {
        // Set up the tracking allocator if this is a debug build
        global_track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&global_track, global_allocator)
        global_allocator = mem.tracking_allocator(&global_track)

        defer {
            if len(global_track.allocation_map) > 0 {
                fmt.eprintf("=== %v allocations not freed from global allocator: ===\n", len(global_track.allocation_map))
                for _, entry in global_track.allocation_map {
                    fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
                }
            }
            if len(global_track.bad_free_array) > 0 {
                fmt.eprintf("=== %v incorrect frees from global allocator: ===\n", len(global_track.bad_free_array))
                for entry in global_track.bad_free_array {
                    fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
                }
            }
            mem.tracking_allocator_destroy(&global_track)
        }
    }
    context.allocator = global_allocator

    // Parse command-line arguments
    log_level := log.Level.Info
    {
        context.logger = log.create_console_logger(log_level)
        argc := len(os.args)
        for arg, i in os.args {
            if arg == "--log-level" || arg == "-l" {
                if i + 1 < argc {
                    switch os.args[i + 1] {
                        case "DEBUG": log_level = .Debug
                        case "INFO": log_level = .Info
                        case "WARNING": log_level = .Warning
                        case "ERROR": log_level = .Error
                        case "FATAL": log_level = .Fatal
                        case: log.warnf(
                            "Unrecognized --log-level: %v. Using default (%v)",
                            os.args[i + 1],
                            log_level,
                        )
                    }
                }
            }
        }
        log.destroy_console_logger(context.logger)
    }

    // Set up logger
    context.logger = log.create_console_logger(log_level)
    when ODIN_DEBUG do defer log.destroy_console_logger(context.logger)
    log.info("Initiating swag mode...")

    // Set up per-scene allocator
    scene_allocator: mem.Allocator
    scene_backing_memory: []byte
    {
        per_frame_arena: mem.Arena
        err: mem.Allocator_Error
        scene_backing_memory, err = mem.alloc_bytes(SCENE_ARENA_SZIE)
        if err != nil {
            log.error("Error allocating scene allocator backing buffer.")
        }

        mem.arena_init(&per_frame_arena, scene_backing_memory)
        scene_allocator = mem.arena_allocator(&per_frame_arena)

    }
    defer mem.free_bytes(scene_backing_memory)
    when ODIN_DEBUG {
        // Set up the tracking allocator if this is a debug build
        scene_track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&scene_track, scene_allocator)
        scene_allocator = mem.tracking_allocator(&scene_track)

        defer {
            if len(scene_track.allocation_map) > 0 {
                fmt.eprintf("=== %v allocations not freed from scene allocator: ===\n", len(scene_track.allocation_map))
                for _, entry in scene_track.allocation_map {
                    fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
                }
            }
            if len(scene_track.bad_free_array) > 0 {
                fmt.eprintf("=== %v incorrect frees from scene allocator: ===\n", len(scene_track.bad_free_array))
                for entry in scene_track.bad_free_array {
                    fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
                }
            }
            mem.tracking_allocator_destroy(&scene_track)
        }
    }
    defer free_all(scene_allocator)

    // Set up per-frame temp allocator
    temp_backing_memory: []byte
    {
        per_frame_arena: mem.Arena
        err: mem.Allocator_Error
        temp_backing_memory, err = mem.alloc_bytes(TEMP_ARENA_SIZE)
        if err != nil {
            log.error("Error allocating temporary allocator backing buffer.")
        }

        mem.arena_init(&per_frame_arena, temp_backing_memory)
        context.temp_allocator = mem.arena_allocator(&per_frame_arena)
    }
    defer mem.free_bytes(temp_backing_memory)



    // Load user configuration
    user_config, config_ok := load_user_config(USER_CONFIG_FILENAME)
    if !config_ok do log.error("Failed to load user config.")
    defer delete_user_config(&user_config, context.allocator)



    // Initialize SDL2
    sdl2.Init({.AUDIO, .EVENTS, .GAMECONTROLLER, .VIDEO})
    when ODIN_DEBUG do defer sdl2.Quit()
    log.info("Initialized SDL2")

    // Use SDL2 to dynamically link against the Vulkan loader
    // This allows sdl2.Vulkan_GetVkGetInstanceProcAddr() to return a real address
    if sdl2.Vulkan_LoadLibrary(nil) != 0 {
        s := sdl2.GetErrorString()
        log.fatalf("Failed to link Vulkan loader: %v", s)
        return
    }



    // Initialize graphics device
    init_params := vkw.Init_Parameters {
        app_name = "Game7",
        frames_in_flight = FRAMES_IN_FLIGHT,
        features = {.Window,.Raytracing},
        //features = {.Window},
        vk_get_instance_proc_addr = sdl2.Vulkan_GetVkGetInstanceProcAddr(),
    }
    vgd, res := vkw.init_vulkan(init_params)
    if res != .SUCCESS {
        log.errorf("Failed to initialize Vulkan : %v", res)
        return
    }
    defer vkw.quit_vulkan(&vgd)

    // Make window
    app_window: Window
    
    // Determine window resolution
    {
        desktop_display_mode: sdl2.DisplayMode
        if sdl2.GetDesktopDisplayMode(0, &desktop_display_mode) != 0 {
            log.error("Error getting desktop display mode.")
        }
        app_window.display_resolution = hlsl.uint2 {
            u32(desktop_display_mode.w),
            u32(desktop_display_mode.h),
        }
        app_window.resolution = DEFAULT_RESOLUTION
        if user_config.flags[.ExclusiveFullscreen] || user_config.flags[.BorderlessFullscreen] do app_window.resolution = app_window.display_resolution
        if .WindowWidth in user_config.ints && .WindowHeight in user_config.ints {
            x := user_config.ints[.WindowWidth]
            y := user_config.ints[.WindowHeight]
            app_window.resolution = {u32(x), u32(y)}
        }
        app_window.present_mode = .FIFO
    }

    // Determine SDL window flags
    app_window.flags = {.VULKAN,.RESIZABLE}
    if user_config.flags[.ExclusiveFullscreen] {
        app_window.flags += {.FULLSCREEN}
    } else if user_config.flags[.BorderlessFullscreen] {
        app_window.flags += {.BORDERLESS}
    }

    // Determine SDL window position
    app_window.position.x = sdl2.WINDOWPOS_CENTERED
    app_window.position.y = sdl2.WINDOWPOS_CENTERED
    if .WindowX in user_config.ints && .WindowY in user_config.ints {
        app_window.position.x = i32(user_config.ints[.WindowX])
        app_window.position.y = i32(user_config.ints[.WindowY])
    } else {
        user_config.ints[.WindowX] = i64(sdl2.WINDOWPOS_CENTERED)
        user_config.ints[.WindowY] = i64(sdl2.WINDOWPOS_CENTERED)
    }

    app_window.window = sdl2.CreateWindow(
        TITLE_WITHOUT_IMGUI,
        app_window.position.x,
        app_window.position.y,
        i32(app_window.resolution.x),
        i32(app_window.resolution.y),
        app_window.flags
    )
    when ODIN_DEBUG do defer sdl2.DestroyWindow(app_window.window)
    sdl2.SetWindowAlwaysOnTop(app_window.window, sdl2.bool(user_config.flags[.AlwaysOnTop]))

    // Initialize the state required for rendering to the window
    if !vkw.init_sdl2_window(&vgd, app_window.window) {
        e := sdl2.GetError()
        log.fatalf("Couldn't init SDL2 surface: %v", e)
        return
    }

    // Now that we're done with global allocations, switch context.allocator to scene_allocator
    context.allocator = scene_allocator

    // Initialize the renderer
    renderer := init_renderer(&vgd, app_window.resolution)
    when ODIN_DEBUG do defer delete_renderer(&vgd, &renderer)
    if !renderer.do_raytracing {
        log.warn("Raytracing features are not supported by your GPU.")
    }

    //Dear ImGUI init
    imgui_state := imgui_init(&vgd, user_config, app_window.resolution)
    when ODIN_DEBUG do defer gui_cleanup(&vgd, &imgui_state)
    if imgui_state.show_gui {
        sdl2.SetWindowTitle(app_window.window, TITLE_WITH_IMGUI)
    }

    // Init audio system
    audio_system: AudioSystem
    init_audio_system(&audio_system, user_config, global_allocator, scene_allocator)
    when ODIN_DEBUG do defer destroy_audio_system(&audio_system)
    toggle_device_playback(&audio_system, true)

    // Main app structure storing the game's overall state
    game_state := init_gamestate(&vgd, &renderer, &audio_system, &user_config, global_allocator)

    {
        start_level := "test02"
        s, ok := user_config.strs[.StartLevel]
        if ok {
            start_level = s
        }
        sb: strings.Builder
        strings.builder_init(&sb, context.temp_allocator)
        start_path := fmt.sbprintf(&sb, "data/levels/%v.lvl", start_level)
        load_level_file(&vgd, &renderer, &audio_system, &game_state, &user_config, start_path, global_allocator)
    }

    // @TODO: Keymappings need to be a part of GameState
    freecam_key_mappings := make(map[sdl2.Scancode]VerbType, allocator = global_allocator)
    defer delete(freecam_key_mappings)
    character_key_mappings := make(map[sdl2.Scancode]VerbType, allocator = global_allocator)
    defer delete(character_key_mappings)
    {
        freecam_key_mappings[.ESCAPE] = .ToggleImgui
        freecam_key_mappings[.W] = .TranslateFreecamForward
        freecam_key_mappings[.S] = .TranslateFreecamBack
        freecam_key_mappings[.A] = .TranslateFreecamLeft
        freecam_key_mappings[.D] = .TranslateFreecamRight
        freecam_key_mappings[.Q] = .TranslateFreecamDown
        freecam_key_mappings[.E] = .TranslateFreecamUp
        freecam_key_mappings[.LSHIFT] = .Sprint
        freecam_key_mappings[.LCTRL] = .Crawl
        freecam_key_mappings[.SPACE] = .PlayerJump
        freecam_key_mappings[.BACKSLASH] = .FrameAdvance
        freecam_key_mappings[.PAUSE] = .Resume
        freecam_key_mappings[.F] = .FullscreenHotkey
        character_key_mappings[.R] = .PlayerReset

        character_key_mappings[.ESCAPE] = .ToggleImgui
        character_key_mappings[.W] = .PlayerTranslateForward
        character_key_mappings[.S] = .PlayerTranslateBack
        character_key_mappings[.A] = .PlayerTranslateLeft
        character_key_mappings[.D] = .PlayerTranslateRight
        character_key_mappings[.LSHIFT] = .Sprint
        character_key_mappings[.LCTRL] = .Crawl
        character_key_mappings[.SPACE] = .PlayerJump
        character_key_mappings[.BACKSLASH] = .FrameAdvance
        character_key_mappings[.PAUSE] = .Resume
        character_key_mappings[.F] = .FullscreenHotkey
        character_key_mappings[.R] = .PlayerReset
    }

    // Init input system
    context.allocator = global_allocator
    input_system: InputSystem
    defer destroy_input_system(&input_system)
    if .Follow in game_state.viewport_camera.control_flags {
        input_system = init_input_system(&character_key_mappings)
    } else {
        input_system = init_input_system(&freecam_key_mappings)
    }
    context.allocator = scene_allocator

    // Setup may have used temp allocation, 
    // so clear out temp memory before first frame processing
    //free_all(context.temp_allocator)

    current_time := time.now()          // Time in nanoseconds since UNIX epoch
    previous_time := time.time_add(current_time, time.Duration(-1_000_000)) //current_time - time.Time{_nsec = 1}
    do_limit_cpu := false
    saved_mouse_coords := hlsl.int2 {0, 0}
    load_new_level: Maybe(string)

    log.info("App initialization complete. Entering main loop")

    do_main_loop := true
    for do_main_loop {
        // Time
        current_time = time.now()
        nanosecond_dt := time.diff(previous_time, current_time)
        last_frame_dt := f32(nanosecond_dt / 1000) / 1_000_000
        dt := min(last_frame_dt, MAXIMUM_FRAME_DT)
        previous_time = current_time

        // @TODO: Wrap this value at some point?
        game_state.time += dt * game_state.timescale

        // Save user configuration every 100ms
        if user_config.autosave && time.diff(user_config.last_saved, current_time) >= 1_000_000 {
            user_config.strs[.StartLevel] = game_state.current_level
            update_user_cfg_camera(&user_config, &game_state.viewport_camera)
            save_user_config(&user_config, USER_CONFIG_FILENAME)
            user_config.last_saved = current_time
        }

        // Load new level before any other per-frame work begins
        {
            level, ok := load_new_level.?
            if ok {
                builder: strings.Builder
                strings.builder_init(&builder, context.temp_allocator)
                fmt.sbprintf(&builder, "data/levels/%v", level)
                path := strings.to_string(builder)
                load_level_file(&vgd, &renderer, &audio_system, &game_state, &user_config, path, global_allocator)
                load_new_level = nil
            }
        }

        // Start a new Dear ImGUI frame and get an io reference
        begin_gui(&imgui_state)
        io := imgui.GetIO()
        io.DeltaTime = last_frame_dt
        renderer.cpu_uniforms.time = f32(vgd.frame_count) / 144

        new_frame(&renderer)

        scene_editor(&game_state, &vgd, &renderer, &imgui_state, &user_config)

        output_verbs := poll_sdl2_events(&input_system)

        // Quit if user wants it
        do_main_loop = !output_verbs.bools[.Quit]

        // Tell Dear ImGUI about inputs
        {
            if output_verbs.bools[.ToggleImgui] {
                imgui_state.show_gui = !imgui_state.show_gui
                user_config.flags[.ImguiEnabled] = imgui_state.show_gui
                if imgui_state.show_gui {
                    sdl2.SetWindowTitle(app_window.window, TITLE_WITH_IMGUI)
                } else {
                    sdl2.SetWindowTitle(app_window.window, TITLE_WITHOUT_IMGUI)
                }
            }

            mlook_coords, ok := output_verbs.int2s[.ToggleMouseLook]
            if ok && mlook_coords != {0, 0} {
                mlook := !(.MouseLook in game_state.viewport_camera.control_flags)
                // Do nothing if Dear ImGUI wants mouse input
                if !(mlook && io.WantCaptureMouse) {
                    sdl2.SetRelativeMouseMode(sdl2.bool(mlook))
                    if mlook {
                        saved_mouse_coords.x = i32(mlook_coords.x)
                        saved_mouse_coords.y = i32(mlook_coords.y)
                    } else {
                        sdl2.WarpMouseInWindow(app_window.window, saved_mouse_coords.x, saved_mouse_coords.y)
                    }
                    // The ~ is "symmetric difference" for bit_sets
                    // Basically like XOR
                    game_state.viewport_camera.control_flags ~= {.MouseLook}
                }
            }

            if .MouseLook not_in game_state.viewport_camera.control_flags {
                x, y: c.int
                sdl2.GetMouseState(&x, &y)
                imgui.IO_AddMousePosEvent(io, f32(x), f32(y))
            } else {
                sdl2.WarpMouseInWindow(app_window.window, saved_mouse_coords.x, saved_mouse_coords.y)
            }

        }

        // Update

        docknode := imgui.DockBuilderGetCentralNode(imgui_state.dockspace_id)
        renderer.viewport_dimensions.offset.x = cast(i32)docknode.Pos.x
        renderer.viewport_dimensions.offset.y = cast(i32)docknode.Pos.y
        renderer.viewport_dimensions.extent.width = cast(u32)docknode.Size.x
        renderer.viewport_dimensions.extent.height = cast(u32)docknode.Size.y
        game_state.viewport_camera.aspect_ratio = docknode.Size.x / docknode.Size.y

        @static cpu_limiter_ms : c.int = 100

        // Misc imgui window for testing
        @static rotate_sun := false
        @static move_player := false
        @static last_raycast_hit: hlsl.float3
        want_refire_raycast := false
        if imgui_state.show_gui && user_config.flags[.ShowDebugMenu] {
            if imgui.Begin("Hacking window", &user_config.flags[.ShowDebugMenu]) {
                imgui.Text("Frame #%i", vgd.frame_count)
                imgui.Separator()

                {
                    using game_state.character

                    sb: strings.Builder
                    strings.builder_init(&sb, context.temp_allocator)
                    defer strings.builder_destroy(&sb)

                    flag := .ShowPlayerHitSphere in game_state.debug_vis_flags
                    if imgui.Checkbox("Show player collision", &flag) do game_state.debug_vis_flags ~= {.ShowPlayerHitSphere}
                    flag = .ShowPlayerActivityRadius in game_state.debug_vis_flags
                    if imgui.Checkbox("Show player activity radius", &flag) do game_state.debug_vis_flags ~= {.ShowPlayerActivityRadius}
                    flag = .ShowCoinRadius in game_state.debug_vis_flags
                    if imgui.Checkbox("Show coin radius", &flag) do game_state.debug_vis_flags ~= {.ShowCoinRadius}
                    imgui.Text("Player collider position: (%f, %f, %f)", collision.position.x, collision.position.y, collision.position.z)
                    imgui.Text("Player collider velocity: (%f, %f, %f)", collision.velocity.x, collision.velocity.y, collision.velocity.z)
                    imgui.Text("Player collider acceleration: (%f, %f, %f)", acceleration.x, acceleration.y, acceleration.z)
                    fmt.sbprintf(&sb, "Player state: %v", collision.state)
                    state_str, _ := strings.to_cstring(&sb)
                    strings.builder_reset(&sb)
                    imgui.Text(state_str)
                    imgui.SliderFloat("Player move speed", &move_speed, 1.0, 50.0)
                    imgui.SliderFloat("Player sprint speed", &sprint_speed, 1.0, 50.0)
                    imgui.SliderFloat("Player deceleration speed", &deceleration_speed, 0.01, 2.0)
                    imgui.SliderFloat("Player jump speed", &jump_speed, 1.0, 50.0)
                    imgui.SliderFloat("Player anim speed", &anim_speed, 0.0, 2.0)
                    imgui.SliderFloat("Bullet travel time", &game_state.character.bullet_travel_time, 0.0, 1.0)
                    imgui.SliderFloat("Coin radius", &game_state.coin_collision_radius, 0.1, 1.0)
                    if imgui.Button("Reset player") {
                        output_verbs.bools[.PlayerReset] = true
                    }
                    imgui.SameLine()
                    imgui.BeginDisabled(move_player)
                    move_text : cstring = "Move player"
                    if move_player do move_text = "Moving player..."
                    if imgui.Button(move_text) {
                        move_player = true
                    }
                    imgui.EndDisabled()
                    imgui.Text("Last raycast hit: (%f, %f, %f)", last_raycast_hit.x, last_raycast_hit.y, last_raycast_hit.z)
                    if imgui.Button("Refire last raycast") {
                        want_refire_raycast = true
                    }
                    imgui.Separator()
                }

                imgui.Checkbox("Rotate sun", &rotate_sun)

                imgui.SliderFloat("Distortion Strength", &renderer.cpu_uniforms.distortion_strength, 0.0, 1.0)
                imgui.SliderFloat("Timescale", &game_state.timescale, 0.0, 2.0)
                imgui.SameLine()
                if imgui.Button("Reset") do game_state.timescale = 1.0

                imgui.Checkbox("Enable CPU Limiter", &do_limit_cpu)
                imgui.SameLine()
                HelpMarker(
                    "Enabling this setting forces the main thread " +
                    "to sleep for 100 milliseconds at the end of the main loop, " +
                    "effectively capping the framerate to 10 FPS"
                )
                imgui.SliderInt("CPU Limiter milliseconds", &cpu_limiter_ms, 10, 1000)

                imgui.Separator()
                {
                    b := bool(renderer.cpu_uniforms.triangle_vis)
                    if imgui.Checkbox("Triangle vis", &b) do renderer.cpu_uniforms.triangle_vis = !renderer.cpu_uniforms.triangle_vis
                }
                imgui.Separator()
            }
            imgui.End()
        }

        // React to main menu bar interaction
        @static show_load_modal := false
        @static show_save_modal := false
        switch gui_main_menu_bar(&imgui_state, &game_state, &user_config) {
            case .Exit: do_main_loop = false
            case .LoadLevel: {
                show_load_modal = true
            }
            case .SaveLevel: {
                sb: strings.Builder
                strings.builder_init(&sb, context.temp_allocator)
                path := fmt.sbprintf(&sb, "data/levels/%v.lvl", game_state.current_level)
                write_level_file(&game_state, &renderer, audio_system, path)
            }
            case .SaveLevelAs: {
                show_save_modal = true
            }
            case .ToggleAlwaysOnTop: {
                sdl2.SetWindowAlwaysOnTop(app_window.window, sdl2.bool(user_config.flags[.AlwaysOnTop]))
            }
            case .ToggleBorderlessFullscreen: {
                game_state.borderless_fullscreen = !game_state.borderless_fullscreen
                game_state.exclusive_fullscreen = false
                xpos, ypos: c.int
                if game_state.borderless_fullscreen {
                    app_window.resolution = app_window.display_resolution
                } else {
                    app_window.resolution = DEFAULT_RESOLUTION
                    xpos = c.int(user_config.ints[.WindowX])
                    ypos = c.int(user_config.ints[.WindowY])
                }
                io.DisplaySize.x = f32(app_window.resolution.x)
                io.DisplaySize.y = f32(app_window.resolution.y)
                user_config.ints[.WindowX] = i64(xpos)
                user_config.ints[.WindowY] = i64(ypos)

                sdl2.SetWindowBordered(app_window.window, !game_state.borderless_fullscreen)
                sdl2.SetWindowPosition(app_window.window, xpos, ypos)
                sdl2.SetWindowSize(app_window.window, c.int(app_window.resolution.x), c.int(app_window.resolution.y))
                sdl2.SetWindowResizable(app_window.window, !game_state.borderless_fullscreen)

                vgd.resize_window = true
            }
            case .ToggleExclusiveFullscreen: {
                game_state.exclusive_fullscreen = !game_state.exclusive_fullscreen
                game_state.borderless_fullscreen = false
                xpos, ypos: c.int
                flags : sdl2.WindowFlags = nil
                app_window.resolution = DEFAULT_RESOLUTION
                if game_state.exclusive_fullscreen {
                    flags += {.FULLSCREEN}
                    app_window.resolution = app_window.display_resolution
                } else {
                    app_window.resolution = DEFAULT_RESOLUTION
                    xpos = c.int(user_config.ints[.WindowX])
                    ypos = c.int(user_config.ints[.WindowY])
                }
                io.DisplaySize.x = f32(app_window.resolution.x)
                io.DisplaySize.y = f32(app_window.resolution.y)

                sdl2.SetWindowSize(app_window.window, c.int(app_window.resolution.x), c.int(app_window.resolution.y))
                sdl2.SetWindowFullscreen(app_window.window, flags)
                sdl2.SetWindowResizable(app_window.window, !game_state.exclusive_fullscreen)

                vgd.resize_window = true
            }
            case .None: {}
        }

        if output_verbs.bools[.FullscreenHotkey] {
            game_state.borderless_fullscreen = !game_state.borderless_fullscreen
            game_state.exclusive_fullscreen = false
            xpos, ypos: c.int
            if game_state.borderless_fullscreen {
                app_window.resolution = app_window.display_resolution
            } else {
                app_window.resolution = {u32(user_config.ints[.WindowWidth]), u32(user_config.ints[.WindowHeight])}
                xpos = c.int(user_config.ints[.WindowX])
                ypos = c.int(user_config.ints[.WindowY])
            }
            io.DisplaySize.x = f32(app_window.resolution.x)
            io.DisplaySize.y = f32(app_window.resolution.y)

            sdl2.SetWindowBordered(app_window.window, !game_state.borderless_fullscreen)
            sdl2.SetWindowPosition(app_window.window, xpos, ypos)
            sdl2.SetWindowSize(app_window.window, c.int(app_window.resolution.x), c.int(app_window.resolution.y))
            sdl2.SetWindowResizable(app_window.window, !game_state.borderless_fullscreen)

            vgd.resize_window = true
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
                    load_new_level = strings.clone(string(list_items[selected_item]), context.allocator)
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
                imgui.InputText("Level savename", cstring(&game_state.savename_buffer[0]), len(game_state.savename_buffer))
                if imgui.Button("Save") {
                    s := strings.string_from_null_terminated_ptr(&game_state.savename_buffer[0], len(game_state.savename_buffer))
                    level_savename = fmt.sbprintf(&builder, "data/levels/%v", s)
                    game_state.savename_buffer[0] = 0
                    show_save_modal = false
                    imgui.CloseCurrentPopup()
                }
                
                imgui.Separator()
                if imgui.Button("Back") {
                    show_save_modal = false
                    imgui.CloseCurrentPopup()
                }

                if len(level_savename) > 0 {
                    write_level_file(&game_state, &renderer, audio_system, level_savename)
                }

                imgui.EndPopup()
            }
        }

        if imgui_state.show_gui && user_config.flags[.CameraConfig] {
            res, ok := camera_gui(
                &game_state,
                &game_state.viewport_camera,
                &input_system,
                &user_config,
                &user_config.flags[.CameraConfig]
            )
            if ok {
                switch res {
                    case .ToggleFollowCam: {
                        if .Follow in game_state.viewport_camera.control_flags {
                            replace_keybindings(&input_system, &character_key_mappings)
                        } else {
                            replace_keybindings(&input_system, &freecam_key_mappings)
                        }
                    }
                }    
            }
        }

        if imgui_state.show_gui && user_config.flags[.WindowConfig] {
            vgd.resize_window |= window_config(imgui_state, &app_window, user_config)
        }

        if imgui_state.show_gui && user_config.flags[.GraphicsSettings] do graphics_gui(&renderer, &imgui_state, &user_config.flags[.GraphicsSettings])

        if imgui_state.show_gui && user_config.flags[.AudioPanel] do audio_gui(&game_state, &audio_system, &user_config, &user_config.flags[.AudioPanel])

        // Input remapping GUI
        if imgui_state.show_gui && user_config.flags[.InputConfig] do input_gui(&input_system, &user_config.flags[.InputConfig])

        // Imgui Demo
        if imgui_state.show_gui && user_config.flags[.ShowImguiDemo] do imgui.ShowDemoWindow(&user_config.flags[.ShowImguiDemo])

        // Handle current editor state
        {
            move_positionable :: proc(
                game_state: ^GameState,
                input_system: InputSystem,
                viewport_dimensions: vk.Rect2D,
                position: ^hlsl.float3
            ) -> bool {
                collision_pt: hlsl.float3
                hit := false
                io := imgui.GetIO()
                if !io.WantCaptureMouse {
                    dims : [4]f32 = {
                        cast(f32)viewport_dimensions.offset.x,
                        cast(f32)viewport_dimensions.offset.y,
                        cast(f32)viewport_dimensions.extent.width,
                        cast(f32)viewport_dimensions.extent.height,
                    }
                    collision_pt, hit = do_mouse_raycast(
                        game_state.viewport_camera,
                        game_state.terrain_pieces[:],
                        input_system.mouse_location,
                        dims
                    )
                    if hit {
                        position^ = collision_pt
                    }

                    if input_system.mouse_clicked {
                        game_state.editor_response = nil
                    }
                }
                return hit
            }

            pick_path :: proc(
                modal_title: cstring,
                path: string,
                builder: ^strings.Builder,
                resp: ^Maybe(EditorResponse)
            ) -> (cstring, bool) {
                result: cstring
                ok := false

                imgui.OpenPopup(modal_title)
                center := imgui.GetMainViewport().Size / 2.0
                imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
                imgui.SetNextWindowSize(imgui.GetMainViewport().Size - 200.0)

                if imgui.BeginPopupModal(modal_title, nil, {.NoMove,.NoResize}) {
                    selected_item: c.int
                    list_items := make([dynamic]cstring, 0, 16, context.temp_allocator)
                    if gui_list_files(path, &list_items, &selected_item, "models") {
                        fmt.sbprintf(builder, "%v/%v", path, list_items[selected_item])
                        path_cstring, _ := strings.to_cstring(builder)

                        result = path_cstring
                        ok = true
                        resp^ = nil
                        imgui.CloseCurrentPopup()
                    }
                    imgui.Separator()
                    if imgui.Button("Return") {
                        resp^ = nil
                        imgui.CloseCurrentPopup()
                    }
                    imgui.EndPopup()
                }
                strings.builder_reset(builder)
                return result, ok
            }

            resp, edit_ok := game_state.editor_response.(EditorResponse)
            if edit_ok {
                builder: strings.Builder
                strings.builder_init(&builder, context.temp_allocator)
                #partial switch resp.type {
                    case .AddTerrainPiece: {
                        path, ok := pick_path("Add terrain piece", "data/models", &builder, &game_state.editor_response)
                        if ok {
                            position := hlsl.float3 {}
                            rotation := quaternion128 {}
                            scale : f32 = 1.0
                            mmat := translation_matrix(position) * linalg.to_matrix4(rotation) * uniform_scaling_matrix(scale)
                            model := load_gltf_static_model(&vgd, &renderer, path)
                            
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
                    }
                    case .AddStaticScenery: {
                        path, ok := pick_path("Add static scenery", "data/models", &builder, &game_state.editor_response)
                        if ok {
                            position := hlsl.float3 {}
                            rotation := quaternion128 {}
                            scale : f32 = 1.0
                            mmat := translation_matrix(position) * linalg.to_matrix4(rotation) * uniform_scaling_matrix(scale)
                            model := load_gltf_static_model(&vgd, &renderer, path)
                            
                            append(&game_state.static_scenery, StaticScenery {
                                position = position,
                                rotation = rotation,
                                scale = scale,
                                model = model,
                            })
                        }
                    }
                    case .AddAnimatedScenery: {
                        path, ok := pick_path("Add animated scenery", "data/models", &builder, &game_state.editor_response)
                        if ok {
                            model := load_gltf_skinned_model(&vgd, &renderer, path)
                            position := hlsl.float3 {}
                            rotation := quaternion128 {}
                            scale : f32 = 1.0
                            append(&game_state.animated_scenery, AnimatedScenery {
                                position = position,
                                rotation = rotation,
                                scale = scale,
                                model = model,
                                anim_speed = 1.0,
                            })
                        }
                    }
                    case .MoveTerrainPiece: {
                        position := &game_state.terrain_pieces[resp.index].position
                        move_positionable(
                            &game_state,
                            input_system,
                            renderer.viewport_dimensions,
                            position
                        )
                    }
                    case .MoveStaticScenery: {
                        position := &game_state.static_scenery[resp.index].position
                        move_positionable(
                            &game_state,
                            input_system,
                            renderer.viewport_dimensions,
                            position
                        )
                    }
                    case .MoveAnimatedScenery: {
                        position := &game_state.animated_scenery[resp.index].position
                        move_positionable(
                            &game_state,
                            input_system,
                            renderer.viewport_dimensions,
                            position
                        )
                    }
                    case .MoveEnemy: {
                        enemy := &game_state.enemies[resp.index]
                        if move_positionable(
                            &game_state,
                            input_system,
                            renderer.viewport_dimensions,
                            &enemy.position
                        ) {
                            e := &game_state.enemies[resp.index]
                            e.velocity = {}
                            e.position.z += 1.0
                            e.home_position = enemy.position
                        }
                    }
                    case .MoveCoin: {
                        coin := &game_state.coins[resp.index]
                        if move_positionable(&game_state, input_system, renderer.viewport_dimensions, &coin.position) {
                            coin.position.z += 1.0
                        }
                    }
                    case .MovePlayerSpawn: {
                        move_positionable(&game_state, input_system, renderer.viewport_dimensions, &game_state.character_start)
                    }
                    case: {}
                }
            }
        }

        // Memory viewer
        when ODIN_DEBUG {
            if imgui_state.show_gui && user_config.flags[.ShowAllocatorStats] {
                if imgui.Begin("Allocator stats", &user_config.flags[.ShowAllocatorStats]) {
                    imgui.Text("Global allocator stats")
                    imgui.Text("Total global memory allocated: %i", global_track.current_memory_allocated)
                    imgui.Text("Peak global memory allocated: %i", global_track.peak_memory_allocated)
                    imgui.Separator()
                    imgui.Text("Per-scene allocator stats")
                    imgui.Text("Total per-scene memory allocated: %i", scene_track.current_memory_allocated)
                    imgui.Text("Peak per-scene memory allocated: %i", scene_track.peak_memory_allocated)
                    imgui.Separator()
                }
                imgui.End()
            }
        }

        // After all imgui work, update clip_from_screen matrix
        renderer.cpu_uniforms.clip_from_screen = {
            2.0 / io.DisplaySize.x, 0.0, 0.0, -1.0,
            0.0, 2.0 / io.DisplaySize.y, 0.0, -1.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0
        }

        // Determine if we're simulating a tick of game logic this frame
        game_state.do_this_frame = !game_state.paused
        if output_verbs.bools[.FrameAdvance] {
            game_state.do_this_frame = true
            game_state.paused = true
        }
        if output_verbs.bools[.Resume] do game_state.paused = !game_state.paused

        // Update and draw player
        if game_state.do_this_frame {
            player_update(&game_state, &audio_system, &output_verbs, game_state.timescale * dt)
        }
        player_draw(&game_state, &vgd, &renderer)

        // Update and draw enemies
        if game_state.do_this_frame {
            enemies_update(&game_state, &audio_system, dt * game_state.timescale)
        }
        enemies_draw(&vgd, &renderer, game_state)
        
        // Air bullet draw
        {
            bullet, ok := game_state.character.air_bullet.?
            if ok {
                dd := DebugDraw {
                    world_from_model = translation_matrix(bullet.collision.position) * uniform_scaling_matrix(bullet.collision.radius),
                    color = {0.0, 1.0, 0.0, 0.8}
                }
                draw_debug_mesh(&vgd, &renderer, game_state.sphere_mesh, &dd)

                // Make air bullet a point light source
                l := default_point_light()
                l.color = {0.0, 1.0, 0.0}
                l.world_position = bullet.collision.position
                do_point_light(&renderer, l)
            }
        }

        coins_draw(&vgd, &renderer, game_state)

        // Move player hackiness
        if move_player && !io.WantCaptureMouse {
            dims : [4]f32 = {
                cast(f32)renderer.viewport_dimensions.offset.x,
                cast(f32)renderer.viewport_dimensions.offset.y,
                cast(f32)renderer.viewport_dimensions.extent.width,
                cast(f32)renderer.viewport_dimensions.extent.height,
            }
            collision_pt, hit := do_mouse_raycast(
                game_state.viewport_camera,
                game_state.terrain_pieces[:],
                input_system.mouse_location,
                dims
            )
            if hit {
                col := &game_state.character.collision
                col.position = collision_pt
                col.position.z += col.radius
            }

            if input_system.mouse_clicked do move_player = false
        }

        // Camera update
        current_view_from_world := camera_update(&game_state, &output_verbs, dt)
        projection_from_view := camera_projection_from_view(&game_state.viewport_camera)
        renderer.cpu_uniforms.clip_from_world =
            projection_from_view *
            current_view_from_world
        {
            vfw := hlsl.float3x3(current_view_from_world)
            vfw4 := hlsl.float4x4(vfw)
            renderer.cpu_uniforms.clip_from_skybox = projection_from_view * vfw4;
            
            renderer.cpu_uniforms.view_position.xyz = game_state.viewport_camera.position
            renderer.cpu_uniforms.view_position.a = 1.0
        }

        // Update and draw static scenery
        for &mesh in game_state.static_scenery {
            rot := linalg.to_matrix4(mesh.rotation)
            world_mat := translation_matrix(mesh.position) * rot * uniform_scaling_matrix(mesh.scale)

            dd := StaticDraw {
                world_from_model = world_mat,
            }
            draw_ps1_static_mesh(&vgd, &renderer, mesh.model, &dd)
        }

        // Update and draw animated scenery
        for &mesh in game_state.animated_scenery {
            if game_state.do_this_frame {
                anim := &renderer.animations[mesh.anim_idx]
                anim_end := get_animation_endtime(anim)
                mesh.anim_t += dt * game_state.timescale * mesh.anim_speed
                mesh.anim_t = math.mod(mesh.anim_t, anim_end)
            }

            rot := linalg.to_matrix4(mesh.rotation)

            world_mat := translation_matrix(mesh.position) * rot * uniform_scaling_matrix(mesh.scale)
            dd := SkinnedDraw {
                world_from_model = world_mat,
                anim_idx = mesh.anim_idx,
                anim_t = mesh.anim_t
            }
            draw_ps1_skinned_mesh(&vgd, &renderer, mesh.model, &dd)
        }

        // Draw terrain pieces
        for &piece in game_state.terrain_pieces {
            scale := scaling_matrix(piece.scale)
            rot := linalg.matrix4_from_quaternion_f32(piece.rotation)
            trans := translation_matrix(piece.position)
            mat := trans * rot * scale
            tform := StaticDraw {
                world_from_model = mat
            }
            draw_ps1_static_mesh(&vgd, &renderer, piece.model, &tform)
        }

        // Rotate sunlight
        if rotate_sun {
            for i in 0..<renderer.cpu_uniforms.directional_light_count {
                light := &renderer.cpu_uniforms.directional_lights[i]
                d := hlsl.float4 {light.direction.x, light.direction.y, light.direction.z, 0.0}
                light.direction = (d * yaw_rotation_matrix(dt)).xyz
            }
        }

        // Window update
        {
            new_size, ok := output_verbs.int2s[.ResizeWindow]
            if ok {
                app_window.resolution.x = u32(new_size.x)
                app_window.resolution.y = u32(new_size.y)
                vgd.resize_window = true
            }

            new_pos, ok2 := output_verbs.int2s[.MoveWindow]
            if ok2 {
                user_config.ints[.WindowX] = i64(new_pos.x)
                user_config.ints[.WindowY] = i64(new_pos.y)
            }
        }

        audio_tick(&audio_system)

        // Render
        {
            full_swapchain_remake :: proc(gd: ^vkw.Graphics_Device, renderer: ^Renderer, user_config: ^UserConfiguration, window: Window) {
                io := imgui.GetIO()

                info := vkw.SwapchainInfo {
                    dimensions = {
                        uint(window.resolution.x),
                        uint(window.resolution.y)
                    },
                    present_mode = window.present_mode
                }
                if !vkw.resize_window(gd, info) do log.error("Failed to resize window")
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
            if vgd.resize_window {
                full_swapchain_remake(&vgd, &renderer, &user_config, app_window)
                vgd.resize_window = false
            }

            gfx_cb_idx := vkw.begin_gfx_command_buffer(&vgd, renderer.gfx_timeline)

            // Increment timeline semaphore upon command buffer completion
            vkw.add_signal_op(&vgd, &renderer.gfx_sync, renderer.gfx_timeline, vgd.frame_count + 1)

            // Acquire swapchain image and try to handle result
            swapchain_image_idx, acquire_result := vkw.acquire_swapchain_image(&vgd, gfx_cb_idx, &renderer.gfx_sync)
            #partial switch acquire_result {
                case .SUCCESS: {}
                case .SUBOPTIMAL_KHR, .ERROR_OUT_OF_DATE_KHR: {
                    full_swapchain_remake(&vgd, &renderer, &user_config, app_window)
                }
                case: {
                    log.errorf("Swapchain image acquire failed: %v", acquire_result)
                }
            }

            framebuffer := swapchain_framebuffer(&vgd, swapchain_image_idx, app_window.resolution)

            // Main render call
            render_scene(
                &vgd,
                gfx_cb_idx,
                &renderer,
                &game_state.viewport_camera,
                &framebuffer
            )

            // Draw Dear Imgui
            framebuffer.color_load_op = .LOAD
            render_imgui(&vgd, gfx_cb_idx, &imgui_state, &framebuffer)

            // Submit gfx command buffer and present swapchain image
            present_res := vkw.submit_gfx_and_present(&vgd, gfx_cb_idx, &renderer.gfx_sync, &swapchain_image_idx)
            if present_res == .SUBOPTIMAL_KHR || present_res == .ERROR_OUT_OF_DATE_KHR {
                full_swapchain_remake(&vgd, &renderer, &user_config, app_window)
            }
        }

        // CLear temp allocator for next frame
        free_all(context.temp_allocator)

        // Clear sync info for next frame
        vkw.clear_sync_info(&renderer.gfx_sync)
        vkw.clear_sync_info(&renderer.compute_sync)

        // CPU limiter
        // 1 millisecond == 1,000,00 nanoseconds
        if do_limit_cpu do time.sleep(time.Duration(MILLISECONDS_TO_NANOSECONDS * cpu_limiter_ms))
    }

    vkw.device_wait_idle(&vgd)
    log.info("Returning from main()")
}
