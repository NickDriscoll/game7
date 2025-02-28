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
import stbi "vendor:stb/image"

import imgui "odin-imgui"
import vk "vendor:vulkan"
import vkw "desktop_vulkan_wrapper"
import hm "desktop_vulkan_wrapper/handlemap"

USER_CONFIG_FILENAME :: "user.cfg"
TITLE_WITHOUT_IMGUI :: "KataWARi"
TITLE_WITH_IMGUI :: "KataWARi -- Press ESC to hide developer GUI"
DEFAULT_RESOLUTION :: hlsl.uint2 {1280, 720}

MAXIMUM_FRAME_DT :: 1.0 / 60.0

TEMP_ARENA_SIZE :: 64 * 1024            //Guessing 64KB necessary size for per-frame allocations

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


ComputeSkinningPushConstants :: struct {
    in_positions: vk.DeviceAddress,
    out_positions: vk.DeviceAddress,
    joint_ids: vk.DeviceAddress,
    joint_weights: vk.DeviceAddress,
    joint_transforms: vk.DeviceAddress,
    max_vtx_id: u32,
}

TerrainPiece :: struct {
    collision: StaticTriangleCollision,
    model_matrix: hlsl.float4x4,
    mesh_data: StaticModelData,
}

delete_terrain_piece :: proc(using t: ^TerrainPiece) {
    delete_static_triangles(&collision)
}

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


CHARACTER_START_POS : hlsl.float3 : {-19.0, 45.0, 10.0}
Character :: struct {
    collision: Sphere,
    state: CharacterState,
    velocity: hlsl.float3,
    facing: hlsl.float3,
    move_speed: f32,
    jump_speed: f32,
    remaining_jumps: u32,
    control_flags: CharacterFlags,
    mesh_data: StaticModelData,
}

GameState :: struct {
    character: Character,
    viewport_camera: Camera,
    terrain_pieces: [dynamic]TerrainPiece,
    camera_follow_point: hlsl.float3,
    camera_follow_speed: f32,
    timescale: f32,

    freecam_collision: bool,
    borderless_fullscreen: bool,
    exclusive_fullscreen: bool
}

delete_game :: proc(using g: ^GameState) {
    for &piece in terrain_pieces do delete_terrain_piece(&piece)
    delete(terrain_pieces)
}

main :: proc() {
    // Parse command-line arguments
    log_level := log.Level.Info
    context.logger = log.create_console_logger(log_level)
    {
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
    }

    // Set up logger
    context.logger = log.create_console_logger(log_level)
    log.info("Initiating swag mode...")

    // Set up global allocator
    context.allocator = runtime.heap_allocator()
    when ODIN_DEBUG {
        // Set up the tracking allocator if this is a debug build
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        context.allocator = mem.tracking_allocator(&track)
        
        defer {
            if len(track.allocation_map) > 0 {
                fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
                for _, entry in track.allocation_map {
                    fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
                }
            }
            if len(track.bad_free_array) > 0 {
                fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
                for entry in track.bad_free_array {
                    fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
                }
            }
            mem.tracking_allocator_destroy(&track)
        }
    }

    // Set up per-frame temp allocator
    per_frame_arena: mem.Arena
    backing_memory: []byte
    {
        err: mem.Allocator_Error
        backing_memory, err = mem.alloc_bytes(TEMP_ARENA_SIZE)
        if err != nil {
            log.error("Error allocating temporary memory backing buffer.")
        }

        mem.arena_init(&per_frame_arena, backing_memory)
        context.temp_allocator = mem.arena_allocator(&per_frame_arena)
    }
    defer mem.free_bytes(backing_memory)

    // Load user configuration
    user_config_last_saved := time.now()
    user_config, config_ok := load_user_config(USER_CONFIG_FILENAME)
    if !config_ok do log.error("Failed to load user config.")
    defer delete_user_config(&user_config, context.allocator)
    user_config_autosave := user_config.flags["config_autosave"]

    // Initialize SDL2
    sdl2.Init({.EVENTS, .GAMECONTROLLER, .VIDEO})
    defer sdl2.Quit()
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
    defer vkw.quit_vulkan(&vgd)
    
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
    defer sdl2.DestroyWindow(sdl_window)
    sdl2.SetWindowAlwaysOnTop(sdl_window, sdl2.bool(user_config.flags["always_on_top"]))

    // Initialize the state required for rendering to the window
    if !vkw.init_sdl2_window(&vgd, sdl_window) {
        log.fatal("Couldn't init SDL2 surface.")
        return
    }

    // Main app structure storing the game's overall state
    game_state: GameState
    defer delete_game(&game_state)
    game_state.freecam_collision = user_config.flags["freecam_collision"]
    game_state.borderless_fullscreen = user_config.flags[BORDERLESS_FULLSCREEN_KEY]
    game_state.exclusive_fullscreen = user_config.flags[EXCLUSIVE_FULLSCREEEN_KEY]
    game_state.timescale = 1.0

    // Initialize the renderer
    renderer := init_renderer(&vgd, resolution)
    defer delete_renderer(&vgd, &renderer)
    renderer.main_framebuffer.clear_color = {0.1568627, 0.443137, 0.9176471, 1.0}

    //Dear ImGUI init
    imgui_state := imgui_init(&vgd, resolution)
    defer imgui_cleanup(&vgd, &imgui_state)
    ini_savename_buffer: [2048]u8
    if imgui_state.show_gui {
        sdl2.SetWindowTitle(sdl_window, TITLE_WITH_IMGUI)
    }

    main_scene_path : cstring = "data/models/artisans.glb"
    //main_scene_path : cstring = "data/models/plane.glb"

    main_scene_mesh := load_gltf_static_model(&vgd, &renderer, main_scene_path)
    defer gltf_static_delete(&main_scene_mesh)

    // Get collision data out of main scene model
    {
        positions := get_glb_positions(main_scene_path, context.temp_allocator)
        defer delete(positions)
        mmat := uniform_scaling_matrix(1.0)
        collision := static_triangle_mesh(positions[:], mmat)
        append(&game_state.terrain_pieces, TerrainPiece {
            collision = collision,
            model_matrix = mmat,
            mesh_data = main_scene_mesh,
        })
    }

    // Load test glTF model
    spyro_mesh: StaticModelData
    moon_mesh: StaticModelData
    defer gltf_static_delete(&spyro_mesh)
    defer gltf_static_delete(&moon_mesh)
    {
        path : cstring = "data/models/spyro2.glb"
        //path : cstring = "data/models/klonoa2.glb"
        spyro_mesh = load_gltf_static_model(&vgd, &renderer, path)
        path = "data/models/majoras_moon.glb"
        moon_mesh = load_gltf_static_model(&vgd, &renderer, path)
    }
    
    // Add moon terrain piece
    {
        positions := get_glb_positions("data/models/majoras_moon.glb", context.temp_allocator)
        scale := uniform_scaling_matrix(300.0)
        rot := yaw_rotation_matrix(-math.PI / 4) * pitch_rotation_matrix(math.PI / 4)
        trans := translation_matrix({350.0, 400.0, 500.0})
        mat := trans * rot * scale
        collision := static_triangle_mesh(positions[:], mat)
        append(&game_state.terrain_pieces, TerrainPiece {
            collision = collision,
            model_matrix = mat,
            mesh_data = moon_mesh
        })
    }

    // Load animated test glTF model
    simple_skinned_model: SkinnedModelData
    defer gltf_skinned_delete(&simple_skinned_model)
    {
        path : cstring = "data/models/RiggedSimple.glb"
        simple_skinned_model = load_gltf_skinned_model(&vgd, &renderer, path, context.temp_allocator)
    }

    game_state.character = Character {
        collision = {
            position = CHARACTER_START_POS,
            radius = 0.8
        },
        velocity = {},
        state = .Falling,
        facing = {0.0, 1.0, 0.0},
        move_speed = 10.0,
        jump_speed = 15.0,
        mesh_data = moon_mesh
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
        nearplane = 0.1,
        farplane = 1_000_000.0,
        collision_radius = 0.8,
        target = {
            distance = 8.0
        },
        control_flags = {.Follow}
    }
    log.debug(game_state.viewport_camera)
    saved_mouse_coords := hlsl.int2 {0, 0}

    game_state.camera_follow_point = game_state.character.collision.position
    game_state.camera_follow_speed = 6.0

    freecam_key_mappings := make(map[sdl2.Scancode]VerbType, allocator = context.allocator)
    defer delete(freecam_key_mappings)
    character_key_mappings := make(map[sdl2.Scancode]VerbType, allocator = context.allocator)
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
        
        character_key_mappings[.ESCAPE] = .ToggleImgui
        character_key_mappings[.W] = .PlayerTranslateForward
        character_key_mappings[.S] = .PlayerTranslateBack
        character_key_mappings[.A] = .PlayerTranslateLeft
        character_key_mappings[.D] = .PlayerTranslateRight
        character_key_mappings[.Q] = .TranslateFreecamDown
        character_key_mappings[.E] = .TranslateFreecamUp
        character_key_mappings[.LSHIFT] = .Sprint
        character_key_mappings[.LCTRL] = .Crawl
        character_key_mappings[.SPACE] = .PlayerJump
    }

    // Init input system
    input_system: InputSystem
    defer destroy_input_system(&input_system)
    if .Follow in game_state.viewport_camera.control_flags {
        input_system = init_input_system(&character_key_mappings)
    } else {
        input_system = init_input_system(&freecam_key_mappings)
    }

    // Setup may have used temp allocation, 
    // so clear out temp memory before first frame processing
    free_all(context.temp_allocator)

    current_time := time.now()          // Time in nanoseconds since UNIX epoch
    previous_time := time.time_add(current_time, time.Duration(-1_000_000)) //current_time - time.Time{_nsec = 1}
    limit_cpu := false
    
    log.info("App initialization complete. Entering main loop")

    do_main_loop := true
    for do_main_loop {
        // Time
        current_time = time.now()
        nanosecond_dt := time.diff(previous_time, current_time)
        last_frame_dt := f32(nanosecond_dt / 1000) / 1_000_000
        last_frame_dt = min(last_frame_dt, MAXIMUM_FRAME_DT)
        previous_time = current_time

        // Save user configuration every second or so
        if user_config_autosave && time.diff(user_config_last_saved, current_time) < 1_000_000_000 {
            update_user_cfg_camera(&user_config, &game_state.viewport_camera)
            save_user_config(&user_config, USER_CONFIG_FILENAME)
            user_config_last_saved = current_time
        }
        
        // Start a new Dear ImGUI frame and get an io reference
        begin_gui(&imgui_state)
        io := imgui.GetIO()
        io.DeltaTime = last_frame_dt
        renderer.cpu_uniforms.clip_from_screen = {
            2.0 / io.DisplaySize.x, 0.0, 0.0, -1.0,
            0.0, 2.0 / io.DisplaySize.y, 0.0, -1.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0
        }
        renderer.cpu_uniforms.time = f32(vgd.frame_count) / 144
        
        output_verbs := poll_sdl2_events(&input_system)

        // Quit if user wants it
        do_main_loop = !output_verbs.bools[.Quit]
        
        // Process the app verbs that the input system returned to the game
        @static camera_sprint_multiplier : f32 = 5.0
        @static camera_slow_multiplier : f32 = 1.0 / 5.0

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
        @static last_raycast_hit: hlsl.float3
        want_refire_raycast := false
        if imgui_state.show_gui && user_config.flags["show_debug_menu"] {
            using game_state.viewport_camera
            if imgui.Begin("Hacking window", &user_config.flags["show_debug_menu"]) {
                imgui.Text("Frame #%i", vgd.frame_count)
                imgui.Text("Camera position: (%f, %f, %f)", position.x, position.y, position.z)
                imgui.Text("Camera yaw: %f", yaw)
                imgui.Text("Camera pitch: %f", pitch)
                imgui.SliderFloat("Camera fast speed", &camera_sprint_multiplier, 0.0, 100.0)
                imgui.SliderFloat("Camera slow speed", &camera_slow_multiplier, 0.0, 1.0/5.0)
                
                follow_cam := .Follow in control_flags
                if imgui.Checkbox("Follow cam", &follow_cam) {
                    pitch = 0.0
                    yaw = 0.0
                    control_flags ~= {.Follow}
                    if .Follow in control_flags {
                        replace_keybindings(&input_system, &character_key_mappings)
                    } else {
                        replace_keybindings(&input_system, &freecam_key_mappings)
                    }
                }
                imgui.SliderFloat("Camera follow distance", &target.distance, 1.0, 20.0)
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

                    imgui.Text("Player collider position: (%f, %f, %f)", collision.position.x, collision.position.y, collision.position.z)
                    imgui.Text("Player collider velocity: (%f, %f, %f)", velocity.x, velocity.y, velocity.z)
                    fmt.sbprintf(&sb, "Player state: %v", state)
                    state_str := strings.to_cstring(&sb)
                    strings.builder_reset(&sb)
                    imgui.Text(state_str)
                    imgui.SliderFloat("Player move speed", &move_speed, 1.0, 50.0)
                    imgui.SliderFloat("Player jump speed", &jump_speed, 1.0, 50.0)
                    if imgui.Button("Reset player") {
                        collision.position = CHARACTER_START_POS
                        velocity = {}
                    }
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
                
                //imgui.ColorPicker4("Clear color", (^[4]f32)(&render_data.main_framebuffer.clear_color), {.NoPicker})
                
                imgui.Checkbox("Enable CPU Limiter", &limit_cpu)
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

                if imgui.Checkbox("Periodically save user config", &user_config_autosave) {
                    user_config.flags["config_autosave"] = user_config_autosave
                }
            }
            imgui.End()
        }

        // React to main menu bar interaction
        switch main_menu_bar(&imgui_state, &game_state, &user_config) {
            case .Exit: do_main_loop = false
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
            case .None: {}
        }

        // if imgui_state.show_gui && user_config.flags["show_memory_tracker"] {
        //     if imgui.Begin("Memory tracker", &user_config.flags["show_memory_tracker"]) {
        //         when ODIN_DEBUG == true {
        //             sb: strings.Builder
        //             strings.builder_init(&sb, context.temp_allocator)
        //             defer strings.builder_destroy(&sb)

        //             total_alloc_size := 0
        //             for _, al in track.allocation_map {
        //                 total_alloc_size += al.size
        //             }

        //             imgui.Text("Tracking_Allocator for context.allocator:")
        //             imgui.Text("Current number of allocations: %i", len(track.allocation_map))
        //             imgui.Text("Total bytes allocated by context.allocator: %i", total_alloc_size)
        //             for ptr, al in track.allocation_map {
        //                 t := strings.clone_to_cstring(fmt.sbprintf(&sb, "0x%v, %#v", ptr, al), context.temp_allocator)
        //                 imgui.Text(t)
        //                 strings.builder_reset(&sb)
        //             }
        //         } else {
        //             imgui.Text("No tracking allocators in Release builds.")
        //         }
        //     }
        //     imgui.End()
        // }

        // Input remapping GUI
        if imgui_state.show_gui && user_config.flags["input_config"] do input_gui(&input_system, &user_config.flags["input_config"])

        // Imgui Demo
        if imgui_state.show_gui && user_config.flags["show_imgui_demo"] do imgui.ShowDemoWindow(&user_config.flags["show_imgui_demo"])
        
        @static current_view_from_world: hlsl.float4x4

        // TEST CODE PLZ REMOVE
        {
            place_thing_screen_coords, ok2 := output_verbs.int2s[.PlaceThing]
            if want_refire_raycast {
                collision_pt := last_raycast_hit
                game_state.character.collision.position = collision_pt + {0.0, 0.0, game_state.character.collision.radius}
                game_state.character.velocity = {}
                game_state.character.state = .Falling
            } else if !io.WantCaptureMouse && ok2 && place_thing_screen_coords != {0, 0} {
                viewport_coords := hlsl.uint2 {
                    u32(place_thing_screen_coords.x) - u32(renderer.viewport_dimensions[0]),
                    u32(place_thing_screen_coords.y) - u32(renderer.viewport_dimensions[1]),
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
                    game_state.character.collision.position = collision_pt + {0.0, 0.0, game_state.character.collision.radius}
                    game_state.character.velocity = {}
                    game_state.character.state = .Falling
                    last_raycast_hit = collision_pt
                }
            }
        }
        // Update and draw player
        player_update(&game_state, &output_verbs, last_frame_dt)
        player_draw(&game_state, &vgd, &renderer)

        // Camera update
        current_view_from_world = camera_update(&game_state, &output_verbs, last_frame_dt, camera_sprint_multiplier, camera_slow_multiplier)
        renderer.cpu_uniforms.clip_from_world =
            camera_projection_from_view(&game_state.viewport_camera) *
            current_view_from_world

        // Draw arbitrary skinned mesh
        {
            anim_idx := simple_skinned_model.first_animation_idx
            anim := &renderer.animations[anim_idx]
            anim_end := get_animation_endtime(anim)
            anim_t := math.remainder(renderer.cpu_uniforms.time * 0.1, anim_end)
            log.debug(renderer.cpu_uniforms.time)
            dd := SkinnedDraw {
                world_from_model = translation_matrix({0.0, 10.0, 5.0}),
                anim_idx = anim_idx,
                anim_t = anim_t
            }
            draw_ps1_skinned_mesh(&vgd, &renderer, &simple_skinned_model, &dd)
        }

        // Draw terrain pieces
        for &piece in game_state.terrain_pieces {
            tform := StaticDraw {
                world_from_model = piece.model_matrix
            }
            draw_ps1_static_mesh(&vgd, &renderer, &piece.mesh_data, &tform)
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


            // Do CPU-side work for animations
            // Need to put data in relevant place for compute shader operation
            // then launch said compute shader
            {
                push_constant_batches := make([dynamic]ComputeSkinningPushConstants, 0, len(renderer.cpu_skinned_instances), allocator = context.temp_allocator)
                vertex_counts := make([dynamic]u32, 0, len(renderer.cpu_skinned_instances), allocator = context.temp_allocator)
                instance_joints_so_far : u32 = 0
                skinned_verts_so_far : u32 = 0
                for skinned_instance in renderer.cpu_skinned_instances {
                    anim := renderer.animations[skinned_instance.animation_idx]
                    anim_t := skinned_instance.animation_time

                    mesh, _ := hm.get(&renderer.cpu_skinned_meshes, hm.Handle(skinned_instance.mesh_handle))
                    
                    // Get interpolated keyframe state for translation, rotation, and scale
                    {
                        // Initialize joint matrices with identity matrix
                        instance_joints := make([dynamic]hlsl.float4x4, mesh.joint_count, allocator = context.temp_allocator)
                        for i in 0..<mesh.joint_count do instance_joints[i] = IDENTITY_MATRIX4x4
                        
                        // Compute joint transforms from animation channels
                        for channel in anim.channels {
                            tr := &instance_joints[channel.local_joint_id]

                            // Check if anim_t is outside the keyframe range


                            // Return the interpolated value of the keyframes
                            // @TODO: This loop sucks
                            for i in 0..<len(channel.keyframes)-1 {
                                now := channel.keyframes[i]
                                next := channel.keyframes[i + 1]
                                if now.time <= anim_t && anim_t < next.time {
                                    // Get interpolation value between two times
                                    // anim_t == (1 - t)a + bt
                                    // anim_t == a - at + bt
                                    // anim_t == a - t(a + b)
                                    // a - anim_t == t(a + b)
                                    // a - anim_t / (a + b) == t
                                    // Obviously this is assuming a linear interpolation, which may not be what we have
                                    interpolation_amount := now.time - anim_t / (now.time + next.time)
                                    switch channel.aspect {
                                        case .Translation: {
                                            //tr^ = transform * tr^       // Transform is premultiplied
                                        }
                                        case .Rotation: {
                                            now_quat := quaternion(w = now.value[0], x = now.value[1], y = now.value[2], z = now.value[3])
                                            next_quat := quaternion(w = next.value[0], x = next.value[1], y = next.value[2], z = next.value[3])
                                            rotation_quat := linalg.quaternion_slerp_f32(now_quat, next_quat, interpolation_amount)
                                            transform := linalg.to_matrix4(rotation_quat)
            
                                            tr^ *= transform            // Rotation is postmultiplied
                                        }
                                        case .Scale: {
                                            //tr^ *= transform            // Scale is postmultiplied
                                        }
                                    }
                                    break
                                } else if anim_t < now.time {
                                    // Clamp to first keyframe
                                    switch channel.aspect {
                                        case .Translation: {
                                            //tr^ = transform * tr^       // Transform is premultiplied
                                        }
                                        case .Rotation: {
                                            now_quat := quaternion(w = now.value[0], x = now.value[1], y = now.value[2], z = now.value[3])
                                            transform := linalg.to_matrix4(now_quat)
            
                                            tr^ *= transform            // Rotation is postmultiplied
                                        }
                                        case .Scale: {
                                            //tr^ *= transform            // Scale is postmultiplied
                                        }
                                    }


                                } else {
                                    // Clamp to last keyframe
                                    switch channel.aspect {
                                        case .Translation: {
                                            //tr^ = transform * tr^       // Transform is premultiplied
                                        }
                                        case .Rotation: {
                                            next_quat := quaternion(w = next.value[0], x = next.value[1], y = next.value[2], z = next.value[3])
                                            transform := linalg.to_matrix4(next_quat)
            
                                            tr^ *= transform            // Rotation is postmultiplied
                                        }
                                        case .Scale: {
                                            //tr^ *= transform            // Scale is postmultiplied
                                        }
                                    }
                                }
                            }
                        }

                        // Premultiply instance joints with inverse bind matrices
                        for i in 0..<len(instance_joints) {
                            joint_transform := &instance_joints[i]
                            joint_transform^ *= renderer.inverse_bind_matrices[u32(i) + mesh.first_inverse_bind_matrix]
                        }
                        // Postmultiply with parent transform
                        for i in 1..<len(instance_joints) {
                            joint_transform := &instance_joints[i]
                            joint_transform^ = instance_joints[renderer.joint_parents[u32(i) + mesh.first_inverse_bind_matrix]] * joint_transform^
                        }

                        // Insert another compute shader dispatch
                        in_pos_ptr := renderer.cpu_uniforms.position_ptr + vk.DeviceAddress(size_of(hlsl.float4) * mesh.gpu_data.static_data.position_offset)

                        // @TODO: use a different buffer for vertex stream-out
                        out_pos_ptr := renderer.cpu_uniforms.position_ptr + vk.DeviceAddress(size_of(hlsl.float4) * mesh.gpu_data.out_positions_offset)
                        
                        joint_ids_ptr := renderer.cpu_uniforms.joint_id_ptr + vk.DeviceAddress(size_of(hlsl.uint4) * mesh.gpu_data.joint_ids_offset)
                        joint_weights_ptr := renderer.cpu_uniforms.joint_weight_ptr + vk.DeviceAddress(size_of(hlsl.float4) * mesh.gpu_data.joint_weights_offset)
                        joint_mats_ptr := renderer.cpu_uniforms.joint_mats_ptr + vk.DeviceAddress(size_of(hlsl.float4x4) * instance_joints_so_far)
                        pcs := ComputeSkinningPushConstants {
                            in_positions = in_pos_ptr,
                            out_positions = out_pos_ptr,
                            joint_ids = joint_ids_ptr,
                            joint_weights = joint_weights_ptr,
                            joint_transforms = joint_mats_ptr,
                            max_vtx_id = mesh.vertices_len - 1
                        }
                        append(&push_constant_batches, pcs)
                        append(&vertex_counts, mesh.vertices_len)

                        // Also add CPUStaticInstance for the skinned output of the compute shader
                        new_cpu_static_instance := CPUStaticInstance {
                            world_from_model = skinned_instance.world_from_model,
                            mesh_handle = mesh.static_mesh_handle,
                            material_handle = skinned_instance.material_handle
                        }
                        append(&renderer.cpu_static_instances, new_cpu_static_instance)

                        // Upload to GPU
                        vkw.sync_write_buffer(&vgd, renderer.joint_matrices_buffer, instance_joints[:], instance_joints_so_far)
                        instance_joints_so_far += mesh.joint_count
                        skinned_verts_so_far += mesh.vertices_len
                    }
                }

                // Record commands related to dispatching compute shader
                comp_cb_idx := vkw.begin_compute_command_buffer(&vgd, renderer.compute_timeline)

                // Bind compute skinning pipeline
                vkw.cmd_bind_compute_pipeline(&vgd, comp_cb_idx, renderer.skinning_pipeline)

                for i in 0..<len(push_constant_batches) {
                    batch := &push_constant_batches[i]
                    vkw.cmd_push_constants_compute(&vgd, comp_cb_idx, batch)

                    GROUP_THREADCOUNT :: 64
                    q, r := math.divmod(vertex_counts[i], GROUP_THREADCOUNT)
                    groups : u32 = q
                    if r != 0 do groups += 1
                    vkw.cmd_dispatch(&vgd, comp_cb_idx, groups, 1, 1)
                }

                // Barrier to sync streamout buffer writes with vertex shader reads
                pos_buf, _ := vkw.get_buffer(&vgd, renderer.positions_buffer)
                vkw.cmd_compute_pipeline_barriers(&vgd, comp_cb_idx, {
                    vkw.Buffer_Barrier {
                        src_stage_mask = {.COMPUTE_SHADER},
                        src_access_mask = {.SHADER_WRITE},
                        dst_stage_mask = {.ALL_COMMANDS},
                        dst_access_mask = {.SHADER_READ},
                        buffer = pos_buf.buffer,
                        offset = 0,
                        size = pos_buf.alloc_info.size
                    }
                }, {})

                // Increment compute timeline semaphore when compute skinning is finished
                vkw.add_signal_op(&vgd, &renderer.compute_sync, renderer.compute_timeline, vgd.frame_count + 1)

                // Have graphics queue wait on compute skinning timeline semaphore
                vkw.add_wait_op(&vgd, &renderer.gfx_sync, renderer.compute_timeline, vgd.frame_count + 1)
                
                vkw.submit_compute_command_buffer(&vgd, comp_cb_idx, &renderer.compute_sync)
            }
    
            gfx_cb_idx := vkw.begin_gfx_command_buffer(&vgd, renderer.gfx_timeline)
            
            // Increment timeline semaphore upon command buffer completion
            vkw.add_signal_op(&vgd, &renderer.gfx_sync, renderer.gfx_timeline, vgd.frame_count + 1)
    
            swapchain_image_idx: u32
            vkw.acquire_swapchain_image(&vgd, &swapchain_image_idx)
            swapchain_image_handle := vgd.swapchain_images[swapchain_image_idx]
    
            // Wait on swapchain image acquire semaphore
            // and signal when we're done drawing on a different semaphore
            vkw.add_wait_op(&vgd, &renderer.gfx_sync, vgd.acquire_semaphores[vkw.in_flight_idx(&vgd)])
            vkw.add_signal_op(&vgd, &renderer.gfx_sync, vgd.present_semaphores[vkw.in_flight_idx(&vgd)])
    
            // Memory barrier between swapchain acquire and rendering
            swapchain_vkimage, _ := vkw.get_image_vkhandle(&vgd, swapchain_image_handle)
            vkw.cmd_gfx_pipeline_barriers(&vgd, gfx_cb_idx, {
                vkw.Image_Barrier {
                    src_stage_mask = {.ALL_COMMANDS},
                    src_access_mask = {.MEMORY_READ},
                    dst_stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
                    dst_access_mask = {.MEMORY_WRITE},
                    old_layout = .UNDEFINED,
                    new_layout = .COLOR_ATTACHMENT_OPTIMAL,
                    src_queue_family = vgd.gfx_queue_family,
                    dst_queue_family = vgd.gfx_queue_family,
                    image = swapchain_vkimage,
                    subresource_range = vk.ImageSubresourceRange {
                        aspectMask = {.COLOR},
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1
                    }
                }
            })

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
    
            // Memory barrier between rendering to swapchain image and swapchain present
            vkw.cmd_gfx_pipeline_barriers(&vgd, gfx_cb_idx, {
                vkw.Image_Barrier {
                    src_stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
                    src_access_mask = {.MEMORY_WRITE},
                    dst_stage_mask = {.ALL_COMMANDS},
                    dst_access_mask = {.MEMORY_READ},
                    old_layout = .COLOR_ATTACHMENT_OPTIMAL,
                    new_layout = .PRESENT_SRC_KHR,
                    src_queue_family = vgd.gfx_queue_family,
                    dst_queue_family = vgd.gfx_queue_family,
                    image = swapchain_vkimage,
                    subresource_range = vk.ImageSubresourceRange {
                        aspectMask = {.COLOR},
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1
                    }
                }
            })
    
            vkw.submit_gfx_command_buffer(&vgd, gfx_cb_idx, &renderer.gfx_sync)
            vkw.present_swapchain_image(&vgd, &swapchain_image_idx)
        }

        // CLear temp allocator for next frame
        free_all(context.temp_allocator)

        // Clear sync info for next frame
        vkw.clear_sync_info(&renderer.gfx_sync)
        vkw.clear_sync_info(&renderer.compute_sync)
        vgd.frame_count += 1

        // CPU limiter
        // 100 mil nanoseconds == 100 milliseconds
        if limit_cpu do time.sleep(time.Duration(1_000_000 * cpu_limiter_ms))
    }

    log.info("Returning from main()")
}
