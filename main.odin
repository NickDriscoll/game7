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

MAXIMUM_FRAME_DT :: 1.0 / 60.0

SCENE_ARENA_SZIE :: 1024 * 1024         // Memory pool for per-scene allocations
TEMP_ARENA_SIZE :: 64 * 1024            // Guessing 64KB necessary size for per-frame allocations

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

// @TODO: Window grab bag struct? Just for figuring out what to do?


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
                fmt.eprintf("=== %v allocations not freed: ===\n", len(global_track.allocation_map))
                for _, entry in global_track.allocation_map {
                    fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
                }
            }
            if len(global_track.bad_free_array) > 0 {
                fmt.eprintf("=== %v incorrect frees: ===\n", len(global_track.bad_free_array))
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
                fmt.eprintf("=== %v allocations not freed: ===\n", len(scene_track.allocation_map))
                for _, entry in scene_track.allocation_map {
                    fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
                }
            }
            if len(scene_track.bad_free_array) > 0 {
                fmt.eprintf("=== %v incorrect frees: ===\n", len(scene_track.bad_free_array))
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
    user_config_last_saved := time.now()
    user_config, config_ok := load_user_config(USER_CONFIG_FILENAME)
    if !config_ok do log.error("Failed to load user config.")
    defer delete_user_config(&user_config, context.allocator)
    user_config_autosave := user_config.flags["config_autosave"]



    // Initialize SDL2
    sdl2.Init({.AUDIO, .EVENTS, .GAMECONTROLLER, .VIDEO})
    when ODIN_DEBUG do defer sdl2.Quit()
    log.info("Initialized SDL2")

    // Use SDL2 to dynamically link against the Vulkan loader
    // This allows sdl2.Vulkan_GetVkGetInstanceProcAddr() to return a real address
    if sdl2.Vulkan_LoadLibrary(nil) != 0 {
        log.fatal("Couldn't load Vulkan library.")
        return
    }



    // Initialize graphics device
    init_params := vkw.Init_Parameters {
        app_name = "Game7",
        api_version = .Vulkan13,
        frames_in_flight = FRAMES_IN_FLIGHT,
        window_support = true,
        vk_get_instance_proc_addr = sdl2.Vulkan_GetVkGetInstanceProcAddr(),
    }
    vgd := vkw.init_vulkan(&init_params)
    when ODIN_DEBUG do defer vkw.quit_vulkan(&vgd)

    // Make window 
    desktop_display_mode: sdl2.DisplayMode
    if sdl2.GetDesktopDisplayMode(0, &desktop_display_mode) != 0 {
        log.error("Error getting desktop display mode.")
    }
    display_resolution := hlsl.uint2 {
        u32(desktop_display_mode.w),
        u32(desktop_display_mode.h),
    }

    // Determine window resolution
    resolution := DEFAULT_RESOLUTION
    if user_config.flags[EXCLUSIVE_FULLSCREEEN_KEY] || user_config.flags[BORDERLESS_FULLSCREEN_KEY] do resolution = display_resolution
    if "window_width" in user_config.ints && "window_height" in user_config.ints {
        x := user_config.ints["window_width"]
        y := user_config.ints["window_height"]
        resolution = {u32(x), u32(y)}
    }

    // Determine SDL window flags
    sdl_windowflags : sdl2.WindowFlags = {.VULKAN,.RESIZABLE}
    if user_config.flags[EXCLUSIVE_FULLSCREEEN_KEY] {
        sdl_windowflags += {.FULLSCREEN}
    }
    if user_config.flags[BORDERLESS_FULLSCREEN_KEY] {
        sdl_windowflags += {.BORDERLESS}
    }

    // Determine SDL window position
    window_x : i32 = sdl2.WINDOWPOS_CENTERED
    window_y : i32 = sdl2.WINDOWPOS_CENTERED
    if "window_x" in user_config.ints && "window_y" in user_config.ints {
        window_x = i32(user_config.ints["window_x"])
        window_y = i32(user_config.ints["window_y"])
    } else {
        user_config.ints["window_x"] = i64(sdl2.WINDOWPOS_CENTERED)
        user_config.ints["window_y"] = i64(sdl2.WINDOWPOS_CENTERED)
    }

    sdl_window := sdl2.CreateWindow(
        TITLE_WITHOUT_IMGUI,
        window_x,
        window_y,
        i32(resolution.x),
        i32(resolution.y),
        sdl_windowflags
    )
    when ODIN_DEBUG do defer sdl2.DestroyWindow(sdl_window)
    sdl2.SetWindowAlwaysOnTop(sdl_window, sdl2.bool(user_config.flags["always_on_top"]))

    // Initialize the state required for rendering to the window
    if !vkw.init_sdl2_window(&vgd, sdl_window) {
        log.fatal("Couldn't init SDL2 surface.")
        return
    }

    // Now that we're done with global allocations, switch context.allocator to scene_allocator
    context.allocator = scene_allocator

    // Initialize the renderer
    renderer := init_renderer(&vgd, resolution)
    when ODIN_DEBUG do defer delete_renderer(&vgd, &renderer)
    renderer.main_framebuffer.clear_color = {0.1568627, 0.443137, 0.9176471, 1.0}

    //Dear ImGUI init
    imgui_state := imgui_init(&vgd, resolution)
    when ODIN_DEBUG do defer imgui_cleanup(&vgd, &imgui_state)
    ini_savename_buffer: [2048]u8
    if imgui_state.show_gui {
        sdl2.SetWindowTitle(sdl_window, TITLE_WITH_IMGUI)
    }

    // Main app structure storing the game's overall state
    game_state: GameState
    game_state.freecam_collision = user_config.flags["freecam_collision"]
    game_state.borderless_fullscreen = user_config.flags[BORDERLESS_FULLSCREEN_KEY]
    game_state.exclusive_fullscreen = user_config.flags[EXCLUSIVE_FULLSCREEEN_KEY]
    game_state.timescale = 1.0

    //main_scene_path : cstring = "data/models/plane.glb"
    //main_scene_path : cstring = "data/models/artisans.glb"
    main_scene_path : cstring = "data/models/game7_testmap00.glb"

    main_scene_mesh := load_gltf_static_model(&vgd, &renderer, main_scene_path)

    // Get collision data out of main scene model
    {
        positions := get_glb_positions(main_scene_path)
        mmat := uniform_scaling_matrix(1.0)
        collision := new_static_triangle_mesh(positions[:], mmat)
        // append(&game_state.terrain_pieces, TerrainPiece {
        //     collision = collision,
        //     position = {},
        //     scale = 1.0,
        //     model = main_scene_mesh,
        // })
    }

    // Load test glTF model
    moon_mesh: ^StaticModelData
    {
        //path : cstring = "data/models/spyro2.glb"
        //path : cstring = "data/models/klonoa2.glb"
        path : cstring = "data/models/majoras_moon.glb"
        moon_mesh = load_gltf_static_model(&vgd, &renderer, path)
    }

    // Load icosphere mesh for debug visualization
    game_state.sphere_mesh = load_gltf_static_model(&vgd, &renderer, "data/models/icosphere.glb")

    // Add moon terrain piece
    {
        positions := get_glb_positions("data/models/majoras_moon.glb")
        rotq := linalg.quaternion_from_euler_angles_f32(0.0, 0.0, -math.PI / 4.0, linalg.Euler_Angle_Order.XYZ)
        rotq *= linalg.quaternion_from_euler_angles_f32(math.PI / 4.0 , 0.0, 0.0, linalg.Euler_Angle_Order.XYZ)
        scale := uniform_scaling_matrix(300.0)
        rot := linalg.to_matrix4(rotq)
        trans := translation_matrix({350.0, 400.0, 500.0})
        mat := trans * rot * scale
        collision := new_static_triangle_mesh(positions[:], mat)

        // append(&game_state.terrain_pieces, TerrainPiece {
        //     collision = collision,
        //     position = {350.0, 400.0, 500.0},
        //     rotation = rotq,
        //     scale = 300.0,
        //     model = moon_mesh
        // })
    }

    // Load animated test glTF model
    skinned_model: ^SkinnedModelData
    {
        //path : cstring = "data/models/RiggedSimple.glb"
        path : cstring = "data/models/CesiumMan.glb"
        //path : cstring = "data/models/DreadSamus.glb"
        skinned_model = load_gltf_skinned_model(&vgd, &renderer, path)
        // append(&game_state.animated_scenery, AnimatedScenery {
        //     model = skinned_model,
        //     position = {50.2138786, 65.6309738, -2.65704226},
        //     rotation = quaternion(real=math.cos_f32(math.PI / 4.0), imag=0, jmag=0, kmag=math.sin_f32(math.PI / 4.0)),
        //     scale = 1.0,
        //     anim_idx = 0,
        //     anim_t = 0.0,
        //     anim_speed = 1.0,
        // })
    }

    // @TODO: Load this value from level file
    //game_state.character_start = {-9.0, 15.0, 1.0}
    load_level_file(&vgd, &renderer, &game_state, "data/levels/hardcoded_test.lvl")

    game_state.character = Character {
        collision = {
            position = game_state.character_start,
            radius = 0.8
        },
        velocity = {},
        deceleration_speed = 0.1,
        state = .Falling,
        facing = {0.0, 1.0, 0.0},
        move_speed = 7.0,
        jump_speed = 8.0,
        remaining_jumps = 2,
        anim_speed = 0.856,
        mesh_data = skinned_model
    }

    // Initialize main viewport camera
    game_state.viewport_camera = Camera {
        position = {
            f32(user_config.floats["freecam_x"]),
            f32(user_config.floats["freecam_y"]),
            f32(user_config.floats["freecam_z"])
        },
        yaw = f32(user_config.floats["freecam_yaw"]),
        pitch = f32(user_config.floats["freecam_pitch"]),
        fov_radians = f32(user_config.floats["camera_fov"]),
        aspect_ratio = f32(resolution.x) / f32(resolution.y),
        nearplane = 0.1 / math.sqrt_f32(2.0),
        farplane = 1_000_000.0,
        collision_radius = 0.1,
        target = {
            distance = 8.0
        },
    }
    game_state.freecam_speed_multiplier = 5.0
    game_state.freecam_slow_multiplier = 1.0 / 5.0
    if user_config.flags["follow_cam"] do game_state.viewport_camera.control_flags += {.Follow}
    log.debug(game_state.viewport_camera)
    saved_mouse_coords := hlsl.int2 {0, 0}

    game_state.camera_follow_point = game_state.character.collision.position
    game_state.camera_follow_speed = 6.0

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

    // Init audio system
    audio_system := init_audio_system()

    // Setup may have used temp allocation, 
    // so clear out temp memory before first frame processing
    free_all(context.temp_allocator)

    current_time := time.now()          // Time in nanoseconds since UNIX epoch
    previous_time := time.time_add(current_time, time.Duration(-1_000_000)) //current_time - time.Time{_nsec = 1}
    do_limit_cpu := false
    paused := false
    do_this_frame := true

    log.info("App initialization complete. Entering main loop")

    do_main_loop := true
    for do_main_loop {
        // Time
        current_time = time.now()
        nanosecond_dt := time.diff(previous_time, current_time)
        last_frame_dt := f32(nanosecond_dt / 1000) / 1_000_000
        last_frame_dt = min(last_frame_dt, MAXIMUM_FRAME_DT)
        previous_time = current_time

        // Save user configuration every 100ms
        if user_config_autosave && time.diff(user_config_last_saved, current_time) >= 1_000_000 {
            update_user_cfg_camera(&user_config, &game_state.viewport_camera)
            save_user_config(&user_config, USER_CONFIG_FILENAME)
            user_config_last_saved = current_time
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
                if imgui_state.show_gui {
                    sdl2.SetWindowTitle(sdl_window, TITLE_WITH_IMGUI)
                } else {
                    sdl2.SetWindowTitle(sdl_window, TITLE_WITHOUT_IMGUI)
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
                        sdl2.WarpMouseInWindow(sdl_window, saved_mouse_coords.x, saved_mouse_coords.y)
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
                sdl2.WarpMouseInWindow(sdl_window, saved_mouse_coords.x, saved_mouse_coords.y)
            }

        }


        // Update

        docknode := imgui.DockBuilderGetCentralNode(imgui_state.dockspace_id)
        renderer.viewport_dimensions[0] = docknode.Pos.x
        renderer.viewport_dimensions[1] = docknode.Pos.y
        renderer.viewport_dimensions[2] = docknode.Size.x
        renderer.viewport_dimensions[3] = docknode.Size.y
        game_state.viewport_camera.aspect_ratio = docknode.Size.x / docknode.Size.y

        @static cpu_limiter_ms : c.int = 100

        // Misc imgui window for testing
        @static move_player := false
        @static last_raycast_hit: hlsl.float3
        want_refire_raycast := false
        if imgui_state.show_gui && user_config.flags["show_debug_menu"] {
            if imgui.Begin("Hacking window", &user_config.flags["show_debug_menu"]) {
                imgui.Text("Frame #%i", vgd.frame_count)
                imgui.Separator()
                imgui.SliderFloat("Camera smoothing speed", &game_state.camera_follow_speed, 0.1, 50.0)
                if imgui.Checkbox("Enable freecam collision", &game_state.freecam_collision) {
                    user_config.flags["freecam_collision"] = game_state.freecam_collision
                }
                imgui.Separator()

                {
                    using game_state.character

                    sb: strings.Builder
                    strings.builder_init(&sb, context.temp_allocator)
                    defer strings.builder_destroy(&sb)

                    flag := .ShowPlayerHitSphere in game_state.debug_vis_flags
                    if imgui.Checkbox("Show player collision", &flag) do game_state.debug_vis_flags ~= {.ShowPlayerHitSphere}
                    imgui.Text("Player collider position: (%f, %f, %f)", collision.position.x, collision.position.y, collision.position.z)
                    imgui.Text("Player collider velocity: (%f, %f, %f)", velocity.x, velocity.y, velocity.z)
                    imgui.Text("Player collider acceleration: (%f, %f, %f)", acceleration.x, acceleration.y, acceleration.z)
                    fmt.sbprintf(&sb, "Player state: %v", state)
                    state_str, _ := strings.to_cstring(&sb)
                    strings.builder_reset(&sb)
                    imgui.Text(state_str)
                    imgui.SliderFloat("Player move speed", &move_speed, 1.0, 50.0)
                    imgui.SliderFloat("Player deceleration speed", &deceleration_speed, 0.01, 2.0)
                    imgui.SliderFloat("Player jump speed", &jump_speed, 1.0, 50.0)
                    imgui.SliderFloat("Player anim speed", &anim_speed, 0.0, 2.0)
                    if imgui.Button("Reset player") {
                        collision.position = game_state.character_start
                        velocity = {}
                    }
                    imgui.SameLine()
                    imgui.BeginDisabled(move_player)
                    if imgui.Button("Move player") {
                        move_player = true
                    }
                    imgui.EndDisabled()
                    imgui.Text("Last raycast hit: (%f, %f, %f)", last_raycast_hit.x, last_raycast_hit.y, last_raycast_hit.z)
                    if imgui.Button("Refire last raycast") {
                        want_refire_raycast = true
                    }
                    imgui.Separator()
                }

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
                    b := renderer.cpu_uniforms.triangle_vis == 1
                    if imgui.Checkbox("Triangle vis", &b) do renderer.cpu_uniforms.triangle_vis ~= 1
                }
                imgui.Separator()

                ini_cstring := cstring(&ini_savename_buffer[0])
                imgui.Text("Save current configuration of Dear ImGUI windows")
                imgui.InputText(".ini filename", ini_cstring, len(ini_savename_buffer) - 1)
                if imgui.Button("Save current GUI configuration") {
                    imgui.SaveIniSettingsToDisk(ini_cstring)
                    log.debugf("Saved Dear ImGUI ini settings to \"%v\"", ini_cstring)
                    ini_savename_buffer = {}
                }
                imgui.Separator()
            }
            imgui.End()
        }

        // React to main menu bar interaction
        @static show_load_modal := false
        switch main_menu_bar(&imgui_state, &game_state, &user_config) {
            case .Exit: do_main_loop = false
            case .SaveLevel: {
                write_level_file(&game_state)
            }
            case .ToggleAlwaysOnTop: {
                sdl2.SetWindowAlwaysOnTop(sdl_window, sdl2.bool(user_config.flags["always_on_top"]))
            }
            case .ToggleBorderlessFullscreen: {
                game_state.borderless_fullscreen = !game_state.borderless_fullscreen
                game_state.exclusive_fullscreen = false
                xpos, ypos: c.int
                if game_state.borderless_fullscreen {
                    resolution = display_resolution
                } else {
                    resolution = DEFAULT_RESOLUTION
                    xpos = c.int(display_resolution.x / 2 - DEFAULT_RESOLUTION.x / 2)
                    ypos = c.int(display_resolution.y / 2 - DEFAULT_RESOLUTION.y / 2)
                }
                io.DisplaySize.x = f32(resolution.x)
                io.DisplaySize.y = f32(resolution.y)
                user_config.ints["window_x"] = i64(xpos)
                user_config.ints["window_y"] = i64(ypos)

                sdl2.SetWindowBordered(sdl_window, !game_state.borderless_fullscreen)
                sdl2.SetWindowPosition(sdl_window, xpos, ypos)
                sdl2.SetWindowSize(sdl_window, c.int(resolution.x), c.int(resolution.y))
                sdl2.SetWindowResizable(sdl_window, !game_state.borderless_fullscreen)

                vgd.resize_window = true
            }
            case .ToggleExclusiveFullscreen: {
                game_state.exclusive_fullscreen = !game_state.exclusive_fullscreen
                game_state.borderless_fullscreen = false
                xpos, ypos: c.int
                flags : sdl2.WindowFlags = nil
                resolution = DEFAULT_RESOLUTION
                if game_state.exclusive_fullscreen {
                    flags += {.FULLSCREEN}
                    resolution = display_resolution
                } else {
                    resolution = DEFAULT_RESOLUTION
                    xpos = c.int(display_resolution.x / 2 - DEFAULT_RESOLUTION.x / 2)
                    ypos = c.int(display_resolution.y / 2 - DEFAULT_RESOLUTION.y / 2)
                }
                io.DisplaySize.x = f32(resolution.x)
                io.DisplaySize.y = f32(resolution.y)
                user_config.ints["window_x"] = i64(xpos)
                user_config.ints["window_y"] = i64(ypos)

                sdl2.SetWindowSize(sdl_window, c.int(resolution.x), c.int(resolution.y))
                sdl2.SetWindowFullscreen(sdl_window, flags)
                sdl2.SetWindowResizable(sdl_window, !game_state.exclusive_fullscreen)

                vgd.resize_window = true
            }
            case .ShowLoadModal: {
                show_load_modal = true
            }
            case .None: {}
        }

        if show_load_modal {
            imgui.OpenPopup("Modal testing bb")

            if imgui.BeginPopupModal("Modal testing bb") {
                imgui.Text("Plz show up")
                if imgui.Button("Return") do show_load_modal = false
                imgui.EndPopup()
            }
        }

        if imgui_state.show_gui && user_config.flags["camera_config"] {
            res, ok := camera_gui(
                &game_state,
                &game_state.viewport_camera,
                &input_system,
                &user_config,
                &user_config.flags["camera_config"]
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

        // Input remapping GUI
        if imgui_state.show_gui && user_config.flags["input_config"] do input_gui(&input_system, &user_config.flags["input_config"])

        // Imgui Demo
        if imgui_state.show_gui && user_config.flags["show_imgui_demo"] do imgui.ShowDemoWindow(&user_config.flags["show_imgui_demo"])

        // Handle current editor state
        {
            obj, edit_ok := game_state.editor_response.(EditorResponse)
            if edit_ok {
                if !io.WantCaptureMouse {
                    viewport_coords := hlsl.uint2 {
                        u32(input_system.mouse_location.x) - u32(renderer.viewport_dimensions[0]),
                        u32(input_system.mouse_location.y) - u32(renderer.viewport_dimensions[1]),
                    }
                    ray := get_view_ray(
                        &game_state.viewport_camera,
                        viewport_coords,
                        {u32(renderer.viewport_dimensions[2]), u32(renderer.viewport_dimensions[3])}
                    )

                    collision_pt: hlsl.float3
                    closest_dist := math.INF_F32
                    for &piece in game_state.terrain_pieces {
                        candidate, ok := intersect_ray_triangles(&ray, &piece.collision)
                        if ok {
                            candidate_dist := hlsl.distance(collision_pt, game_state.viewport_camera.position)
                            if candidate_dist < closest_dist {
                                collision_pt = candidate
                                closest_dist = candidate_dist
                            }
                        }
                    }

                    if closest_dist < math.INF_F32 {
                        #partial switch obj.type {
                            case. MoveTerrainPiece: {
                                object := &game_state.terrain_pieces[obj.index]
                                object.position = collision_pt
                            }
                            case .MoveStaticScenery: {
                                object := &game_state.static_scenery[obj.index]
                                object.position = collision_pt
                            }
                            case .MoveAnimatedScenery: {
                                object := &game_state.animated_scenery[obj.index]
                                object.position = collision_pt
                            }
                            case: {}
                        }
                    }

                    if input_system.mouse_clicked {
                        game_state.editor_response = nil
                    }
                }
            }
        }

        // Memory viewer
        when ODIN_DEBUG {
            if imgui_state.show_gui && user_config.flags["show_allocator_stats"] {
                if imgui.Begin("Allocator stats", &user_config.flags["show_allocator_stats"]) {
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
        do_this_frame = !paused
        if output_verbs.bools[.FrameAdvance] {
            do_this_frame = true
            paused = true
        }
        if output_verbs.bools[.Resume] do paused = !paused

        // Update and draw player
        if do_this_frame {
            player_update(&game_state, &output_verbs, game_state.timescale * last_frame_dt)
        }

        player_draw(&game_state, &vgd, &renderer)

        // Camera update
        current_view_from_world := camera_update(&game_state, &output_verbs, last_frame_dt)
        projection_from_view := camera_projection_from_view(&game_state.viewport_camera)
        renderer.cpu_uniforms.clip_from_world =
            projection_from_view *
            current_view_from_world
        {
            vfw := hlsl.float3x3(current_view_from_world)
            vfw4 := hlsl.float4x4(vfw)
            renderer.cpu_uniforms.clip_from_skybox = projection_from_view * vfw4;
        }

        // Move player hackiness
        if move_player && !io.WantCaptureMouse {
            viewport_coords := hlsl.uint2 {
                u32(input_system.mouse_location.x) - u32(renderer.viewport_dimensions[0]),
                u32(input_system.mouse_location.y) - u32(renderer.viewport_dimensions[1]),
            }
            ray := get_view_ray(
                &game_state.viewport_camera,
                viewport_coords,
                {u32(renderer.viewport_dimensions[2]), u32(renderer.viewport_dimensions[3])}
            )

            collision_pt: hlsl.float3
            closest_dist := math.INF_F32
            for &piece in game_state.terrain_pieces {
                candidate, ok := intersect_ray_triangles(&ray, &piece.collision)
                if ok {
                    candidate_dist := hlsl.distance(collision_pt, game_state.viewport_camera.position)
                    if candidate_dist < closest_dist {
                        collision_pt = candidate
                        closest_dist = candidate_dist
                    }
                }
            }
            if closest_dist < math.INF_F32 {
                col := &game_state.character.collision
                col.position = collision_pt
                col.position.z += col.radius
            }

            if input_system.mouse_clicked do move_player = false
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
            if do_this_frame {
                anim := &renderer.animations[mesh.anim_idx]
                anim_end := get_animation_endtime(anim)
                mesh.anim_t += last_frame_dt * game_state.timescale * mesh.anim_speed
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

        // Window update
        {
            new_size, ok := output_verbs.int2s[.ResizeWindow]
            if ok {
                resolution.x = u32(new_size.x)
                resolution.y = u32(new_size.y)
                vgd.resize_window = true
            }

            new_pos, ok2 := output_verbs.int2s[.MoveWindow]
            if ok2 {
                user_config.ints["window_x"] = i64(new_pos.x)
                user_config.ints["window_y"] = i64(new_pos.y)
            }
        }

        // Render
        {
            // Resize swapchain if necessary
            if vgd.resize_window {
                if !vkw.resize_window(&vgd, resolution) do log.error("Failed to resize window")
                resize_framebuffers(&vgd, &renderer, resolution)
                game_state.viewport_camera.aspect_ratio = f32(resolution.x) / f32(resolution.y)
                user_config.ints["window_width"] = i64(resolution.x)
                user_config.ints["window_height"] = i64(resolution.y)
                io.DisplaySize.x = f32(resolution.x)
                io.DisplaySize.y = f32(resolution.y)

                vgd.resize_window = false
            }

            gfx_cb_idx := vkw.begin_gfx_command_buffer(&vgd, renderer.gfx_timeline)

            // Increment timeline semaphore upon command buffer completion
            vkw.add_signal_op(&vgd, &renderer.gfx_sync, renderer.gfx_timeline, vgd.frame_count + 1)

            swapchain_image_idx, _ := vkw.acquire_swapchain_image(&vgd, gfx_cb_idx, &renderer.gfx_sync)

            framebuffer := swapchain_framebuffer(&vgd, swapchain_image_idx, cast([2]u32)resolution)

            // Main render call
            render(
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
            vkw.submit_gfx_and_present(&vgd, gfx_cb_idx, &renderer.gfx_sync, &swapchain_image_idx)
        }

        // CLear temp allocator for next frame
        free_all(context.temp_allocator)

        // Clear sync info for next frame
        vkw.clear_sync_info(&renderer.gfx_sync)
        vkw.clear_sync_info(&renderer.compute_sync)
        vgd.frame_count += 1

        // CPU limiter
        // 100 mil nanoseconds == 100 milliseconds
        if do_limit_cpu do time.sleep(time.Duration(1_000_000 * cpu_limiter_ms))
    }

    log.info("Returning from main()")

    vkw.device_wait_idle(&vgd)
}
