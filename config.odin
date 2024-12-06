package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

UserConfiguration :: struct {
    flags: map[string]bool,
    // borderless_fullscreen: bool,
    // exclusive_fullscreen: bool,
    // always_on_top: bool,
    // show_imgui_demo: bool,
    // show_debug_menu: bool,
}

init_user_config :: proc(allocator := context.allocator) -> UserConfiguration {
    cfg: UserConfiguration
    cfg.flags = make(map[string]bool, allocator = allocator)

    return cfg
}

save_user_config :: proc(config: ^UserConfiguration, filename: string) {
    save_file, err := os.open(filename, os.O_WRONLY | os.O_CREATE)
    defer os.close(save_file)
    if err != nil {
        log.errorf("Error opening \"%v\" for saving: %v", filename, err)
    }

    sb: strings.Builder
    strings.builder_init(&sb, allocator = context.temp_allocator)
    defer strings.builder_destroy(&sb)

    for key, val in config.flags {
        st := fmt.sbprintfln(&sb, "%v = %v", key, val)
        os.write_string(save_file, st)
        strings.builder_reset(&sb)
    }

    // os.write_string(save_file, "borderless_fullscreen = false\n")
    // os.write_string(save_file, "exclusive_fullscreen = false\n")
    // os.write_string(save_file, "always_on_top = false\n")
    // os.write_string(save_file, "show_imgui_demo = false\n")
    // os.write_string(save_file, "show_debug_menu = false\n")
}

load_user_config :: proc(filename: string) -> UserConfiguration {
    u: UserConfiguration

    return u
}