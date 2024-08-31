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
    sdl_window := sdl2.CreateWindow("Vulkan is not for the feint of heart", sdl2.WINDOWPOS_CENTERED, sdl2.WINDOWPOS_CENTERED, 800, 800, sdl_windowflags)
    defer sdl2.DestroyWindow(sdl_window)

    init_params := vk.Init_Parameters {}
    vgd := vk.vulkan_init(&init_params)
    
    fmt.println("Returning from main()")
}