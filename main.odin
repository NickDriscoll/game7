package main

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

TITLE_WITHOUT_IMGUI :: "KataWARi"
TITLE_WITH_IMGUI :: "KataWARi -- Press ESC to hide developer GUI"

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
                            log_level
                        )
                    }
                }
            }
        }
    }
    
    // Set up Odin context
    context.logger = log.create_console_logger(log_level)
    log.info("Initiating swag mode...")

    // Initialize SDL2
    sdl2.Init({.EVENTS, .GAMECONTROLLER, .VIDEO})
    defer sdl2.Quit()
    log.info("Initialized SDL2")

    // Open game controller input
    controller_one: ^sdl2.GameController
    defer if controller_one != nil do sdl2.GameControllerClose(controller_one)
    
    // Use SDL2 to dynamically link against the Vulkan loader
    // This allows sdl2.Vulkan_GetVkGetInstanceProcAddr() to return a real address
    if sdl2.Vulkan_LoadLibrary(nil) != 0 {
        log.fatal("Couldn't load Vulkan library.")
    }
    
    // Initialize graphics device
    init_params := vkw.Init_Parameters {
        app_name = "Game7",
        api_version = .Vulkan13,
        frames_in_flight = FRAMES_IN_FLIGHT,
        window_support = true,
        vk_get_instance_proc_addr = sdl2.Vulkan_GetVkGetInstanceProcAddr()
    }
    vgd := vkw.init_vulkan(&init_params)
    
    // Make window
    resolution: hlsl.uint2
    resolution.x = 1920
    resolution.y = 1080
    sdl_windowflags : sdl2.WindowFlags = {.VULKAN,.RESIZABLE}
    sdl_window := sdl2.CreateWindow(TITLE_WITHOUT_IMGUI, sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, i32(resolution.x), i32(resolution.y), sdl_windowflags)
    defer sdl2.DestroyWindow(sdl_window)

    // Initialize the state required for rendering to the window
    if !vkw.init_sdl2_window(&vgd, sdl_window) {
        log.fatal("Couldn't init SDL2 surface.")
    }

    // Initialize the renderer
    render_data := init_renderer(&vgd, resolution)
    defer delete_renderer(&vgd, &render_data)

    //Dear ImGUI init
    imgui_state := imgui_init(&vgd, resolution)
    defer imgui_cleanup(&vgd, &imgui_state)

    // Load test glTF model
    my_gltf_mesh: [dynamic]DrawPrimitive
    defer delete(my_gltf_mesh)
    {
        path : cstring = "data/models/spyro2.glb"
        my_gltf_mesh = load_gltf_mesh(&vgd, &render_data, path)
    }
    spyro_pos := hlsl.float3 {0.0, 0.0, 0.0}

    main_scene_path : cstring = "data/models/town_square.glb"
    //main_scene_path : cstring = "data/models/artisans.glb"
    //main_scene_path : cstring = "data/models/sentinel_beach.glb"  // Not working
    main_scene_mesh := load_gltf_mesh(&vgd, &render_data, main_scene_path)
    
    log.info("App initialization complete")

    // Initialize main viewport camera
    viewport_camera := Camera {
        position = {0.0, -5.0, 10.0},
        yaw = 0.0,
        pitch = math.PI / 4.0,
        fov_radians = math.PI / 2.0,
        aspect_ratio = f32(resolution.x) / f32(resolution.y),
        nearplane = 0.1,
        farplane = 1_000_000_000.0
    }
    saved_mouse_coords := hlsl.int2 {0, 0}

    free_all(context.temp_allocator)

    move_spyro := false
    current_time := time.now()
    previous_time: time.Time
    do_main_loop := true
    for do_main_loop {
        // Time
        current_time = time.now()
        elapsed_time := time.diff(previous_time, current_time)
        previous_time = current_time
        if vgd.frame_count % 1800 == 0 do log.debugf("elapsed_time: %v", elapsed_time)

        imgui.NewFrame()

        // Process system events
        camera_rotation: hlsl.float2 = {0.0, 0.0}
        {
            using viewport_camera
            io := imgui.GetIO()
            io.DeltaTime = f32(elapsed_time) / 1_000_000_000.0

            event: sdl2.Event
            for sdl2.PollEvent(&event) {
                #partial switch event.type {
                    case .QUIT: do_main_loop = false
                    case .WINDOWEVENT: {
                        #partial switch (event.window.event) {
                            case .RESIZED: {
                                new_x := event.window.data1
                                new_y := event.window.data2

                                resolution.x = u32(new_x)
                                resolution.y = u32(new_y)

                                io.DisplaySize.x = f32(new_x)
                                io.DisplaySize.y = f32(new_y)

                                vgd.resize_window = true
                            }
                        }
                    }
                    case .KEYDOWN: {
                        #partial switch event.key.keysym.sym {
                            case .ESCAPE: imgui_state.show_gui = !imgui_state.show_gui
                            case .SPACE: move_spyro = true
                            case .W: control_flags += {.MoveForward}
                            case .S: control_flags += {.MoveBackward}
                            case .A: control_flags += {.MoveLeft}
                            case .D: control_flags += {.MoveRight}
                            case .Q: control_flags += {.MoveDown}
                            case .E: control_flags += {.MoveUp}
                        }

                        #partial switch event.key.keysym.scancode {
                            case .LSHIFT: control_flags += {.Speed}
                            case .LCTRL: control_flags += {.Slow}
                        }
                        imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.sym), true)
                    }
                    case .KEYUP: {
                        #partial switch event.key.keysym.sym {
                            case .SPACE: move_spyro = false
                            case .W: control_flags -= {.MoveForward}
                            case .S: control_flags -= {.MoveBackward}
                            case .A: control_flags -= {.MoveLeft}
                            case .D: control_flags -= {.MoveRight}
                            case .Q: control_flags -= {.MoveDown}
                            case .E: control_flags -= {.MoveUp}
                        }

                        #partial switch event.key.keysym.scancode {
                            case .LSHIFT: control_flags -= {.Speed}
                            case .LCTRL: control_flags -= {.Slow}
                        }
                        imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.sym), false)
                    }
                    case .MOUSEBUTTONDOWN: {
                        switch event.button.button {
                            case sdl2.BUTTON_LEFT: {
                            }
                            case sdl2.BUTTON_RIGHT: {
                                // The ~ is "symmetric difference" for bit_sets
                                // Basically like XOR
                                control_flags ~= {.MouseLook}
                                mlook := .MouseLook in control_flags

                                sdl2.SetRelativeMouseMode(sdl2.bool(mlook))
                                if mlook {
                                    saved_mouse_coords.x = event.button.x
                                    saved_mouse_coords.y = event.button.y
                                } else {
                                    sdl2.WarpMouseInWindow(sdl_window, saved_mouse_coords.x, saved_mouse_coords.y)
                                }
                            }
                        }
                        imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), true)
                    }
                    case .MOUSEBUTTONUP: {
                        imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), false)
                    }
                    case .MOUSEMOTION: {
                        camera_rotation.x += f32(event.motion.xrel)
                        camera_rotation.y += f32(event.motion.yrel)
                        if .MouseLook not_in control_flags {
                            imgui.IO_AddMousePosEvent(io, f32(event.motion.x), f32(event.motion.y))
                        }
                    }
                    case .MOUSEWHEEL: {
                        imgui.IO_AddMouseWheelEvent(io, f32(event.wheel.x), f32(event.wheel.y))
                    }
                    case .CONTROLLERDEVICEADDED: {
                        controller_idx := event.cdevice.which
                        controller_one = sdl2.GameControllerOpen(controller_idx)
                        log.debugf("Controller %v connected.", controller_idx)
                    }
                    case .CONTROLLERDEVICEREMOVED: {
                        controller_idx := event.cdevice.which
                        if controller_idx == 0 {
                            sdl2.GameControllerClose(controller_one)
                            controller_one = nil
                        }
                        log.debugf("Controller %v removed.", controller_idx)
                    }
                    case .CONTROLLERBUTTONDOWN: {
                        fmt.println(sdl2.GameControllerGetStringForButton(sdl2.GameControllerButton(event.cbutton.button)))
                        if sdl2.GameControllerRumble(controller_one, 0xFFFF, 0xFFFF, 500) != 0 {
                            log.error("Rumble not supported!")
                        }
                    }
                }
            }
        }

        // Update

        // Update camera based on user input
        {
            using viewport_camera

            CAMERA_SPEED :: 0.1

            speed_mod := 1.0
            if .Speed in control_flags do speed_mod *= 5.0
            if .Slow in control_flags do speed_mod /= 5.0

            if .MouseLook in control_flags {
                ROTATION_SENSITIVITY :: 0.001
                viewport_camera.yaw += ROTATION_SENSITIVITY * camera_rotation.x
                viewport_camera.pitch += ROTATION_SENSITIVITY * camera_rotation.y
                
                for viewport_camera.yaw < -2.0 * math.PI do viewport_camera.yaw += 2.0 * math.PI
                for viewport_camera.yaw > 2.0 * math.PI do viewport_camera.yaw -= 2.0 * math.PI
    
                if viewport_camera.pitch < -math.PI / 2.0 do viewport_camera.pitch = -math.PI / 2.0
                if viewport_camera.pitch > math.PI / 2.0 do viewport_camera.pitch = math.PI / 2.0
            }
    
            camera_direction: hlsl.float3 = {0.0, 0.0, 0.0}
            if .MoveForward in control_flags do camera_direction += {0.0, 1.0, 0.0}
            if .MoveBackward in control_flags do camera_direction += {0.0, -1.0, 0.0}
            if .MoveLeft in control_flags do camera_direction += {-1.0, 0.0, 0.0}
            if .MoveRight in control_flags do camera_direction += {1.0, 0.0, 0.0}
            if .MoveUp in control_flags do camera_direction += {0.0, 0.0, 1.0}
            if .MoveDown in control_flags do camera_direction += {0.0, 0.0, -1.0}

            if camera_direction != {0.0, 0.0, 0.0} {
                camera_direction = hlsl.float3(speed_mod) * hlsl.float3(CAMERA_SPEED) * hlsl.normalize(camera_direction)
            }
            
            //Compute temporary camera matrix for orienting player inputted direction vector
            world_from_view := hlsl.inverse(camera_view_from_world(&viewport_camera))
            viewport_camera.position += 
                (world_from_view *
                hlsl.float4{camera_direction.x, camera_direction.y, camera_direction.z, 0.0}).xyz


        }

        // Teleport spyro in front of camera
        if move_spyro {
            using viewport_camera
            placement_distance := 5.0
            world_from_view := hlsl.inverse(camera_view_from_world(&viewport_camera))
            world_facing : hlsl.float3 = (world_from_view * hlsl.float4{0.0, 1.0, 0.0, 0.0}).xyz
            spyro_pos = position + world_facing * hlsl.float3(placement_distance)
        }


        if imgui_state.show_gui {
            @static show_demo := false

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

                    imgui.EndMenu()
                }

                if imgui.BeginMenu("Debug") {
                    if imgui.MenuItem("Show Dear ImGUI demo window", selected = show_demo) {
                        show_demo = !show_demo
                    }

                    imgui.EndMenu()
                }
                
                imgui.EndMainMenuBar()
            }


            if show_demo do imgui.ShowDemoWindow()

            {
                using viewport_camera
                imgui.Text("Frame #%i", vgd.frame_count)
                imgui.Text("Camera position: (%f, %f, %f)", position.x, position.y, position.z)
                imgui.Text("Camera yaw: %f", yaw)
                imgui.Text("Camera pitch: %f", pitch)
            }

            sdl2.SetWindowTitle(sdl_window, TITLE_WITH_IMGUI)
        } else {
            sdl2.SetWindowTitle(sdl_window, TITLE_WITHOUT_IMGUI)
        }

        draw_ps1_primitives(&vgd, &render_data, main_scene_mesh[0].mesh, main_scene_mesh[0].material, {
            {
                world_from_model = {
                    1.0, 0.0, 0.0, 0.0,
                    0.0, 1.0, 0.0, 0.0,
                    0.0, 0.0, 1.0, -50.0,
                    0.0, 0.0, 0.0, 1.0
                }
            }
        })

        // Queue up draw call of my_gltf
        t := f32(vgd.frame_count) / 144.0
        translation := 2.0 * math.sin(t)
        mesh_im_drawing := my_gltf_mesh[0]
        draw_ps1_primitives(&vgd, &render_data, mesh_im_drawing.mesh, mesh_im_drawing.material, {
            {
                world_from_model = {
                    1.0, 0.0, 0.0, 10.0,
                    0.0, 1.0, 0.0, 0.0,
                    0.0, 0.0, 0.3, translation,
                    0.0, 0.0, 0.0, 1.0
                }
            },
            {
                world_from_model = {
                    1.0, 0.0, 0.0, spyro_pos.x,
                    0.0, 1.0, 0.0, spyro_pos.y,
                    0.0, 0.0, 1.0, spyro_pos.z,
                    0.0, 0.0, 0.0, 1.0
                }
            }
        })

        imgui.EndFrame()

        // Render
        {
            // Increment timeline semaphore upon command buffer completion
            append(&render_data.gfx_sync_info.signal_ops, vkw.Semaphore_Op {
                semaphore = render_data.gfx_timeline,
                value = vgd.frame_count + 1
            })

            // Resize swapchain if necessary
            if vgd.resize_window {
                vk.DeviceWaitIdle(vgd.device)

                if !vkw.resize_window(&vgd, resolution) do log.error("Failed to resize window")
                //resize_framebuffers(&vgd, &render_data, resolution)


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
            framebuffer.clear_color = {0.0, 0.5, 0.5, 1.0}
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

        // Clear sync info for next frame
        vkw.clear_sync_info(&render_data.gfx_sync_info)
        vgd.frame_count += 1

        // CLear temp allocator for next frame
        free_all(context.temp_allocator)
    }

    log.info("Returning from main()")
}
