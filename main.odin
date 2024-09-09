package main

import "core:fmt"
import "core:log"
import "core:os"
import "vendor:sdl2"
import vk "vendor:vulkan"
import vkw "desktop_vulkan_wrapper"

main :: proc() {
    // Parse command-line arguments
    log_level := log.Level.Info
    {
        argc := len(os.args)
        for arg, i in os.args {
            if arg == "--log-level" {
                if i + 1 < argc {
                    switch os.args[i + 1] {
                        case "DEBUG": log_level = .Debug
                        case "INFO": log_level = .Info
                        case "WARNING": log_level = .Warning
                        case "ERROR": log_level = .Error
                    }
                }
            }
        }
    }
    
    // Set up Odin context
    context.logger = log.create_console_logger(log_level)

    // Initialize SDL2
    sdl2.Init({sdl2.InitFlag.EVENTS, sdl2.InitFlag.VIDEO})
    defer sdl2.Quit()
    log.info("Initialized SDL2")

    // Use SDL2 to load Vulkan
    if sdl2.Vulkan_LoadLibrary(nil) != 0 {
        log.fatal("Couldn't load Vulkan library.")
    }
    
    // Initialize graphics device
    init_params := vkw.Init_Parameters {
        api_version = .Vulkan12,
        frames_in_flight = 2,
        window_support = true
    }
    vgd := vkw.init_graphics_device(&init_params)
    log.debugf("%#v", vgd)
    
    // Make window
    resolution: vkw.int2
    resolution.x = 800
    resolution.y = 600
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
    {
        // pipeline_info := vkw.PipelineInfo {

        // }
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

    // Create buffer
    test_buffer: vkw.Buffer_Handle
    {
        info := vkw.Buffer_Info {
            size = 64,
            usage = {.INDEX_BUFFER},
            queue_family = .Graphics,
            required_flags = {.DEVICE_LOCAL}
        }
        test_buffer = vkw.create_buffer(&vgd, &info)
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
                }
            }
        }

        // Update

        // Render

        vkw.tick_deletion_queues(&vgd)

        // Represents what this frame's gfx command buffer will wait on and signal
        gfx_sync_info: vkw.Sync_Info
        defer vkw.delete_sync_info(&gfx_sync_info)
        
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

        // Buffer delete
        vkw.delete_buffer(&vgd, test_buffer)

        gfx_cb_idx := vkw.begin_gfx_command_buffer(&vgd, &cpu_sync)

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
        vkw.cmd_pipeline_barrier(&vgd, gfx_cb_idx, {
            vkw.Image_Barrier {
                src_stage_mask = {.ALL_COMMANDS},
                src_access_mask = {.MEMORY_READ},
                dst_stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
                dst_access_mask = {.MEMORY_WRITE},
                old_layout = .UNDEFINED,
                new_layout = .COLOR_ATTACHMENT_OPTIMAL,
                src_queue_family = vgd.gfx_queue_family,
                dst_queue_family = vgd.gfx_queue_family,
                image_handle = swapchain_image_handle,
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
        framebuffer.color_image_views[0] = swapchain_image_handle
        framebuffer.resolution.x = u32(resolution.x)
        framebuffer.resolution.y = u32(resolution.y)
        vkw.cmd_begin_render_pass(&vgd, gfx_cb_idx, &framebuffer)
        /*

        vkw.write_buffer_elems()
        vkw.draw_indirect()
        
        */
        vkw.cmd_end_render_pass(&vgd, gfx_cb_idx)

        // Memory barrier between rendering and image present
        vkw.cmd_pipeline_barrier(&vgd, gfx_cb_idx, {
            vkw.Image_Barrier {
                src_stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
                src_access_mask = {.MEMORY_WRITE},
                dst_stage_mask = {.ALL_COMMANDS},
                dst_access_mask = {.MEMORY_READ},
                old_layout = .COLOR_ATTACHMENT_OPTIMAL,
                new_layout = .PRESENT_SRC_KHR,
                src_queue_family = vgd.gfx_queue_family,
                dst_queue_family = vgd.gfx_queue_family,
                image_handle = swapchain_image_handle,
                subresource_range = vk.ImageSubresourceRange {
                    aspectMask = {.COLOR},
                    baseMipLevel = 0,
                    levelCount = 1,
                    baseArrayLayer = 0,
                    layerCount = 1
                }
            }
        })

        vkw.submit_gfx_command_buffer(&vgd, gfx_cb_idx, &gfx_sync_info)
        vkw.present_swapchain_image(&vgd, swapchain_image_idx)

        vgd.frame_count += 1
    }

    log.info("Returning from main()")
}