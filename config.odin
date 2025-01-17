package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:text/scanner"
import "core:strconv"
import "core:strings"

// Constants for user configuration keys
EXCLUSIVE_FULLSCREEEN_KEY :: "exclusive_fullscreen"
BORDERLESS_FULLSCREEN_KEY :: "borderless_fullscreen"

UserConfiguration :: struct {
    flags: map[string]bool,
    ints: map[string]i64,
    floats: map[string]f64,


    _interner: strings.Intern,
}

init_user_config :: proc(allocator := context.allocator) -> UserConfiguration {
    cfg: UserConfiguration
    cfg.flags = make(map[string]bool, allocator = allocator)

    err := strings.intern_init(&cfg._interner)
    if err != nil {
        log.errorf("Error initializing string interner: %v", err)
    }

    return cfg
}

delete_user_config :: proc(using c: ^UserConfiguration, allocator := context.allocator) {
    strings.intern_destroy(&_interner)
    delete(flags)
    delete(ints)
    delete(floats)
}

save_user_config :: proc(config: ^UserConfiguration, filename: string) {
    sb: strings.Builder
    strings.builder_init(&sb, allocator = context.temp_allocator)
    defer strings.builder_destroy(&sb)

    save_file, err := create_write_file(filename)
    if err != nil {
        log.errorf("Error opening \"%v\" for saving: %v", filename, err)
    }
    defer os.close(save_file)

    // Saving flags
    for key, val in config.flags {
        st := fmt.sbprintfln(&sb, "%v = %v", key, val)
        os.write_string(save_file, st)
        strings.builder_reset(&sb)
    }

    // Saving ints
    for key, val in config.ints {
        st := fmt.sbprintfln(&sb, "%v = %v", key, val)
        os.write_string(save_file, st)
        strings.builder_reset(&sb)
    }

    // Saving floats
    for key, val in config.floats {
        st := fmt.sbprintfln(&sb, "%v = %v", key, val)
        os.write_string(save_file, st)
        strings.builder_reset(&sb)
    }
}

save_default_user_config :: proc(filename: string) {
    out_file, err := create_write_file(filename)
    if err != nil {
        log.errorf("Error opening default user config file: %v", err)
    }
    defer os.close(out_file)

    // Write defaults to file
    os.write_string(out_file, "show_debug_menu = false\n")
    os.write_string(out_file, "show_closest_point = false\n")
    os.write_string(out_file, "freecam_collision = true\n")
    os.write_string(out_file, "exclusive_fullscreen = false\n")
    os.write_string(out_file, "borderless_fullscreen = false\n")
    os.write_string(out_file, "always_on_top = false\n")
    os.write_string(out_file, "show_imgui_demo = false\n")

    os.write_string(out_file, "freecam_x = 0.0\n")
    os.write_string(out_file, "freecam_y = -5.0\n")
    os.write_string(out_file, "freecam_z = 60.0\n")
    os.write_string(out_file, "camera_fov = 1.57079637\n")
    os.write_string(out_file, "freecam_pitch = 0.78539819\n")
    os.write_string(out_file, "freecam_yaw = 0.0\n")
}

load_user_config :: proc(filename: string) -> (UserConfiguration, bool) {
    user_config, ok := raw_load_user_config(filename)
    if !ok {
        log.warn("Failed to load config file. Generating default config.")
        save_default_user_config(filename)

        user_config, ok = raw_load_user_config(filename)
    }

    return user_config, ok
}

raw_load_user_config :: proc(filename: string) -> (c: UserConfiguration, ok: bool) {
    file_text := os.read_entire_file(filename, allocator = context.temp_allocator) or_return

    u := init_user_config()

    sc: scanner.Scanner
    scanner.init(&sc, string(file_text))
    log.debugf("Using scanner: %#v", sc)
    
    // Consume tokens in groups of three
    // key, =, value
    key_tok := scanner.scan(&sc)
    key_str := scanner.token_text(&sc)
    for key_tok != scanner.EOF {
        // Put the key in the internerator
        interned_key, err := strings.intern_get(&u._interner, key_str)
        log.debugf("User cfg key: %v", interned_key)
        if err != nil {
            log.errorf("Error interning key: %v", err)
        }

        scanner.scan(&sc)
        eq_tok := scanner.token_text(&sc)
        if eq_tok != "=" {
            log.errorf("Expected '=', found %v", eq_tok)
        }

        negative_number := false
        scanner.scan(&sc)
        val_tok := scanner.token_text(&sc)
        log.debugf("User cfg value: %v", val_tok)
        if val_tok == "-" {
            negative_number = true
            scanner.scan(&sc)
            val_tok = scanner.token_text(&sc)
        }
        if val_tok == "true"                            do u.flags[interned_key] = true
        else if val_tok == "false"                      do u.flags[interned_key] = false
        else if strings.contains(val_tok, ".") {
            i : f64 = -1 if negative_number else 1
            u.floats[interned_key] = i * strconv.atof(val_tok)
        }
        else                                            do u.ints[interned_key] = i64(strconv.atoi(val_tok))


        key_tok = scanner.scan(&sc)
        key_str = scanner.token_text(&sc)
    }

    return u, true
}

update_user_cfg_camera :: proc(using s: ^UserConfiguration, camera: ^Camera) {
    floats["freecam_x"] = f64(camera.position.x)
    floats["freecam_y"] = f64(camera.position.y)
    floats["freecam_z"] = f64(camera.position.z)
    floats["camera_fov"] = f64(camera.fov_radians)
    // floats["freecam_pitch"] = f64(camera.pitch)
    // floats["freecam_yaw"] = f64(camera.yaw)
}

