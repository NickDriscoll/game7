package main

import "core:fmt"
import "core:log"
import "vendor:sdl2"
import vkw "desktop_vulkan_wrapper"

main :: proc() {
    // Parse command-line arguments

    
    // Set up Odin context
    context.logger = log.create_console_logger(.Debug)
    //context.logger = log.create_console_logger(.Info)

    // Initialize SDL2
    sdl2.Init({sdl2.InitFlag.EVENTS, sdl2.InitFlag.VIDEO})
    defer sdl2.Quit()
    fmt.println("Initialized SDL2")

    // Use SDL2 to load Vulkan
    if sdl2.Vulkan_LoadLibrary(nil) != 0 {
        log.fatal("Couldn't load Vulkan library.")
    }
    
    // Initialize graphics device
    init_params := vkw.Init_Parameters {
        frames_in_flight = 2,
        window_support = true
    }
    vgd := vkw.create_graphics_device(&init_params)
    log.debugf("%#v", vgd)
    
    // Make window
    sdl_windowflags : sdl2.WindowFlags = {.VULKAN}
    sdl_window := sdl2.CreateWindow("every morning when I wake up it hits me that i work at LunarG", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, 800, 600, sdl_windowflags)
    defer sdl2.DestroyWindow(sdl_window)

    // Initialize the state required for rendering to the window
    {
        vkw.init_sdl2_surface(&vgd, sdl_window)
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

        //vkw.draw_meshes()
        //vkw.draw_meshes()

        // Render

        //frame_data := vkw.start_frame()


    }

    fmt.println("Returning from main()")
}