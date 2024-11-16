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
    resolution: vkw.int2
    resolution.x = 1920
    resolution.y = 1080
    sdl_windowflags : sdl2.WindowFlags = {.VULKAN}
    sdl_window := sdl2.CreateWindow("KataWARi", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, resolution.x, resolution.y, sdl_windowflags)
    defer sdl2.DestroyWindow(sdl_window)

    // Initialize the state required for rendering to the window
    if !vkw.init_sdl2_window(&vgd, sdl_window) {
        log.fatal("Couldn't init SDL2 surface.")
    }

    // Initialize the renderer
    render_data := init_renderer(&vgd)
    defer delete_renderer(&vgd, &render_data)

    // Create test images
    // TEST_IMAGES :: 3
    test_images: [dynamic]vkw.Image_Handle
    defer delete(test_images)
    selected_image := 0
    {
        filenames := make([dynamic]cstring, context.temp_allocator)
        defer delete(filenames)

        err := filepath.walk("data/images", proc(info: os.File_Info, in_err: os.Error, user_data: rawptr) -> 
        (err: os.Error, skip_dir: bool) {

            if info.is_dir do return

            cs, e := strings.clone_to_cstring(info.fullpath, context.temp_allocator)
            if e != .None {
                log.errorf("Error cloning filepath \"%v\" to cstring", info.fullpath)
            }
            
            fnames : ^[dynamic]cstring = cast(^[dynamic]cstring)user_data
            append(fnames, cs)
            
            err = nil
            skip_dir = false
            return
        }, &filenames)
        if err != nil {
            log.error("Error walking images directory")
        }

        resize(&test_images, len(filenames))

        // Load images from disk
        for filename, i in filenames {
            width, height, channels: i32
            image_bytes := stbi.load(filename, &width, &height, &channels, 4)
            defer stbi.image_free(image_bytes)
            byte_count := int(width * height * 4)
            image_slice := slice.from_ptr(image_bytes, byte_count)
            log.debugf("%v uncompressed size: %v bytes", filename, byte_count)
    
            info := vkw.Image_Create {
                flags = nil,
                image_type = .D2,
                format = .R8G8B8A8_SRGB,
                extent = {
                    width = u32(width),
                    height = u32(height),
                    depth = 1
                },
                supports_mipmaps = false,
                array_layers = 1,
                samples = {._1},
                tiling = .OPTIMAL,
                usage = {.SAMPLED,.TRANSFER_DST},
                alloc_flags = nil
            }
            ok: bool
            test_images[i], ok = vkw.sync_create_image_with_data(&vgd, &info, image_slice)
            if !ok {
                log.error("vkw.sync_create_image_with_data failed.")
            }
        }

    }

    //Dear ImGUI init
    imgui_state := imgui_init(&vgd, resolution)
    defer imgui_cleanup(&vgd, &imgui_state)
    show_gui := true

    // Load test glTF model
    my_gltf_mesh: [dynamic]DrawPrimitive
    defer delete(my_gltf_mesh)
    {
        path : cstring = "data/models/spyro2.glb"
        my_gltf_mesh = load_gltf_mesh(&vgd, &render_data, path, context.allocator)
    }
    
    log.info("App initialization complete")

    // Initialize main viewport camera
    viewport_camera := Camera {
        position = {0.0, -5.0, 10.0},
        yaw = 0.0,
        pitch = math.PI / 4.0,
        fov_radians = math.PI / 2.0,
        aspect_ratio = f32(resolution.x) / f32(resolution.y),
        nearplane = 0.1,
        farplane = 1_000.0
    }
    saved_mouse_coords := hlsl.int2 {0, 0}

    free_all(context.temp_allocator)

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
                    case .KEYDOWN: {
                        #partial switch event.key.keysym.sym {
                            case .ESCAPE: show_gui = !show_gui
                            case .SPACE: selected_image = (selected_image + 1) % len(test_images)
                            case .W: control_flags += {.MoveForward}
                            case .S: control_flags += {.MoveBackward}
                            case .A: control_flags += {.MoveLeft}
                            case .D: control_flags += {.MoveRight}
                            case .Q: control_flags += {.MoveDown}
                            case .E: control_flags += {.MoveUp}
                        }
                        // if .LSHIFT in event.key.keysym.mod {
                        //     control_flags += {.Speed}
                        // }
                        // if .LCTRL in event.key.keysym.mod {
                        //     control_flags += {.Slow}
                        // }
                        imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.sym), true)
                    }
                    case .KEYUP: {
                        #partial switch event.key.keysym.sym {
                            case .W: control_flags -= {.MoveForward}
                            case .S: control_flags -= {.MoveBackward}
                            case .A: control_flags -= {.MoveLeft}
                            case .D: control_flags -= {.MoveRight}
                            case .Q: control_flags -= {.MoveDown}
                            case .E: control_flags -= {.MoveUp}
                        }
                        // if .LSHIFT in event.key.keysym.mod {
                        //     control_flags -= {.Speed}
                        // }
                        // if .LCTRL in event.key.keysym.mod {
                        //     control_flags -= {.Slow}
                        // }
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

        
        if show_gui {
            imgui.ShowDemoWindow()
            {
                using viewport_camera
                imgui.Text("Frame #%i", vgd.frame_count)
                imgui.Text("Camera position: (%f, %f, %f)", position.x, position.y, position.z)
                imgui.Text("Camera yaw: %f", yaw)
                imgui.Text("Camera pitch: %f", pitch)
            }
        }

        // Queue up draw call of my_gltf
        t := f32(vgd.frame_count) / 144.0
        y_translation := 20.0 * math.sin(t)
        mesh_im_drawing := my_gltf_mesh[0]
        draw_ps1_primitives(&vgd, &render_data, mesh_im_drawing.mesh, mesh_im_drawing.material, {
            {
                world_from_model = {
                    5.0, 0.0, 0.0, 10.0,
                    0.0, 5.0, 0.0, y_translation,
                    0.0, 0.0, 1.0, 0.0,
                    0.0, 0.0, 0.0, 1.0
                }
            },
            {
                world_from_model = {
                    1.0, 0.0, 0.0, 0.0,
                    0.0, 1.0, 0.0, 0.0,
                    0.0, 0.0, 1.0, 0.0,
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
    
            // Sync point where we wait if there are already two frames in the gfx queue
            if vgd.frame_count >= u64(vgd.frames_in_flight) {
                // Wait on timeline semaphore before starting command buffer execution
                wait_value := vgd.frame_count - u64(vgd.frames_in_flight) + 1
                append(&render_data.gfx_sync_info.wait_ops, vkw.Semaphore_Op {
                    semaphore = render_data.gfx_timeline,
                    value = wait_value
                })
                
                // CPU-sync to prevent CPU from getting further ahead than
                // the number of frames in flight
                sem, ok := vkw.get_semaphore(&vgd, render_data.gfx_timeline)
                if !ok do log.error("Couldn't find semaphore for CPU-sync")
                info := vk.SemaphoreWaitInfo {
                    sType = .SEMAPHORE_WAIT_INFO,
                    pNext = nil,
                    flags = nil,
                    semaphoreCount = 1,
                    pSemaphores = sem,
                    pValues = &wait_value
                }
                if vk.WaitSemaphores(vgd.device, &info, max(u64)) != .SUCCESS {
                    log.error("Failed to wait for timeline semaphore CPU-side man what")
                }
            }

            // It is now safe to write to the uniform buffer now that
            // we know frame N-2 has finished
            {
                
                render_data.cpu_uniforms.clip_from_world =
                    camera_projection_from_view(&viewport_camera) *
                    camera_view_from_world(&viewport_camera)

                io := imgui.GetIO()
                render_data.cpu_uniforms.clip_from_screen = {
                    2.0 / io.DisplaySize.x, 0.0, 0.0, -1.0,
                    0.0, 2.0 / io.DisplaySize.y, 0.0, -1.0,
                    0.0, 0.0, 1.0, 0.0,
                    0.0, 0.0, 0.0, 1.0
                }
                render_data.cpu_uniforms.time = t;

                mesh_buffer, _ := vkw.get_buffer(&vgd, render_data.mesh_buffer)
                material_buffer, _ := vkw.get_buffer(&vgd, render_data.material_buffer)
                instance_buffer, _ := vkw.get_buffer(&vgd, render_data.instance_buffer)
                position_buffer, _ := vkw.get_buffer(&vgd, render_data.positions_buffer)
                uv_buffer, _ := vkw.get_buffer(&vgd, render_data.uvs_buffer)
                color_buffer, _ := vkw.get_buffer(&vgd, render_data.colors_buffer)

                render_data.cpu_uniforms.mesh_ptr = mesh_buffer.address
                render_data.cpu_uniforms.material_ptr = material_buffer.address
                render_data.cpu_uniforms.instance_ptr = instance_buffer.address
                render_data.cpu_uniforms.position_ptr = position_buffer.address
                render_data.cpu_uniforms.uv_ptr = uv_buffer.address
                render_data.cpu_uniforms.color_ptr = color_buffer.address

                in_slice := slice.from_ptr(&render_data.cpu_uniforms, 1)
                if !vkw.sync_write_buffer(UniformBufferData, &vgd, render_data.uniform_buffer, in_slice) {
                    log.error("Failed to write uniform buffer data")
                }
            }
    
            gfx_cb_idx := vkw.begin_gfx_command_buffer(&vgd)

            // This has to be called once per frame
            vkw.begin_frame(&vgd, gfx_cb_idx)
    
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
            
            t := f32(vgd.frame_count) / 144.0
    
            framebuffer: vkw.Framebuffer
            framebuffer.color_images[0] = swapchain_image_handle
            framebuffer.resolution.x = u32(resolution.x)
            framebuffer.resolution.y = u32(resolution.y)
            //framebuffer.clear_color = {0.0, 0.5*math.cos(t)+0.5, 0.5*math.sin(t)+0.5, 1.0}
            framebuffer.clear_color = {0.0, 0.5, 0.5, 1.0}
            framebuffer.color_load_op = .CLEAR
            //framebuffer.color_load_op = .DONT_CARE

            // Main render call
            render(&vgd, gfx_cb_idx, &render_data, &framebuffer)
            framebuffer.color_load_op = .LOAD

            // Draw Dear Imgui
            vkw.cmd_begin_render_pass(&vgd, gfx_cb_idx, &framebuffer)
            draw_imgui(&vgd, gfx_cb_idx, &imgui_state)
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
