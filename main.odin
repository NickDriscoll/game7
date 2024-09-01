package main

import "core:fmt"
import "vendor:sdl2"
//import vk "desktop_vulkan_wrapper"
import vk "../desktop_vulkan_wrapper"

main :: proc() {

    // Initialize SDL2
    //sdl2.Init({sdl2.InitFlag.EVENTS, sdl2.InitFlag.VIDEO})
    fmt.println("Initialized SDL2")

    // Make window
    sdl_windowflags : sdl2.WindowFlags = {.VULKAN}
    sdl_window := sdl2.CreateWindow("every morning when I wake up it hits me that i work at LunarG", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, 800, 600, sdl_windowflags)
    defer sdl2.DestroyWindow(sdl_window)

    // Initialize graphics device
    init_params := vk.Init_Parameters {}
    vgd := vk.vulkan_init(&init_params)

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
    }

    fmt.println("Returning from main()")
}