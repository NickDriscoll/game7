package main

import "core:fmt"
import "core:log"
import "core:os"
import "vendor:sdl2"
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
    sdl_windowflags : sdl2.WindowFlags = {.VULKAN}
    sdl_window := sdl2.CreateWindow("KataWARi", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, 800, 600, sdl_windowflags)
    defer sdl2.DestroyWindow(sdl_window)

    // Initialize the state required for rendering to the window
    {
        if !vkw.init_sdl2_surface(&vgd, sdl_window) {
            log.fatal("Couldn't init SDL2 surface.")
        }
    }
    
    // Pipeline creation
    {
        // pipeline_info := vkw.PipelineInfo {

        // }
    }

    log.info("App initialization complete")
    do_main_loop := true
    for do_main_loop {
        // Process system events
        {
            event: sdl2.Event
            for sdl2.PollEvent(&event) {
                if event.type == .QUIT do do_main_loop = false
                if event.key.keysym.sym == .ESCAPE do do_main_loop = false
            }
        }

        // Update

        // Render

        vkw.tick_deletion_queues(&vgd)

        /*
        gfx_cb_idx := vkw.begin_gfx_command_buffer(&vgd)

        vkw.begin_render_pass(renderpass_handle)
        vkw.write_buffer_elems()
        vkw.draw_indirect()
        vkw.end_render_pass()

        vkw.submit_gfx_command_buffer(vgd, gfx_cb_idx)
        */


    }

    log.info("Returning from main()")
}