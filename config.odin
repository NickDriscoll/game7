package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:text/scanner"
import "core:strconv"
import "core:strings"

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

save_user_config :: proc(config: ^UserConfiguration, filename: string) {
    save_file, err := os.open(filename, os.O_WRONLY | os.O_CREATE)
    defer os.close(save_file)
    if err != nil {
        log.errorf("Error opening \"%v\" for saving: %v", filename, err)
    }

    sb: strings.Builder
    strings.builder_init(&sb, allocator = context.temp_allocator)
    defer strings.builder_destroy(&sb)

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
    
}

load_user_config :: proc(filename: string) -> (c: UserConfiguration, ok: bool) {
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
        if err != nil {
            log.errorf("Error interning key: %v", err)
        }

        scanner.scan(&sc)
        eq_tok := scanner.token_text(&sc)
        if eq_tok != "=" {
            log.errorf("Expected '=', found %v", eq_tok)
        }

        scanner.scan(&sc)
        val_tok := scanner.token_text(&sc)
        if val_tok == "true"                            do u.flags[interned_key] = true
        else if val_tok == "false"                      do u.flags[interned_key] = false
        else if strings.contains(val_tok, ".")          do u.floats[interned_key] = strconv.atof(val_tok)
        else                                            do u.ints[interned_key] = i64(strconv.atoi(val_tok))


        key_tok = scanner.scan(&sc)
        key_str = scanner.token_text(&sc)
    }

    return u, true
}