package main

import "core:c"
import "core:fmt"
import "core:log"
import "core:math/linalg/hlsl"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "vendor:sdl2"
import stbi "vendor:stb/image"

import imgui "odin-imgui"
import vk "vendor:vulkan"
import vkw "desktop_vulkan_wrapper"

MAX_PER_FRAME_DRAW_CALLS :: 1024
MAX_GLOBAL_INDICES :: 1024*1024
FRAMES_IN_FLIGHT :: 2

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
    log.debugf("%#v", vgd)
    log.infof("minStorageBufferOffsetAlignment == %v", vgd.physical_device_properties.properties.limits.minStorageBufferOffsetAlignment)
    
    // Make window
    resolution: vkw.int2
    resolution.x = 1920
    resolution.y = 1080
    sdl_windowflags : sdl2.WindowFlags = {.VULKAN}
    sdl_window := sdl2.CreateWindow("KataWARi", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, resolution.x, resolution.y, sdl_windowflags)
    defer sdl2.DestroyWindow(sdl_window)

    // Initialize the state required for rendering to the window
    {
        if !vkw.init_sdl2_window(&vgd, sdl_window) {
            log.fatal("Couldn't init SDL2 surface.")
        }
    }

    // Initialize the render state structure
    // This is a megastruct for holding the return values from vkw basically
    render_state: RenderingState
    defer delete_rendering_state(&vgd, &render_state)

    // Pipeline creation
    {
        // Load shader bytecode
        // This will be embedded into the executable at compile-time
        vertex_spv := #load("data/shaders/test.vert.spv", []u32)
        fragment_spv := #load("data/shaders/test.frag.spv", []u32)

        raster_state := vkw.default_rasterization_state()
        raster_state.cull_mode = nil

        pipeline_info := vkw.Graphics_Pipeline_Info {
            vertex_shader_bytecode = vertex_spv,
            fragment_shader_bytecode = fragment_spv,
            input_assembly_state = vkw.Input_Assembly_State {
                topology = .TRIANGLE_LIST,
                primitive_restart_enabled = false
            },
            tessellation_state = {},
            rasterization_state = raster_state,
            multisample_state = vkw.Multisample_State {
                sample_count = {._1},
                do_sample_shading = false,
                min_sample_shading = 0.0,
                sample_mask = nil,
                do_alpha_to_coverage = false,
                do_alpha_to_one = false
            },
            depthstencil_state = vkw.DepthStencil_State {
                flags = nil,
                do_depth_test = false,
                do_depth_write = false,
                depth_compare_op = .GREATER_OR_EQUAL,
                do_depth_bounds_test = false,
                do_stencil_test = false,
                // front = nil,
                // back = nil,
                min_depth_bounds = 0.0,
                max_depth_bounds = 1.0
            },
            colorblend_state = vkw.default_colorblend_state(),
            renderpass_state = vkw.PipelineRenderpass_Info {
                color_attachment_formats = {vk.Format.B8G8R8A8_SRGB},
                depth_attachment_format = nil
            }
        }

        handles := vkw.create_graphics_pipelines(&vgd, {pipeline_info})
        defer delete(handles)

        render_state.gfx_pipeline = handles[0]
    }

    // Create main timeline semaphore
    {
        info := vkw.Semaphore_Info {
            type = .TIMELINE,
            init_value = 0
        }
        render_state.gfx_timeline = vkw.create_semaphore(&vgd, &info)
    }

    // Create index buffer
    {
        info := vkw.Buffer_Info {
            size = size_of(u16) * MAX_GLOBAL_INDICES,
            usage = {.INDEX_BUFFER, .TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL}
        }
        render_state.index_buffer = vkw.create_buffer(&vgd, &info)
    }

    // Create indirect draw buffer
    {
        info := vkw.Buffer_Info {
            size = 64,
            usage = {.INDIRECT_BUFFER,.TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL}
        }
        render_state.draw_buffer = vkw.create_buffer(&vgd, &info)
    }

    // Create uniform buffer
    {
        info := vkw.Buffer_Info {
            size = size_of(UniformBufferData),
            usage = {.UNIFORM_BUFFER,.TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL,.HOST_VISIBLE,.HOST_COHERENT}
        }
        render_state.uniform_buffer = vkw.create_buffer(&vgd, &info)
    }
            
    // Write to static buffers
    {
        // Write indices for drawing quad
        indices : []u16 = {0, 1, 2, 1, 3, 2}
        if !vkw.sync_write_buffer(u16, &vgd, render_state.index_buffer, indices) {
            log.error("vkw.sync_write_buffer() failed.")
        }

        // Write quad draw call to indirect draw buffer
        draws : []vk.DrawIndexedIndirectCommand = {
            {
                indexCount = u32(len(indices)),
                instanceCount = 1,
                firstIndex = 0,
                vertexOffset = 0,
                firstInstance = 0
            }
        }
        if !vkw.sync_write_buffer(vk.DrawIndexedIndirectCommand, &vgd, render_state.draw_buffer, draws) {
            log.error("vkw.sync_write_buffer() failed.")
        }
    }

    // Create image
    TEST_IMAGES :: 2
    test_images: [TEST_IMAGES]vkw.Image_Handle
    selected_image := 1
    {
        // Load image from disk

        filenames : []cstring = {
            "data/images/sarah_bonito.jpg",
            "data/images/me_may2023.jpg"
        }
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
    defer delete_imgui_state(&vgd, &imgui_state)
    
    log.info("App initialization complete")

    // Initialize main viewport camera
    viewport_camera := Camera {
        position = {0.0, -5.0, 10.0},
        yaw = 0.0,
        pitch = math.PI / 4.0,
        fov_radians = math.PI / 3.0,
        aspect_ratio = f32(resolution.x) / f32(resolution.y),
        nearplane = 0.1,
        farplane = 1_000.0
    }
    camera_control := false
    camera_forward := false
    camera_back := false
    camera_left := false
    camera_right := false
    camera_up := false
    camera_down := false
    saved_mouse_coords := hlsl.int2 {0, 0}

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
            io := imgui.GetIO()
            io.DeltaTime = f32(elapsed_time) / 1_000_000_000.0

            event: sdl2.Event
            for sdl2.PollEvent(&event) {
                #partial switch event.type {
                    case .QUIT: do_main_loop = false
                    case .KEYDOWN: {
                        #partial switch event.key.keysym.sym {
                            case .SPACE: selected_image = (selected_image + 1) % TEST_IMAGES
                            case .W: camera_forward = true
                            case .S: camera_back = true
                            case .A: camera_left = true
                            case .D: camera_right = true
                            case .Q: camera_down = true
                            case .E: camera_up = true
                        }
                        imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.sym), true)
                    }
                    case .KEYUP: {
                        #partial switch event.key.keysym.sym {
                            case .W: camera_forward = false
                            case .S: camera_back = false
                            case .A: camera_left = false
                            case .D: camera_right = false
                            case .Q: camera_down = false
                            case .E: camera_up = false
                        }
                        imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.sym), false)
                    }
                    case .MOUSEBUTTONDOWN: {
                        switch event.button.button {
                            case sdl2.BUTTON_LEFT: {
                            }
                            case sdl2.BUTTON_RIGHT: {
                                camera_control = !camera_control

                                sdl2.SetRelativeMouseMode(sdl2.bool(camera_control))
                                if camera_control {
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
                        imgui.IO_AddMousePosEvent(io, f32(event.motion.x), f32(event.motion.y))
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
        imgui.ShowDemoWindow()

        // Update camera based on user input
        if camera_control {
            ROTATION_SENSITIVITY :: 0.001
            viewport_camera.yaw += ROTATION_SENSITIVITY * camera_rotation.x
            viewport_camera.pitch += ROTATION_SENSITIVITY * camera_rotation.y
            
            for viewport_camera.yaw < -2.0 * math.PI do viewport_camera.yaw += 2.0 * math.PI
            for viewport_camera.yaw > 2.0 * math.PI do viewport_camera.yaw -= 2.0 * math.PI

            if viewport_camera.pitch < -math.PI / 2.0 do viewport_camera.pitch = -math.PI / 2.0
            if viewport_camera.pitch > math.PI / 2.0 do viewport_camera.pitch = math.PI / 2.0

            camera_direction: hlsl.float3 = {0.0, 0.0, 0.0}
            if camera_forward do camera_direction += {0.0, 1.0, 0.0}
            if camera_back do camera_direction += {0.0, -1.0, 0.0}
            if camera_left do camera_direction += {-1.0, 0.0, 0.0}
            if camera_right do camera_direction += {1.0, 0.0, 0.0}
            if camera_up do camera_direction += {0.0, 0.0, 1.0}
            if camera_down do camera_direction += {0.0, 0.0, -1.0}
            
            //Compute temporary camera matrix for orienting player inputted direction vector
            world_from_view := hlsl.inverse(camera_view_matrix(&viewport_camera))
            viewport_camera.position += 0.1 *
                (world_from_view *
                hlsl.float4{camera_direction.x, camera_direction.y, camera_direction.z, 0.0}).xyz

        }
        {
            using viewport_camera
            imgui.Text("Frame #%i", vgd.frame_count)
            imgui.Text("Camera position: (%f, %f, %f)", position.x, position.y, position.z)
            imgui.Text("Camera yaw: %f", yaw)
            imgui.Text("Camera pitch: %f", pitch)
        }

        imgui.EndFrame()

        // Render
        {
            // Increment timeline semaphore upon command buffer completion
            append(&render_state.gfx_sync_info.signal_ops, vkw.Semaphore_Op {
                semaphore = render_state.gfx_timeline,
                value = vgd.frame_count + 1
            })
    
            // Sync point where we wait if there are already two frames in the gfx queue
            if vgd.frame_count >= u64(vgd.frames_in_flight) {
                // Wait on timeline semaphore before starting command buffer execution
                wait_value := vgd.frame_count - u64(vgd.frames_in_flight) + 1
                append(&render_state.gfx_sync_info.wait_ops, vkw.Semaphore_Op {
                    semaphore = render_state.gfx_timeline,
                    value = wait_value
                })
                
                // CPU-sync to prevent CPU from getting further ahead than
                // the number of frames in flight
                sem, ok := vkw.get_semaphore(&vgd, render_state.gfx_timeline)
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
                uniforms: UniformBufferData
                uniforms.clip_from_world =
                    camera_projection_matrix(&viewport_camera) *
                    camera_view_matrix(&viewport_camera)

                io := imgui.GetIO()
                uniforms.clip_from_screen = {
                    2.0 / io.DisplaySize.x, 0.0, 0.0, -1.0,
                    0.0, 2.0 / io.DisplaySize.y, 0.0, -1.0,
                    0.0, 0.0, 1.0, 0.0,
                    0.0, 0.0, 0.0, 1.0
                }

                in_slice := slice.from_ptr(&uniforms, 1)
                if !vkw.sync_write_buffer(UniformBufferData, &vgd, render_state.uniform_buffer, in_slice) {
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
            append(&render_state.gfx_sync_info.wait_ops, vkw.Semaphore_Op {
                semaphore = vgd.acquire_semaphores[vkw.in_flight_idx(&vgd)]
            })
            append(&render_state.gfx_sync_info.signal_ops, vkw.Semaphore_Op {
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
    
            vkw.cmd_bind_index_buffer(&vgd, gfx_cb_idx, render_state.index_buffer)
            
            t := f32(vgd.frame_count) / 144.0
    
            framebuffer: vkw.Framebuffer
            framebuffer.color_images[0] = swapchain_image_handle
            framebuffer.resolution.x = u32(resolution.x)
            framebuffer.resolution.y = u32(resolution.y)
            framebuffer.clear_color = {0.0, 0.5*math.cos(t)+0.5, 0.5*math.sin(t)+0.5, 1.0}
            framebuffer.color_load_op = .CLEAR
            vkw.cmd_begin_render_pass(&vgd, gfx_cb_idx, &framebuffer)


            
            vkw.cmd_bind_descriptor_set(&vgd, gfx_cb_idx)
            vkw.cmd_bind_pipeline(&vgd, gfx_cb_idx, .GRAPHICS, render_state.gfx_pipeline)

            res := resolution
            vkw.cmd_set_viewport(&vgd, gfx_cb_idx, 0, {vkw.Viewport {
                x = 0.0,
                y = 0.0,
                width = f32(res.x),
                height = f32(res.y),
                minDepth = 0.0,
                maxDepth = 1.0
            }})
            vkw.cmd_set_scissor(&vgd, gfx_cb_idx, 0, {
                {
                    offset = vk.Offset2D {
                        x = 0,
                        y = 0
                    },
                    extent = vk.Extent2D {
                        width = u32(res.x),
                        height = u32(res.y),
                    }
                }
            })

            uniform_buf, ok := vkw.get_buffer(&vgd, render_state.uniform_buffer)
            vkw.cmd_push_constants_gfx(PushConstants, &vgd, gfx_cb_idx, &PushConstants {
                time = t,
                image = test_images[selected_image].index,
                sampler = .Aniso16,
                uniform_buffer_address = uniform_buf.address
            })

            // There will be one of these commands per "bucket"
            vkw.cmd_draw_indexed_indirect(&vgd, gfx_cb_idx, render_state.draw_buffer, 0, 1)

            // Draw Dear Imgui
            draw_imgui(&vgd, gfx_cb_idx, &imgui_state)
    
            vkw.cmd_end_render_pass(&vgd, gfx_cb_idx)
    
            // Memory barrier between rendering and image present
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
    
            vkw.submit_gfx_command_buffer(&vgd, gfx_cb_idx, &render_state.gfx_sync_info)
            vkw.present_swapchain_image(&vgd, &swapchain_image_idx)
    
            
            // Clear sync info for next frame
            vkw.clear_sync_info(&render_state.gfx_sync_info)
            vgd.frame_count += 1

            // CLear temp allocator for next frame
            free_all(context.temp_allocator)
        }
    }

    log.info("Returning from main()")
}
