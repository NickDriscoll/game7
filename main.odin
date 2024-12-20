package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math/linalg/hlsl"
import "core:math"
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

USER_CONFIG_FILE :: "user.cfg"
TITLE_WITHOUT_IMGUI :: "KataWARi"
TITLE_WITH_IMGUI :: "KataWARi -- Press ESC to hide developer GUI"
DEFAULT_RESOLUTION :: hlsl.uint2 {1280, 720}

TEMP_ARENA_SIZE :: 64 * 1024            //Guessing 64KB necessary size for per-frame allocations

IDENTITY_MATRIX :: hlsl.float4x4 {
    1.0, 0.0, 0.0, 0.0,
    0.0, 1.0, 0.0, 0.0,
    0.0, 0.0, 1.0, 0.0,
    0.0, 0.0, 0.0, 1.0,
}

LooseProp :: struct {
    position: hlsl.float3,
    scale: f32,
    mesh_data: MeshData,
}

TerrainPiece :: struct {
    collision: StaticTriangleCollision,
    model_matrix: hlsl.float4x4,
    mesh_data: MeshData,
}

delete_terrain_piece :: proc(using t: ^TerrainPiece) {
    delete_static_triangles(&collision)
}

TestCharacter :: struct {
    collision: Sphere,
    facing: hlsl.float3,
    mesh_data: MeshData,
}

GameState :: struct {
    props: [dynamic]LooseProp,
    terrain_pieces: [dynamic]TerrainPiece,
}

delete_game :: proc(using g: ^GameState) {
    delete(props)
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

    // Set up memory allocators
    per_frame_arena: mem.Arena
    {
        context.allocator = runtime.heap_allocator()

        backing_memory, err := mem.alloc_bytes(TEMP_ARENA_SIZE)
        if err != nil {
            log.error("Error allocating temporary memory backing buffer.")
        }

        mem.arena_init(&per_frame_arena, backing_memory)
        context.temp_allocator = mem.arena_allocator(&per_frame_arena)
    }

    // Load user configuration
    user_config, config_ok := load_user_config(USER_CONFIG_FILE)
    if !config_ok {
        log.warn("Failed to load config file. Generating default config.")
        save_default_user_config(USER_CONFIG_FILE)

        ok2: bool
        user_config, ok2 = load_user_config(USER_CONFIG_FILE)
        if !ok2 {
            log.error("Failed to load freshly generated default config file.")
        }
    }

    // Init input system
    input_state := init_input_state()
    defer destroy_input_state(&input_state)

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
    
    // Make window 
    desktop_display_mode: sdl2.DisplayMode
    if sdl2.GetDesktopDisplayMode(0, &desktop_display_mode) != 0 {
        log.error("Error getting desktop display mode.")
    }
    display_resolution := hlsl.uint2 {
        u32(desktop_display_mode.w),
        u32(desktop_display_mode.h),
    }

    resolution := DEFAULT_RESOLUTION
    if user_config.flags["exclusive_fullscreen"] || user_config.flags["borderless_fullscreen"] do resolution = display_resolution
    if "window_width" in user_config.ints && "window_height" in user_config.ints {
        x := user_config.ints["window_width"]
        y := user_config.ints["window_height"]
        resolution = {u32(x), u32(y)}
    }

    sdl_windowflags : sdl2.WindowFlags = {.VULKAN,.RESIZABLE}
    if user_config.flags["exclusive_fullscreen"] {
        sdl_windowflags += {.FULLSCREEN}
    }
    if user_config.flags["borderless_fullscreen"] {
        sdl_windowflags += {.BORDERLESS}
    }

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

    // Initialize the renderer
    render_data := init_renderer(&vgd, resolution)
    defer delete_renderer(&vgd, &render_data)
    render_data.main_framebuffer.clear_color = {0.1568627, 0.443137, 0.9176471, 1.0}

    //Dear ImGUI init
    imgui_state := imgui_init(&vgd, resolution)
    defer imgui_cleanup(&vgd, &imgui_state)
    ini_savename_buffer: [2048]u8

    // Main app structure storing the game's overall state
    game_state: GameState

    //main_scene_path : cstring = "data/models/sentinel_beach.glb"  // Not working
    //main_scene_path : cstring = "data/models/town_square.glb"
    main_scene_path : cstring = "data/models/artisans.glb"
    //main_scene_path : cstring = "data/models/plane.glb"
    main_scene_mesh := load_gltf_mesh(&vgd, &render_data, main_scene_path)

    // Get collision data out of main scene model
    {
        positions := get_glb_positions(main_scene_path, context.temp_allocator)
        defer delete(positions)
        collision := static_triangle_mesh(positions[:], IDENTITY_MATRIX)
        append(&game_state.terrain_pieces, TerrainPiece {
            collision = collision,
            model_matrix = IDENTITY_MATRIX,
            mesh_data = main_scene_mesh,
        })
    }

    // Load test glTF model
    spyro_mesh: MeshData
    moon_mesh: MeshData
    defer gltf_delete(&spyro_mesh)
    {
        path : cstring = "data/models/spyro2.glb"
        spyro_mesh = load_gltf_mesh(&vgd, &render_data, path)
        path = "data/models/majoras_moon.glb"
        moon_mesh = load_gltf_mesh(&vgd, &render_data, path)
    }
    
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

    // Initialize main viewport camera
    viewport_camera := Camera {
        position = {0.0, -5.0, 60.0},
        yaw = 0.0,
        pitch = math.PI / 4.0,
        fov_radians = math.PI / 2.0,
        aspect_ratio = f32(resolution.x) / f32(resolution.y),
        nearplane = 0.1,
        farplane = 1_000_000_000.0,
        control_flags = nil
    }
    saved_mouse_coords := hlsl.int2 {0, 0}

    // Add loose props to container
    {
        SPACING :: 10.0
        ROWS :: 10
        OFFSET :: -(ROWS/2 * SPACING)
        for y in 0..<ROWS {
            for x in 0..<ROWS {
                my_prop := LooseProp {
                    position = {f32(x) * SPACING + OFFSET, f32(y) * SPACING + OFFSET, 10.0},
                    scale = 1.0,
                    mesh_data = spyro_mesh
                }
                append(&game_state.props, my_prop)
            }
        }
    }

    // Create test character
    character := TestCharacter {
        collision = {
            origin = {0.0, 0.0, 30.0},
            radius = 2.0
        }
    }

    free_all(context.temp_allocator)

    current_time := time.now()
    previous_time := current_time
    window_minimized := false
    limit_cpu := false
    
    log.info("App initialization complete. Entering main loop")

    do_main_loop := true
    for do_main_loop {
        // Time
        current_time = time.now()
        nanosecond_dt := time.diff(previous_time, current_time)
        last_frame_duration := f32(nanosecond_dt / 1000) / 1_000_000
        previous_time = current_time

        io := imgui.GetIO()
        io.DeltaTime = last_frame_duration
        output_verbs := poll_sdl2_events(&input_state)
        io.KeyCtrl = input_state.ctrl_pressed
        
        // Process the app verbs that the input system returned to the game
        camera_rotation: hlsl.float2 = {0.0, 0.0}
        camera_direction: hlsl.float3 = {0.0, 0.0, 0.0}
        camera_speed_mod : f32 = 1.0
        @static camera_sprint_multiplier : f32 = 5.0
        @static camera_slow_multiplier : f32 = 1.0 / 5.0
        {
            for verb in output_verbs.bools {
                #partial switch verb.type {
                    case .Quit: do_main_loop = false
                    case .FocusWindow: window_minimized = false
                    case .MinimizeWindow: window_minimized = true
                    case .ToggleImgui: {
                        if verb.value do imgui_state.show_gui = !imgui_state.show_gui
                    }
                    case .TranslateFreecamBack: {
                        if verb.value do viewport_camera.control_flags += {.MoveBackward}
                        else do viewport_camera.control_flags -= {.MoveBackward}
                    }
                    case .TranslateFreecamForward: {
                        if verb.value do viewport_camera.control_flags += {.MoveForward}
                        else do viewport_camera.control_flags -= {.MoveForward}
                    }
                    case .TranslateFreecamLeft: {
                        if verb.value do viewport_camera.control_flags += {.MoveLeft}
                        else do viewport_camera.control_flags -= {.MoveLeft}
                    }
                    case .TranslateFreecamRight: {
                        if verb.value do viewport_camera.control_flags += {.MoveRight}
                        else do viewport_camera.control_flags -= {.MoveRight}
                    }
                    case .TranslateFreecamDown: {
                        if verb.value do viewport_camera.control_flags += {.MoveDown}
                        else do viewport_camera.control_flags -= {.MoveDown}
                    }
                    case .TranslateFreecamUp: {
                        if verb.value do viewport_camera.control_flags += {.MoveUp}
                        else do viewport_camera.control_flags -= {.MoveUp}
                    }
                    case .Sprint: {
                        if verb.value do viewport_camera.control_flags += {.Speed}
                        else do viewport_camera.control_flags -= {.Speed}
                    }
                    case .Crawl: {
                        if verb.value do viewport_camera.control_flags += {.Slow}
                        else do viewport_camera.control_flags -= {.Slow}
                    }
                }
            }

            for verb in output_verbs.int2s {
                #partial switch verb.type {
                    case .ToggleMouseLook: {
                        mlook := !(.MouseLook in viewport_camera.control_flags)
                        
                        // Do nothing if Dear ImGUI wants mouse input
                        if mlook && io.WantCaptureMouse do continue

                        sdl2.SetRelativeMouseMode(sdl2.bool(mlook))
                        if mlook {
                            saved_mouse_coords.x = i32(verb.value.x)
                            saved_mouse_coords.y = i32(verb.value.y)
                        } else {
                            sdl2.WarpMouseInWindow(sdl_window, saved_mouse_coords.x, saved_mouse_coords.y)
                        }
                        
                        // The ~ is "symmetric difference" for bit_sets
                        // Basically like XOR
                        viewport_camera.control_flags ~= {.MouseLook}
                    }
                    case .MouseMotion: {
                        if .MouseLook not_in viewport_camera.control_flags {
                            imgui.IO_AddMousePosEvent(io, f32(verb.value.x), f32(verb.value.y))
                        }
                            
                    }
                    case .MouseMotionRel: {
                        MOUSE_SENSITIVITY :: 0.001
                        if .MouseLook in viewport_camera.control_flags {
                            camera_rotation += MOUSE_SENSITIVITY * {f32(verb.value.x), f32(verb.value.y)}
                            sdl2.WarpMouseInWindow(sdl_window, saved_mouse_coords.x, saved_mouse_coords.y)
                        }
                    }
                    case .ResizeWindow: {
                        resolution.x = u32(verb.value.x)
                        resolution.y = u32(verb.value.y)
                        vgd.resize_window = true
                    }
                    case .MoveWindow: {
                        user_config.ints["window_x"] = i64(verb.value.x)
                        user_config.ints["window_y"] = i64(verb.value.y)
                    }
                }
            }

            for verb in output_verbs.floats {
                JOYSTICK_SENSITIVITY :: 1
                #partial switch verb.type {
                    case .RotateFreecamX: {
                        camera_rotation.x += JOYSTICK_SENSITIVITY * verb.value
                    }
                    case .RotateFreecamY: {
                        camera_rotation.y += JOYSTICK_SENSITIVITY * verb.value
                    }
                    case .TranslateFreecamX: {
                        camera_direction.x += JOYSTICK_SENSITIVITY * verb.value
                    }
                    case .TranslateFreecamY: {
                        camera_direction.y += JOYSTICK_SENSITIVITY * verb.value
                    }
                    case .Sprint: {
                        camera_speed_mod += camera_sprint_multiplier * verb.value
                    }
                }
            }
        }
        
        imgui.NewFrame()

        // Update

        // Update camera based on user input
        camera_collision_point: hlsl.float3
        camera_collided := false
        {
            using viewport_camera

            CAMERA_SPEED :: 10
            per_frame_speed := CAMERA_SPEED * last_frame_duration

            if .Speed in control_flags do camera_speed_mod *= camera_sprint_multiplier
            if .Slow in control_flags do camera_speed_mod *= camera_slow_multiplier

            viewport_camera.yaw += camera_rotation.x
            viewport_camera.pitch += camera_rotation.y
            for viewport_camera.yaw < -2.0 * math.PI do viewport_camera.yaw += 2.0 * math.PI
            for viewport_camera.yaw > 2.0 * math.PI do viewport_camera.yaw -= 2.0 * math.PI
            if viewport_camera.pitch < -math.PI / 2.0 do viewport_camera.pitch = -math.PI / 2.0
            if viewport_camera.pitch > math.PI / 2.0 do viewport_camera.pitch = math.PI / 2.0

            control_flags_dir: hlsl.float3
            if .MoveForward in control_flags do control_flags_dir += {0.0, 1.0, 0.0}
            if .MoveBackward in control_flags do control_flags_dir += {0.0, -1.0, 0.0}
            if .MoveLeft in control_flags do control_flags_dir += {-1.0, 0.0, 0.0}
            if .MoveRight in control_flags do control_flags_dir += {1.0, 0.0, 0.0}
            if .MoveUp in control_flags do control_flags_dir += {0.0, 0.0, 1.0}
            if .MoveDown in control_flags do control_flags_dir += {0.0, 0.0, -1.0}
            if control_flags_dir != {0.0, 0.0, 0.0} do camera_direction += hlsl.normalize(control_flags_dir)

            if camera_direction != {0.0, 0.0, 0.0} {
                camera_direction = hlsl.float3(camera_speed_mod) * hlsl.float3(per_frame_speed) * camera_direction
            }

            //Compute temporary camera matrix for orienting player inputted direction vector
            world_from_view := hlsl.inverse(camera_view_from_world(&viewport_camera))
            camera_direction4 := hlsl.float4{camera_direction.x, camera_direction.y, camera_direction.z, 0.0}
            viewport_camera.position += (world_from_view * camera_direction4).xyz

            // Collision test the camera's bounding sphere against the terrain
            if user_config.flags["show_closest_point"] || user_config.flags["freecam_collision"] {
                closest_dist := math.INF_F32
                for &piece in game_state.terrain_pieces {
                    candidate := closest_pt_triangles(position, &piece.collision)
                    candidate_dist := hlsl.distance(candidate, position)
                    if candidate_dist < closest_dist {
                        camera_collision_point = candidate
                        closest_dist = candidate_dist
                    }
                }

                if user_config.flags["freecam_collision"] {
                    CAMERA_RADIUS :: 0.8
                    dist := hlsl.distance(camera_collision_point, position)
                    if dist < CAMERA_RADIUS {
                        diff := CAMERA_RADIUS - dist
                        position += diff * hlsl.normalize(position - camera_collision_point)
                        camera_collided = true
                    }
                }
            }
        }

        if user_config.flags["show_closest_point"] {
            for prim in moon_mesh.primitives {
                scale : f32 = 0.1
                draw_ps1_primitive(&vgd, &render_data, prim.mesh, prim.material, &{
                    world_from_model = {
                        scale, 0.0, 0.0, camera_collision_point.x,
                        0.0, scale, 0.0, camera_collision_point.y,
                        0.0, 0.0, scale, camera_collision_point.z,
                        0.0, 0.0, 0.0, 1.0,
                    }
                })
            }
        }


        if imgui_state.show_gui {
            if imgui.BeginMainMenuBar() {
                if imgui.BeginMenu("File") {
                    if imgui.MenuItem("New") {
                        
                    }
                    if imgui.MenuItem("Load") {
                        
                    }
                    if imgui.MenuItem("Save") {
                        
                    }
                    if imgui.MenuItem("Save As") {
                        
                    }
                    if imgui.MenuItem("Save user config") {
                        save_user_config(&user_config, "user.cfg")
                    }
                    if imgui.MenuItem("Exit") do do_main_loop = false

                    imgui.EndMenu()
                }

                if imgui.BeginMenu("Edit") {

                    
                    imgui.EndMenu()
                }

                if imgui.BeginMenu("Config") {
                    if imgui.MenuItem("Input", "porque?") do user_config.flags["input_config"] = !user_config.flags["input_config"]

                    imgui.EndMenu()
                }

                if imgui.BeginMenu("Window") {
                    if imgui.MenuItem("Always On Top", selected = bool(user_config.flags["always_on_top"])) {
                        user_config.flags["always_on_top"] = !user_config.flags["always_on_top"]
                        sdl2.SetWindowAlwaysOnTop(sdl_window, sdl2.bool(user_config.flags["always_on_top"]))
                    }

                    if imgui.MenuItem("Borderless Fullscreen", selected = user_config.flags["borderless_fullscreen"]) {
                        user_config.flags["borderless_fullscreen"] = !user_config.flags["borderless_fullscreen"]
                        user_config.flags["exclusive_fullscreen"] = false
                        
                        user_config.ints["window_x"] = 0
                        user_config.ints["window_y"] = 0

                        xpos, ypos: c.int
                        if user_config.flags["borderless_fullscreen"] {
                            resolution = display_resolution
                        }
                        else {
                            resolution = DEFAULT_RESOLUTION
                            xpos = c.int(display_resolution.x / 2 - DEFAULT_RESOLUTION.x / 2)
                            ypos = c.int(display_resolution.y / 2 - DEFAULT_RESOLUTION.y / 2)
                        }

                        io.DisplaySize.x = f32(resolution.x)
                        io.DisplaySize.y = f32(resolution.y)

                        vgd.resize_window = true
                        sdl2.SetWindowBordered(sdl_window, !user_config.flags["borderless_fullscreen"])
                        sdl2.SetWindowPosition(sdl_window, xpos, ypos)
                        sdl2.SetWindowSize(sdl_window, c.int(resolution.x), c.int(resolution.y))
                        sdl2.SetWindowResizable(sdl_window, true)
                    }
                    
                    if imgui.MenuItem("Exclusive Fullscreen", selected = user_config.flags["exclusive_fullscreen"]) {
                        user_config.flags["exclusive_fullscreen"] = !user_config.flags["exclusive_fullscreen"]
                        user_config.flags["borderless_fullscreen"] = false
                        
                        user_config.ints["window_x"] = 0
                        user_config.ints["window_y"] = 0

                        flags : sdl2.WindowFlags = nil
                        resolution = DEFAULT_RESOLUTION
                        if user_config.flags["exclusive_fullscreen"] do flags += {.FULLSCREEN}
                        if user_config.flags["exclusive_fullscreen"] do resolution = display_resolution

                        io.DisplaySize.x = f32(resolution.x)
                        io.DisplaySize.y = f32(resolution.y)

                        sdl2.SetWindowSize(sdl_window, c.int(resolution.x), c.int(resolution.y))
                        sdl2.SetWindowFullscreen(sdl_window, flags)
                        sdl2.SetWindowResizable(sdl_window, true)
                        vgd.resize_window = true
                    }

                    imgui.EndMenu()
                }

                if imgui.BeginMenu("Debug") {
                    if imgui.MenuItem("Show Dear ImGUI demo window", selected = user_config.flags["show_imgui_demo"]) {
                        user_config.flags["show_imgui_demo"] = !user_config.flags["show_imgui_demo"]
                    }
                    if imgui.MenuItem("Show debug window", selected = user_config.flags["show_debug_menu"]) {
                        user_config.flags["show_debug_menu"] = !user_config.flags["show_debug_menu"]
                    }

                    imgui.EndMenu()
                }
                
                imgui.EndMainMenuBar()
            }

            // Make viewport-sized dockspace
            {
                dock_window_flags := imgui.WindowFlags {
                    .NoTitleBar,
                    .NoMove,
                    .NoResize,
                    .NoBackground,
                    .NoMouseInputs
                }
                window_viewport := imgui.GetWindowViewport()
                imgui.SetNextWindowPos(window_viewport.WorkPos)
                imgui.SetNextWindowSize(window_viewport.WorkSize)
                if imgui.Begin("Main dock window", flags = dock_window_flags) {
                    id := imgui.GetID("Main dockspace")
                    flags := imgui.DockNodeFlags {
                        .NoDockingOverCentralNode,
                        .PassthruCentralNode,
                    }
                    imgui.DockSpaceOverViewport(id, window_viewport, flags = flags)
                }
                imgui.End()
            }

            {
                using viewport_camera

                if user_config.flags["show_debug_menu"] {
                    if imgui.Begin("Hacking window", &user_config.flags["show_debug_menu"]) {
                        imgui.Text("Frame #%i", vgd.frame_count)
                        imgui.Text("Camera position: (%f, %f, %f)", position.x, position.y, position.z)
                        imgui.Text("Camera direction: (%f, %f, %f)", camera_direction.x, camera_direction.y, camera_direction.z)
                        imgui.Text("Camera yaw: %f", yaw)
                        imgui.Text("Camera pitch: %f", pitch)
                        imgui.SliderFloat("Camera fast speed", &camera_sprint_multiplier, 0.0, 100.0)
                        imgui.SliderFloat("Camera slow speed", &camera_slow_multiplier, 0.0, 1.0/5.0)
                        imgui.Checkbox("Show closest point on terrain to camera", &user_config.flags["show_closest_point"])
                        imgui.Checkbox("Enable freecam collision", &user_config.flags["freecam_collision"])
                        imgui.Separator()
                        imgui.SliderFloat("Distortion Strength", &render_data.cpu_uniforms.distortion_strength, 0.0, 1.0)

                        imgui.ColorPicker4("Clear color", (^[4]f32)(&render_data.main_framebuffer.clear_color), {.NoPicker})
                        
                        imgui.Checkbox("Enable CPU Limiter", &limit_cpu)
                        imgui.SameLine()
                        HelpMarker(
                            "Enabling this setting forces the main thread " +
                            "to sleep for 100 milliseconds at the end of the main loop, " +
                            "effectively capping the framerate to 10 FPS"
                        )
                        
                        imgui.Separator()
    
                        ini_cstring := cstring(&ini_savename_buffer[0])
                        imgui.Text("Save current configuration of Dear ImGUI windows")
                        imgui.InputText(".ini filename", ini_cstring, len(ini_savename_buffer))
                        if imgui.Button("Save current GUI configuration") {
                            imgui.SaveIniSettingsToDisk(ini_cstring)
                            log.debugf("Saved Dear ImGUI ini settings to \"%v\"", ini_cstring)
                            ini_savename_buffer = {}
                        }
                    }
                    imgui.End()
                } 
            }

            if "input_config" in user_config.flags {
                if user_config.flags["input_config"] do input_gui(&input_state, &user_config.flags["input_config"])
            }

            // if imgui.Begin("3D viewport") {
            //     handle := render_data.main_framebuffer.color_images[0]
            //     color_image, ok := vkw.get_image(&vgd, handle)
            //     if !ok {
            //         log.error("Couldn't get framebuffer color image.")
            //     }
            //     imgui.Image(hm.handle_to_rawptr(handle), {f32(color_image.extent.width), f32(color_image.extent.height)})
            // }
            // imgui.End()

            if user_config.flags["show_imgui_demo"] do imgui.ShowDemoWindow(&user_config.flags["show_imgui_demo"])
            sdl2.SetWindowTitle(sdl_window, TITLE_WITH_IMGUI)
        } else {
            sdl2.SetWindowTitle(sdl_window, TITLE_WITHOUT_IMGUI)
        }

        // Draw terrain pieces
        for piece in game_state.terrain_pieces {
            tform := DrawData {
                world_from_model = piece.model_matrix
            }
            for prim in piece.mesh_data.primitives {
                draw_ps1_primitive(
                    &vgd,
                    &render_data,
                    prim.mesh,
                    prim.material,
                    &tform
                )
            }
        }

        // Draw loose props
        for prop, i in game_state.props {
            zpos := prop.position.z
            transform := DrawData {
                world_from_model = {
                    prop.scale, 0.0, 0.0, prop.position.x,
                    0.0, prop.scale, 0.0, prop.position.y,
                    0.0, 0.0, prop.scale, zpos,
                    0.0, 0.0, 0.0, 1.0,
                }
            }

            // Render prop's primitives
            for prim in prop.mesh_data.primitives {
                draw_ps1_primitive(
                    &vgd,
                    &render_data,
                    prim.mesh,
                    prim.material,
                    &transform
                )
            }
        }

        // Draw test character
        for prim in character.mesh_data.primitives {
            ddata := DrawData {
                world_from_model = IDENTITY_MATRIX
            }
            ddata.world_from_model[3][0] = character.collision.origin.x
            ddata.world_from_model[3][1] = character.collision.origin.y
            ddata.world_from_model[3][2] = character.collision.origin.z
            draw_ps1_primitive(&vgd, &render_data, prim.mesh, prim.material, &ddata)
        }

        imgui.EndFrame()

        // Render
        if !window_minimized {
            // Increment timeline semaphore upon command buffer completion
            vkw.add_signal_op(&vgd, &render_data.gfx_sync_info, render_data.gfx_timeline, vgd.frame_count + 1)

            // Resize swapchain if necessary
            if vgd.resize_window {
                if !vkw.resize_window(&vgd, resolution) do log.error("Failed to resize window")
                resize_framebuffers(&vgd, &render_data, resolution)
                viewport_camera.aspect_ratio = f32(resolution.x) / f32(resolution.y)
                user_config.ints["window_width"] = i64(resolution.x)
                user_config.ints["window_height"] = i64(resolution.y)
                io.DisplaySize.x = f32(resolution.x)
                io.DisplaySize.y = f32(resolution.y)

                vgd.resize_window = false
            }
    
            gfx_cb_idx := vkw.begin_gfx_command_buffer(&vgd, &render_data.gfx_sync_info, render_data.gfx_timeline)
    
            swapchain_image_idx: u32
            vkw.acquire_swapchain_image(&vgd, &swapchain_image_idx)
            swapchain_image_handle := vgd.swapchain_images[swapchain_image_idx]
    
            // Wait on swapchain image acquire semaphore
            // and signal when we're done drawing on a different semaphore
            append(&render_data.gfx_sync_info.wait_ops, vkw.Semaphore_Op {
                semaphore = vgd.acquire_semaphores[vkw.in_flight_idx(&vgd)]
            })
            append(&render_data.gfx_sync_info.signal_ops, vkw.Semaphore_Op {
                semaphore = vgd.present_semaphores[vkw.in_flight_idx(&vgd)]
            })
    
            // Memory barrier between image acquire and rendering
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
    
            framebuffer: vkw.Framebuffer
            framebuffer.color_images[0] = swapchain_image_handle
            framebuffer.depth_image = {generation = NULL_OFFSET, index = NULL_OFFSET}
            framebuffer.resolution.x = u32(resolution.x)
            framebuffer.resolution.y = u32(resolution.y)
            framebuffer.color_load_op = .CLEAR

            // Main render call
            render(&vgd, gfx_cb_idx, &render_data, &viewport_camera, &framebuffer)
            
            // Draw Dear Imgui
            framebuffer.color_load_op = .LOAD
            vkw.cmd_begin_render_pass(&vgd, gfx_cb_idx, &framebuffer)
            render_imgui(&vgd, gfx_cb_idx, &imgui_state)
            vkw.cmd_end_render_pass(&vgd, gfx_cb_idx)
    
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
    
            vkw.submit_gfx_command_buffer(&vgd, gfx_cb_idx, &render_data.gfx_sync_info)
            vkw.present_swapchain_image(&vgd, &swapchain_image_idx)
        }

        // CLear temp allocator for next frame
        free_all(context.temp_allocator)

        // Clear sync info for next frame
        vkw.clear_sync_info(&render_data.gfx_sync_info)
        vgd.frame_count += 1

        // CPU limiter
        // 100 mil nanoseconds == 100 milliseconds
        if limit_cpu do time.sleep(time.Duration(1_000_000 * 100))
    }

    log.info("Returning from main()")
}
