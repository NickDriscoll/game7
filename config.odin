package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:text/scanner"
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
}

save_default_user_config :: proc(filename: string) {
    
}

load_user_config :: proc(filename: string) -> UserConfiguration {
    // @TODO: Figure out why this string can't seem to be allocated with temp memory

    file_text, ok := os.read_entire_file(filename)
    //file_text, ok := os.read_entire_file(filename, allocator = context.temp_allocator)
    if !ok {
        log.error("Unable to read entire config file.")
    }
    
    u: UserConfiguration

    sc: scanner.Scanner
    scanner.init(&sc, string(file_text))
    log.debugf("Using scanner: %#v", sc)
    
    // Consume tokens in groups of three
    // key, =, value
    key_tok := scanner.scan(&sc)
    key_str := scanner.token_text(&sc)
    //key_str := strings.clone(scanner.token_text(&sc), allocator = context.allocator)
    for key_tok != scanner.EOF {
        scanner.scan(&sc)
        eq_tok := scanner.token_text(&sc)
        if eq_tok != "=" {
            log.errorf("Expected '=', found %v", eq_tok)
        }

        scanner.scan(&sc)
        val_tok := scanner.token_text(&sc)
        if val_tok == "true" do u.flags[key_str] = true
        else if val_tok == "false" do u.flags[key_str] = false
        else {

        }


        key_tok = scanner.scan(&sc)
        key_str = scanner.token_text(&sc)
    }



    return u
}