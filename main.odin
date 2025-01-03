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

USER_CONFIG_FILENAME :: "user.cfg"
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

CharacterState :: enum {
    Grounded,
    Falling
}

TestCharacter :: struct {
    collision: Sphere,
    state: CharacterState,
    velocity: hlsl.float3,
    facing: hlsl.float3,
    mesh_data: MeshData,
}

GameState :: struct {
    character: TestCharacter,
    viewport_camera: Camera,
    props: [dynamic]LooseProp,
    terrain_pieces: [dynamic]TerrainPiece,

    freecam_collision: bool,
    borderless_fullscreen: bool,
    exclusive_fullscreen: bool
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

    // Set up global allocator
    context.allocator = runtime.heap_allocator()
    when ODIN_DEBUG == true {
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
    user_config, config_ok := load_user_config(USER_CONFIG_FILENAME)
    if !config_ok do log.error("Failed to load user config.")
    defer delete_user_config(&user_config, context.allocator)

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

    // Init input system
    input_system := init_input_system()
    defer destroy_input_system(&input_system)

    // Initialize the renderer
    render_data := init_renderer(&vgd, resolution)
    defer delete_renderer(&vgd, &render_data)
    render_data.main_framebuffer.clear_color = {0.1568627, 0.443137, 0.9176471, 1.0}

    //Dear ImGUI init
    imgui_state := imgui_init(&vgd, resolution)
    defer imgui_cleanup(&vgd, &imgui_state)
    ini_savename_buffer: [2048]u8
    if imgui_state.show_gui {
        sdl2.SetWindowTitle(sdl_window, TITLE_WITH_IMGUI)
    }

    //main_scene_path : cstring = "data/models/sentinel_beach.glb"  // Not working
    //main_scene_path : cstring = "data/models/town_square.glb"
    main_scene_path : cstring = "data/models/artisans.glb"
    //main_scene_path : cstring = "data/models/plane.glb"
    main_scene_mesh := load_gltf_mesh(&vgd, &render_data, main_scene_path)
    defer gltf_delete(&main_scene_mesh)

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
    defer gltf_delete(&moon_mesh)
    {
        path : cstring = "data/models/spyro2.glb"
        //path : cstring = "data/models/klonoa2.glb"
        spyro_mesh = load_gltf_mesh(&vgd, &render_data, path)
        path = "data/models/majoras_moon.glb"
        moon_mesh = load_gltf_mesh(&vgd, &render_data, path)
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

    game_state.character = TestCharacter {
        collision = {
            origin = {0.0, 0.0, 30.0},
            radius = 2.0
        },
        velocity = {},
        state = .Falling,
        facing = {0.0, 1.0, 0.0},
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
        control_flags = nil
    }
    log.debug(game_state.viewport_camera)
    saved_mouse_coords := hlsl.int2 {0, 0}

    free_all(context.temp_allocator)

    current_time := time.now()          // Time in nanoseconds since UNIX epoch
    previous_time := current_time
    limit_cpu := false
    timescale : f32 = 1.0
    
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
        
        output_verbs := poll_sdl2_events(&input_system)
        io.KeyCtrl = input_system.ctrl_pressed

        // Quit if user wants it
        if output_verbs.bools[.Quit] do do_main_loop = false
        
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
            if ok {
                if mlook_coords == {0, 0} do continue
                mlook := !(.MouseLook in game_state.viewport_camera.control_flags)
                // Do nothing if Dear ImGUI wants mouse input
                if mlook && io.WantCaptureMouse do continue
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

            mmotion_coords, ok2 := output_verbs.int2s[.MouseMotion]
            if ok2 {
                if .MouseLook not_in game_state.viewport_camera.control_flags {
                    imgui.IO_AddMousePosEvent(io, f32(mmotion_coords.x), f32(mmotion_coords.y))
                }
            }
        }
        
        begin_gui(&imgui_state)

        // Update

        // Update camera based on user input
        {
            using game_state.viewport_camera

            camera_rotation: hlsl.float2 = {0.0, 0.0}
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
                MOUSE_SENSITIVITY :: 0.002
                if .MouseLook in game_state.viewport_camera.control_flags {
                    camera_rotation += MOUSE_SENSITIVITY * {f32(relmotion_coords.x), f32(relmotion_coords.y)}
                    sdl2.WarpMouseInWindow(sdl_window, saved_mouse_coords.x, saved_mouse_coords.y)
                }
            }

            camera_rotation.x += output_verbs.floats[.RotateFreecamX]
            camera_rotation.y += output_verbs.floats[.RotateFreecamY]
            camera_direction.x += output_verbs.floats[.TranslateFreecamX]
            camera_direction.y += output_verbs.floats[.TranslateFreecamY]
            camera_speed_mod += camera_sprint_multiplier * output_verbs.floats[.Sprint]


            CAMERA_SPEED :: 10
            per_frame_speed := CAMERA_SPEED * last_frame_duration

            if .Speed in control_flags do camera_speed_mod *= camera_sprint_multiplier
            if .Slow in control_flags do camera_speed_mod *= camera_slow_multiplier

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
                    CAMERA_RADIUS :: 0.8
                    dist := hlsl.distance(camera_collision_point, position)
                    if dist < CAMERA_RADIUS {
                        diff := CAMERA_RADIUS - dist
                        position += diff * hlsl.normalize(position - camera_collision_point)
                    }
                }
            }
        }

        // Update player character
        {
            using game_state

            GRAVITY_ACCELERATION :: -9.8        // m/s^2
            TERMINAL_VELOCITY :: -16.0           // m/s

            // TEST CODE PLZ REMOVE
            place_thing_screen_coords, ok2 := output_verbs.int2s[.PlaceThing]
            if ok2 && place_thing_screen_coords != {0, 0} {
                tan_fovy := math.tan(game_state.viewport_camera.fov_radians / 2.0)
                tan_fovx := tan_fovy * f32(resolution.x) / f32(resolution.y)
                screen_coords: [2]c.int
                sdl2.GetMouseState(&screen_coords.x, &screen_coords.y)
                clip_coords := hlsl.float4 {
                    f32(screen_coords.x) * 2.0 / f32(resolution.x) - 1.0,
                    f32(screen_coords.y) * 2.0 / f32(resolution.y) - 1.0,
                    1.0,
                    1.0
                }
                view_coords := hlsl.float4 {
                    clip_coords.x * game_state.viewport_camera.nearplane * tan_fovx,
                    -clip_coords.y * game_state.viewport_camera.nearplane * tan_fovy,
                    -game_state.viewport_camera.nearplane,
                    1.0
                }
                world_coords := hlsl.inverse(camera_view_from_world(&game_state.viewport_camera)) * view_coords

                ray_start := hlsl.float3 {world_coords.x, world_coords.y, world_coords.z}
                ray := Ray {
                    start = ray_start,
                    direction = hlsl.normalize(ray_start - game_state.viewport_camera.position)
                }

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

                if closest_dist < math.INF_F32 do character.collision.origin = collision_pt
            }
            
            // switch character.state {
            //     case .Grounded: {

            //     }
            //     case .Falling: {
            //         character.velocity.z += timescale * last_frame_duration * GRAVITY_ACCELERATION
            //         if character.velocity.z < TERMINAL_VELOCITY {
            //             character.velocity.z = TERMINAL_VELOCITY
            //         }
            //         character.collision.origin += timescale * last_frame_duration * character.velocity
            //     }
            // }

            // Snap character to ground if close enough
            {

            }
        }

        if imgui_state.show_gui {
            main_menu_bar(&imgui_state, &game_state, &user_config)
            // if imgui.BeginMainMenuBar() {
            //     if imgui.BeginMenu("File") {
            //         if imgui.MenuItem("New") {
                        
            //         }
            //         if imgui.MenuItem("Load") {
                        
            //         }
            //         if imgui.MenuItem("Save") {
                        
            //         }
            //         if imgui.MenuItem("Save As") {
                        
            //         }
            //         if imgui.MenuItem("Save user config") {
            //             update_user_cfg_camera(&user_config, &game_state.viewport_camera)
            //             save_user_config(&user_config, USER_CONFIG_FILENAME)
            //         }
            //         if imgui.MenuItem("Exit") do do_main_loop = false

            //         imgui.EndMenu()
            //     }

            //     if imgui.BeginMenu("Edit") {

                    
            //         imgui.EndMenu()
            //     }

            //     if imgui.BeginMenu("Config") {
            //         if imgui.MenuItem("Input", "porque?") do user_config.flags["input_config"] = !user_config.flags["input_config"]

            //         imgui.EndMenu()
            //     }

            //     if imgui.BeginMenu("Window") {
            //         if imgui.MenuItem("Always On Top", selected = bool(user_config.flags["always_on_top"])) {
            //             user_config.flags["always_on_top"] = !user_config.flags["always_on_top"]
            //             sdl2.SetWindowAlwaysOnTop(sdl_window, sdl2.bool(user_config.flags["always_on_top"]))
            //         }

            //         if imgui.MenuItem("Borderless Fullscreen", selected = game_state.borderless_fullscreen) {
            //             game_state.borderless_fullscreen = !game_state.borderless_fullscreen
            //             game_state.exclusive_fullscreen = false
                        
            //             user_config.ints["window_x"] = 0
            //             user_config.ints["window_y"] = 0

            //             xpos, ypos: c.int
            //             if game_state.borderless_fullscreen {
            //                 resolution = display_resolution
            //             }
            //             else {
            //                 resolution = DEFAULT_RESOLUTION
            //                 xpos = c.int(display_resolution.x / 2 - DEFAULT_RESOLUTION.x / 2)
            //                 ypos = c.int(display_resolution.y / 2 - DEFAULT_RESOLUTION.y / 2)
            //             }

            //             io.DisplaySize.x = f32(resolution.x)
            //             io.DisplaySize.y = f32(resolution.y)

            //             vgd.resize_window = true
            //             sdl2.SetWindowBordered(sdl_window, !game_state.borderless_fullscreen)
            //             sdl2.SetWindowPosition(sdl_window, xpos, ypos)
            //             sdl2.SetWindowSize(sdl_window, c.int(resolution.x), c.int(resolution.y))
            //             sdl2.SetWindowResizable(sdl_window, true)

            //             // Update config map
            //             user_config.flags[BORDERLESS_FULLSCREEN_KEY] = game_state.borderless_fullscreen
            //         }
                    
            //         if imgui.MenuItem("Exclusive Fullscreen", selected = game_state.exclusive_fullscreen) {
            //             game_state.exclusive_fullscreen = !game_state.exclusive_fullscreen
            //             game_state.borderless_fullscreen = false
                        
            //             user_config.ints["window_x"] = 0
            //             user_config.ints["window_y"] = 0

            //             flags : sdl2.WindowFlags = nil
            //             resolution = DEFAULT_RESOLUTION
            //             if game_state.exclusive_fullscreen {
            //                 flags += {.FULLSCREEN}
            //                 resolution = display_resolution
            //             }

            //             io.DisplaySize.x = f32(resolution.x)
            //             io.DisplaySize.y = f32(resolution.y)

            //             sdl2.SetWindowSize(sdl_window, c.int(resolution.x), c.int(resolution.y))
            //             sdl2.SetWindowFullscreen(sdl_window, flags)
            //             sdl2.SetWindowResizable(sdl_window, true)
            //             vgd.resize_window = true

            //             // Update config map
            //             user_config.flags[EXCLUSIVE_FULLSCREEEN_KEY] = game_state.exclusive_fullscreen
            //         }

            //         imgui.EndMenu()
            //     }

            //     if imgui.BeginMenu("Debug") {
            //         if imgui.MenuItem("Show Dear ImGUI demo window", selected = user_config.flags["show_imgui_demo"]) {
            //             user_config.flags["show_imgui_demo"] = !user_config.flags["show_imgui_demo"]
            //         }
            //         if imgui.MenuItem("Show debug window", selected = user_config.flags["show_debug_menu"]) {
            //             user_config.flags["show_debug_menu"] = !user_config.flags["show_debug_menu"]
            //         }

            //         imgui.EndMenu()
            //     }
                
            //     imgui.EndMainMenuBar()
            // }

            // Misc window
            {
                using game_state.viewport_camera

                if user_config.flags["show_debug_menu"] {
                    if imgui.Begin("Hacking window", &user_config.flags["show_debug_menu"]) {
                        imgui.Text("Frame #%i", vgd.frame_count)
                        imgui.Text("Camera position: (%f, %f, %f)", position.x, position.y, position.z)
                        imgui.Text("Camera yaw: %f", yaw)
                        imgui.Text("Camera pitch: %f", pitch)
                        imgui.SliderFloat("Camera fast speed", &camera_sprint_multiplier, 0.0, 100.0)
                        imgui.SliderFloat("Camera slow speed", &camera_slow_multiplier, 0.0, 1.0/5.0)
                        if imgui.Checkbox("Enable freecam collision", &game_state.freecam_collision) {
                            user_config.flags["freecam_collision"] = game_state.freecam_collision
                        }
                        imgui.Separator()
                        imgui.SliderFloat("Distortion Strength", &render_data.cpu_uniforms.distortion_strength, 0.0, 1.0)
                        imgui.SliderFloat("Timescale", &timescale, 0.0, 2.0)
                        imgui.SameLine()
                        if imgui.Button("Reset") do timescale = 1.0
                        
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

            // Input remapping GUI
            if user_config.flags["input_config"] do input_gui(&input_system, &user_config.flags["input_config"])

            // if imgui.Begin("3D viewport") {
            //     handle := render_data.main_framebuffer.color_images[0]
            //     color_image, ok := vkw.get_image(&vgd, handle)
            //     if !ok {
            //         log.error("Couldn't get framebuffer color image.")
            //     }
            //     imgui.Image(hm.handle_to_rawptr(handle), {f32(color_image.extent.width), f32(color_image.extent.height)})
            // }
            // imgui.End()

            // Imgui Demo
            if user_config.flags["show_imgui_demo"] do imgui.ShowDemoWindow(&user_config.flags["show_imgui_demo"])
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
        for &prop, i in game_state.props {
            zpos := prop.position.z
            transform := DrawData {
                world_from_model = {
                    prop.scale, 0.0, 0.0, prop.position.x,
                    0.0, prop.scale, 0.0, prop.position.y,
                    0.0, 0.0, prop.scale, zpos,
                    0.0, 0.0, 0.0, 1.0,
                }
            }
            draw_ps1_mesh(&vgd, &render_data, &prop.mesh_data, &transform)
        }

        // Draw test character
        {
            scale : f32 = 1.0
            ddata := DrawData {
                world_from_model = uniform_scaling_matrix(scale)
            }
            ddata.world_from_model[3][0] = game_state.character.collision.origin.x
            ddata.world_from_model[3][1] = game_state.character.collision.origin.y
            ddata.world_from_model[3][2] = game_state.character.collision.origin.z

            draw_ps1_mesh(&vgd, &render_data, &game_state.character.mesh_data, &ddata)
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
            // Increment timeline semaphore upon command buffer completion
            vkw.add_signal_op(&vgd, &render_data.gfx_sync_info, render_data.gfx_timeline, vgd.frame_count + 1)

            // Resize swapchain if necessary
            if vgd.resize_window {
                if !vkw.resize_window(&vgd, resolution) do log.error("Failed to resize window")
                resize_framebuffers(&vgd, &render_data, resolution)
                game_state.viewport_camera.aspect_ratio = f32(resolution.x) / f32(resolution.y)
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
            render(&vgd, gfx_cb_idx, &render_data, &game_state.viewport_camera, &framebuffer)
            
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
