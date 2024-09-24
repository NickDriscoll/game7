package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:slice"
import "vendor:sdl2"
import stbi "vendor:stb/image"
import vkw "desktop_vulkan_wrapper"

MAX_PER_FRAME_DRAW_CALLS :: 1024

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
        frames_in_flight = 2,
        window_support = true,
        vk_get_instance_proc_addr = sdl2.Vulkan_GetVkGetInstanceProcAddr()
    }
    vgd := vkw.init_vulkan(&init_params)
    log.debugf("%#v", vgd)
    
    // Make window
    resolution: vkw.int2
    resolution.x = 800
    resolution.y = 800
    sdl_windowflags : sdl2.WindowFlags = {.VULKAN}
    sdl_window := sdl2.CreateWindow("KataWARi", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, resolution.x, resolution.y, sdl_windowflags)
    defer sdl2.DestroyWindow(sdl_window)

    // Initialize the state required for rendering to the window
    {
        if !vkw.init_sdl2_window(&vgd, sdl_window) {
            log.fatal("Couldn't init SDL2 surface.")
        }
    }

    // Pipeline creation
    gfx_pipeline_handle: vkw.Pipeline_Handle
    {
        // Load shader bytecode
        // This will be embedded into the executable at compile-time
        vertex_spv := #load("data/shaders/test.vert.spv", []u32)
        fragment_spv := #load("data/shaders/test.frag.spv", []u32)

        pipeline_info := vkw.Graphics_Pipeline_Info {
            vertex_shader_bytecode = vertex_spv,
            fragment_shader_bytecode = fragment_spv,
            input_assembly_state = vkw.Input_Assembly_State {
                topology = .TRIANGLE_LIST,
                primitive_restart_enabled = false
            },
            tessellation_state = {},
            rasterization_state = vkw.default_rasterization_state(),
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
                color_attachment_formats = {vkw.Format.B8G8R8A8_SRGB},
                depth_attachment_format = nil
            }
        }

        handles := vkw.create_graphics_pipelines(&vgd, {pipeline_info})
        defer delete(handles)

        gfx_pipeline_handle = handles[0]
    }

    // Create main timeline semaphore
    gfx_timeline: vkw.Semaphore_Handle
    {
        info := vkw.Semaphore_Info {
            type = .TIMELINE,
            init_value = 0
        }
        gfx_timeline = vkw.create_semaphore(&vgd, &info)
    }

    // Create index buffer
    index_buffer: vkw.Buffer_Handle
    {
        info := vkw.Buffer_Info {
            size = size_of(u16) * 6,
            usage = {.INDEX_BUFFER, .TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL}
        }
        index_buffer = vkw.create_buffer(&vgd, &info)
    }

    // Create indirect draw buffer
    draw_buffer: vkw.Buffer_Handle
    {
        info := vkw.Buffer_Info {
            size = 64,
            usage = {.INDIRECT_BUFFER,.TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL}
        }
        draw_buffer = vkw.create_buffer(&vgd, &info)
    }

    // Create stack-allocating synchronization info struct
    // Represents the semaphores a given frame's gfx command buffer will wait on and signal
    gfx_sync_info: vkw.Sync_Info
    defer vkw.delete_sync_info(&gfx_sync_info)
            
    // Write to buffers
    {
        indices : []u16 = {0, 1, 2, 1, 3, 2}
        if !vkw.sync_write_buffer(u16, &vgd, index_buffer, indices) {
            log.error("vkw.sync_write_buffer() failed.")
        }
        draws : []vkw.DrawIndexedIndirectCommand = {
            {
                indexCount = u32(len(indices)),
                instanceCount = 1,
                firstIndex = 0,
                vertexOffset = 0,
                firstInstance = 0
            }
        }
        if !vkw.sync_write_buffer(vkw.DrawIndexedIndirectCommand, &vgd, draw_buffer, draws) {
            log.error("vkw.sync_write_buffer() failed.")
        }
    }

    // Create image
    test_image: vkw.Image_Handle
    {
        // Load image from disk
        //filename : cstring = "data/images/sarah_bonito.jpg"
        filename : cstring = "data/images/me_may2023.jpg"
        width, height, channels: i32
        image_bytes := stbi.load(filename, &width, &height, &channels, 4)
        byte_count := int(width * height * 4)
        defer stbi.image_free(image_bytes)
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
        test_image, ok = vkw.sync_create_image_with_data(&vgd, &gfx_sync_info, &info, image_slice)
        if !ok {
            log.error("vkw.sync_create_image_with_data failed.")
        }
    }

    log.info("App initialization complete")

    do_main_loop := true
    for do_main_loop {
        // Process system events
        {
            event: sdl2.Event
            for sdl2.PollEvent(&event) {
                #partial switch event.type {
                    case .QUIT: do_main_loop = false
                    case .KEYDOWN: {
                        #partial switch event.key.keysym.sym {
                            case .ESCAPE: do_main_loop = false
                        }
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

        // Render

        {
            // Clear out previous frame's sync info
            vkw.clear_sync_info(&gfx_sync_info)

            // Increment timeline semaphore upon command buffer completion
            append(&gfx_sync_info.signal_ops, vkw.Semaphore_Op {
                semaphore = gfx_timeline,
                value = vgd.frame_count + 1
            })
    
            cpu_sync: vkw.Semaphore_Op
            if vgd.frame_count >= u64(vgd.frames_in_flight) {
                // Wait on timeline semaphore before starting command buffer execution
                frame_to_wait_on := vgd.frame_count - u64(vgd.frames_in_flight) + 1
                append(&gfx_sync_info.wait_ops, vkw.Semaphore_Op {
                    semaphore = gfx_timeline,
                    value = frame_to_wait_on
                })
    
                // Sync on the CPU-side so that it doesn't get too far ahead
                // of the GPU
                cpu_sync.semaphore = gfx_timeline
                cpu_sync.value = frame_to_wait_on
            }
    
            gfx_cb_idx := vkw.begin_gfx_command_buffer(&vgd, &cpu_sync)

            // This has to be called once per frame
            vkw.tick_subsystems(&vgd, gfx_cb_idx)
    
            swapchain_image_idx: u32
            vkw.acquire_swapchain_image(&vgd, &swapchain_image_idx)
            swapchain_image_handle := vgd.swapchain_images[swapchain_image_idx]
    
            // Wait on swapchain image acquire semaphore
            // and signal when we're done drawing on a different semaphore
            append(&gfx_sync_info.wait_ops, vkw.Semaphore_Op {
                semaphore = vgd.acquire_semaphores[vkw.in_flight_idx(&vgd)]
            })
            append(&gfx_sync_info.signal_ops, vkw.Semaphore_Op {
                semaphore = vgd.present_semaphores[vkw.in_flight_idx(&vgd)]
            })
    
            // Memory barrier between image acquire and rendering
            swapchain_vkimage, _ := vkw.get_image_vkhandle(&vgd, swapchain_image_handle)
            vkw.cmd_gfx_pipeline_barrier(&vgd, gfx_cb_idx, {
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
                    subresource_range = vkw.ImageSubresourceRange {
                        aspectMask = {.COLOR},
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1
                    }
                }
            })
    
            vkw.cmd_bind_index_buffer(&vgd, gfx_cb_idx, index_buffer)
            
            t := f32(vgd.frame_count) / 144.0
    
            framebuffer: vkw.Framebuffer
            framebuffer.color_images[0] = swapchain_image_handle
            framebuffer.resolution.x = u32(resolution.x)
            framebuffer.resolution.y = u32(resolution.y)
            framebuffer.clear_color = {0.0, 0.5*math.cos(t)+0.5, 0.5*math.sin(t)+0.5, 1.0}
            vkw.cmd_begin_render_pass(&vgd, gfx_cb_idx, &framebuffer)
            
            vkw.cmd_bind_descriptor_set(&vgd, gfx_cb_idx)
            vkw.cmd_bind_pipeline(&vgd, gfx_cb_idx, .GRAPHICS, gfx_pipeline_handle)

            //res := resolution / 2
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
                vkw.Scissor {
                    offset = vkw.Offset2D {
                        x = 0,
                        y = 0
                    },
                    extent = vkw.Extent2D {
                        width = u32(res.x),
                        height = u32(res.y),
                    }
                }
            })

            pcs :: struct {
                t: f32,
                image: u32,
                sampler: vkw.Immutable_Samplers
            }
            vkw.cmd_push_constants_gfx(pcs, &vgd, gfx_cb_idx, &pcs {
                t = t,
                image = test_image.index,
                sampler = .Aniso16
            })

            vkw.cmd_draw_indexed_indirect(&vgd, gfx_cb_idx, draw_buffer, 0, 1)
    
            vkw.cmd_end_render_pass(&vgd, gfx_cb_idx)
    
            // Memory barrier between rendering and image present
            vkw.cmd_gfx_pipeline_barrier(&vgd, gfx_cb_idx, {
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
                    subresource_range = vkw.ImageSubresourceRange {
                        aspectMask = {.COLOR},
                        baseMipLevel = 0,
                        levelCount = 1,
                        baseArrayLayer = 0,
                        layerCount = 1
                    }
                }
            })
    
            vkw.submit_gfx_command_buffer(&vgd, gfx_cb_idx, &gfx_sync_info)
            vkw.present_swapchain_image(&vgd, &swapchain_image_idx)
    
            vgd.frame_count += 1
        }
    }

    log.info("Returning from main()")
}
