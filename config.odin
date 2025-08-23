package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:text/scanner"
import "core:strconv"
import "core:strings"
import "core:time"

ConfigKey :: enum {
    ImguiEnabled,
    ShowDebugMenu,
    GraphicsSettings,
    AudioPanel,
    MasterVolume,
    MusicVolume,
    SFXVolume,
    ShowClosestPoint,
    ConfigAutosave,
    FollowCam,
    ShowAllocatorStats,
    CameraFOV,
    CameraConfig,
    ShowImguiDemo,
    InputConfig,
    ShowMemoryTracker,
    FreecamCollision,
    BorderlessFullscreen,
    ExclusiveFullscreen,
    SceneEditor,
    AlwaysOnTop,
    FreecamPitch,
    FreecamYaw,
    FreecamX,
    FreecamY,
    FreecamZ,
    WindowWidth,
    WindowHeight,
    WindowX,
    WindowY,
    WindowConfig,
    StartLevel,
}
CONFIG_KEY_STRINGS : [ConfigKey]string : {
    .ImguiEnabled = "gui_enabled",
    .ShowDebugMenu = "show_debug_menu",
    .GraphicsSettings = "graphics_settings",
    .AudioPanel = "audio_panel",
    .MasterVolume = "master_volume",
    .MusicVolume = "music_volume",
    .SFXVolume = "sfx_volume",
    .CameraConfig = "camera_config",
    .ShowAllocatorStats = "show_allocator_stats",
    .BorderlessFullscreen = "borderless_fullscreen",
    .ExclusiveFullscreen = "exclusive_fullscreen",
    .ShowImguiDemo = "show_imgui_demo",
    .FreecamCollision = "freecam_collision",
    .SceneEditor = "scene_editor",
    .AlwaysOnTop = "always_on_top",
    .ConfigAutosave = "config_autosave",
    .ShowClosestPoint = "show_closest_point",
	.FollowCam = "follow_cam",
	.InputConfig = "input_config",
	.ShowMemoryTracker = "show_memory_tracker",
	.FreecamPitch = "freecam_pitch",
	.FreecamYaw = "freecam_yaw",
	.FreecamX = "freecam_x",
	.FreecamY = "freecam_y",
	.FreecamZ = "freecam_z",
	.WindowWidth = "window_width",
	.WindowHeight = "window_height",
	.WindowX = "window_x",
	.WindowY = "window_y",
    .WindowConfig = "window_config",
    .CameraFOV = "camera_fov",
    .StartLevel = "start_level"
}

UserConfiguration :: struct {
    flags: map[ConfigKey]bool,
    ints: map[ConfigKey]i64,
    floats: map[ConfigKey]f64,
    strs: map[ConfigKey]string,

    last_saved: time.Time,
    autosave: bool,

    _interner: strings.Intern,
}

init_user_config :: proc(allocator := context.allocator) -> UserConfiguration {
    cfg: UserConfiguration
    cfg.flags = make(map[ConfigKey]bool, allocator = allocator)
    cfg.ints = make(map[ConfigKey]i64, allocator = allocator)
    cfg.floats = make(map[ConfigKey]f64, allocator = allocator)
    cfg.strs = make(map[ConfigKey]string, allocator = allocator)

    strings.intern_init(&cfg._interner, allocator = allocator)
    cfg.last_saved = time.now()
    cfg.autosave = true

    return cfg
}

delete_user_config :: proc(using c: ^UserConfiguration, allocator := context.allocator) {
    delete(flags)
    delete(ints)
    delete(floats)
    delete(strs)
    strings.intern_destroy(&_interner)
}

save_user_config :: proc(config: ^UserConfiguration, filename: string) {
    sb: strings.Builder
    strings.builder_init(&sb, allocator = context.temp_allocator)

    save_file, err := create_write_file(filename)
    if err != nil {
        log.errorf("Error opening \"%v\" for saving: %v", filename, err)
    }
    defer os.close(save_file)

    // Saving flags
    for key, val in config.flags {
        cs := CONFIG_KEY_STRINGS
        s := cs[key]
        st := fmt.sbprintfln(&sb, "%v = %v", s, val)
        os.write_string(save_file, st)
        strings.builder_reset(&sb)
    }

    // Saving ints
    for key, val in config.ints {
        cs := CONFIG_KEY_STRINGS
        s := cs[key]
        st := fmt.sbprintfln(&sb, "%v = %v", s, val)
        os.write_string(save_file, st)
        strings.builder_reset(&sb)
    }

    // Saving floats
    for key, val in config.floats {
        cs := CONFIG_KEY_STRINGS
        s := cs[key]
        st := fmt.sbprintfln(&sb, "%v = %f", s, val)
        os.write_string(save_file, st)
        strings.builder_reset(&sb)
    }

    // Saving strings
    for key, val in config.strs {
        cs := CONFIG_KEY_STRINGS
        s := cs[key]
        st := fmt.sbprintfln(&sb, "%v = %v", s, val)
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
    os.write_string(out_file, "scene_editor = false\n")
    os.write_string(out_file, "camera_config = false\n")
    os.write_string(out_file, "follow_cam = true\n")

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
        // Map string to key
        key: Maybe(ConfigKey)
        for k, e in CONFIG_KEY_STRINGS {
            if k == key_str {
                key = e
            }
        }
        assert(key != nil)

        scanner.scan(&sc)
        eq_tok := scanner.token_text(&sc)
        if eq_tok != "=" {
            log.errorf("Expected '=', found \"%v\"", eq_tok)
        }

        negative_number := false
        scanner.scan(&sc)
        val_tok := scanner.token_text(&sc)
        if val_tok == "-" {
            negative_number = true
            scanner.scan(&sc)
            val_tok = scanner.token_text(&sc)
        }
        if val_tok == "true" {
            u.flags[key.?] = true
        }
        else if val_tok == "false" {
            u.flags[key.?] = false
        }
        else if strings.contains(val_tok, ".") {
            i : f64 = -1 if negative_number else 1
            u.floats[key.?] = i * strconv.atof(val_tok)
        }
        else {
            i, oki := strconv.parse_i64(val_tok)
            if oki {
                u.ints[key.?] = i64(i)
            } else {
                its, err := strings.intern_get(&u._interner, val_tok)
                if err != nil {
                    log.errorf("Error interning config string: %v", err)
                }
                u.strs[key.?] = its
            }
        }


        key_tok = scanner.scan(&sc)
        key_str = scanner.token_text(&sc)
    }

    return u, true
}

update_user_cfg_camera :: proc(using s: ^UserConfiguration, camera: ^Camera) {
    flags[.FollowCam] = .Follow in camera.control_flags
    floats[.FreecamX] = f64(camera.position.x)
    floats[.FreecamY] = f64(camera.position.y)
    floats[.FreecamZ] = f64(camera.position.z)
    floats[.CameraFOV] = f64(camera.fov_radians)
    floats[.FreecamPitch] = f64(camera.pitch)
    floats[.FreecamYaw] = f64(camera.yaw)
}

