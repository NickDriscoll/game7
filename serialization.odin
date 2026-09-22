package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/linalg/hlsl"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "vendor:sdl2"

import vkw "desktop_vulkan_wrapper"

LEVEL_FILE_VERSION :: 1
LEVEL_FILE_MAGIC_STRING :: "katawari"

BlockType :: enum {
    Transform,
    TransformDelta,
    CharacterController,
    EnemyAI,
    HoveringEnemy,
    ThrownEnemyAI,
    SphericalBody,
    TriangleMesh,
    StaticModelInstance,
    SkinnedModelInstance,
    DebugModelInstance,
    ParentEntity,
}

load_level_file :: proc(
    app: ^App,
    path: string,
    scene_allocator := context.allocator
) -> bool {
    // Audio lock while loading level data
    sdl2.LockAudioDevice(app.audio_system.device_id)
    defer sdl2.UnlockAudioDevice(app.audio_system.device_id)

    vkw.device_wait_idle(&app.vgd)

    read_head : u32 = 0

    lvl_data: []byte
    {
        err: os.Error
        lvl_data, err = os.read_entire_file_from_path(path, context.temp_allocator)
        if err != nil {
            log.errorf("Error reading entire level file \"%v\": %v", path, err)
            return false
        }
    }

    // Read magic string
    magic := read_string_from_buffer(lvl_data, &read_head)
    if magic != LEVEL_FILE_MAGIC_STRING {
        log.errorf("%v has wrong magic string. Aborting level load.", path)
        return false
    }

    // Have to free rendering resources before scene_allocator is reset
    renderer_free_resources(&app.renderer)
    free_all(scene_allocator)
    audio_new_scene(&app.audio_system)
    renderer_new_scene(&app.renderer, scene_allocator)
    gamestate_new_scene(&app.game_state, &app.vgd, &app.renderer, &app.user_config)

    read_thing_from_buffer :: proc(buffer: []byte, $type: typeid, read_head: ^u32) -> type {
        thing: type
        mem.copy_non_overlapping(&thing, &buffer[read_head^], size_of(type))
        read_head^ += size_of(type)
        return thing
    }

    read_string_from_buffer :: proc(buffer: []byte, read_head: ^u32) -> string {
        // Read the u32 string length, then read the string itself
        str_len := read_thing_from_buffer(buffer, u32, read_head)
        s := strings.string_from_ptr(&buffer[read_head^], int(str_len))
        read_head^ += str_len
        return s
    }

    read_naked_string_from_buffer :: proc(buffer: []byte, offset: u32, length: u32) -> string {
        // Precondition: buffer should start at the first byte of the string table

        start_ptr := slice.ptr_add(&buffer[0], int(offset))
        return strings.string_from_ptr(start_ptr, int(length))
    }

    read_component_map :: proc(
        app: ^App,
        buffer: []byte,
        components: ^map[EntityID]$T,
        head: ^u32,
        string_table_offset: u32,
        largest_seen_id: ^u32,
        scene_allocator: runtime.Allocator
    ) {
        // Read component count
        count := read_thing_from_buffer(buffer, u32, head)

        get_model_path :: proc(
            buffer: []byte,
            head: ^u32,
            string_table_offset: u32,
            scene_allocator: runtime.Allocator
        ) -> cstring {
            sb: strings.Builder
            strings.builder_init(&sb, scene_allocator)

            // Read offset and length of model string and then load it
            offset := read_thing_from_buffer(buffer, u32, head)
            length := read_thing_from_buffer(buffer, u32, head)
            model_string := read_naked_string_from_buffer(buffer[string_table_offset:], offset, length)
            fmt.sbprintf(&sb, "data/models/%v", model_string)
            return strings.to_cstring(&sb)
        }

        for _ in 0..<count {
            id := read_thing_from_buffer(buffer, EntityID, head)

            comp: T
            when T == TriangleMesh {
                model_path := get_model_path(buffer, head, string_table_offset, scene_allocator)

                tform := app.game_state.transforms[id]  // Works bc transforms are loaded before triangle meshes
                mmat := get_transform_matrix(tform)
                comp = load_static_triangle_mesh(string(model_path), mmat, scene_allocator)
            } else when T == StaticModelInstance {
                comp.pos_offset = read_thing_from_buffer(buffer, hlsl.float3, head)
                comp.flags = read_thing_from_buffer(buffer, InstanceFlags, head)
                model_path := get_model_path(buffer, head, string_table_offset, scene_allocator)
                comp.handle = load_gltf_static_model(&app.vgd, &app.renderer, model_path, scene_allocator)
            } else when T == SkinnedModelInstance {
                comp.pos_offset = read_thing_from_buffer(buffer, hlsl.float3, head)
                comp.flags = read_thing_from_buffer(buffer, InstanceFlags, head)
                comp.anim_idx = read_thing_from_buffer(buffer, u32, head)
                model_path := get_model_path(buffer, head, string_table_offset, scene_allocator)
                comp.handle = load_gltf_skinned_model(&app.renderer, model_path, scene_allocator)
            } else when T == DebugModelInstance {
                comp.pos_offset = read_thing_from_buffer(buffer, hlsl.float3, head)
                comp.color = read_thing_from_buffer(buffer, hlsl.float4, head)
                comp.scale = read_thing_from_buffer(buffer, f32, head)
                model_path := get_model_path(buffer, head, string_table_offset, scene_allocator)
                comp.handle = load_gltf_static_model(&app.vgd, &app.renderer, model_path, scene_allocator)
            } else {
                comp = read_thing_from_buffer(buffer, T, head)
            }

            components[id] = comp

            if u32(id) > largest_seen_id^ {
                largest_seen_id^ = u32(id)
            }
        }
    }

    read_stateless_entities :: proc(buffer: []byte, head: ^u32) -> [dynamic]EntityID {
        ids: [dynamic]EntityID

        size := read_thing_from_buffer(buffer, u32, head)
        if size == 0 {
            return ids
        }
        resize(&ids, size)

        len_bytes := size * size_of(EntityID)
        mem.copy_non_overlapping(&ids[0], &buffer[head^], int(len_bytes))
        head^ += len_bytes

        return ids
    }

    path_builder: strings.Builder
    strings.builder_init(&path_builder, context.temp_allocator)

    largest_saved_entity_id: u32 = 0

    // Read string table global offset
    string_table_offset := read_thing_from_buffer(lvl_data, u32, &read_head)

    // Read player spawn position
    app.game_state.level_start = read_thing_from_buffer(lvl_data, hlsl.float3, &read_head)

    // Read bgm name
    {
        bgm_name := read_string_from_buffer(lvl_data, &read_head)
        fmt.sbprintf(&path_builder, "data/audio/%v.ogg", bgm_name)
        path := strings.to_cstring(&path_builder)
        app.game_state.bgm_id, _ = open_music_file(&app.audio_system, path)
        strings.builder_reset(&path_builder)
    }

    // Read directional light data
    {
        count := read_thing_from_buffer(lvl_data, u32, &read_head)
        app.renderer.directional_light_count = count
        for i in 0..<count {
            light := read_thing_from_buffer(lvl_data, NewDirectionalLight, &read_head)
            app.renderer.directional_lights[i] = NewDirectionalLight {
                yaw = light.yaw,
                pitch = light.pitch,
                color = light.color
            }
        }
    }

    // Read components in order
    read_component_map(app, lvl_data, &app.game_state.transforms, &read_head, string_table_offset, &largest_saved_entity_id, scene_allocator)
    read_component_map(app, lvl_data, &app.game_state.transform_deltas, &read_head, string_table_offset, &largest_saved_entity_id, scene_allocator)
    read_component_map(app, lvl_data, &app.game_state.enemy_ais, &read_head, string_table_offset, &largest_saved_entity_id, scene_allocator)
    read_component_map(app, lvl_data, &app.game_state.hovering_enemies, &read_head, string_table_offset, &largest_saved_entity_id, scene_allocator)
    read_component_map(app, lvl_data, &app.game_state.thrown_enemy_ais, &read_head, string_table_offset, &largest_saved_entity_id, scene_allocator)
    read_component_map(app, lvl_data, &app.game_state.spherical_bodies, &read_head, string_table_offset, &largest_saved_entity_id, scene_allocator)
    read_component_map(app, lvl_data, &app.game_state.triangle_meshes, &read_head, string_table_offset, &largest_saved_entity_id, scene_allocator)
    read_component_map(app, lvl_data, &app.game_state.static_models, &read_head, string_table_offset, &largest_saved_entity_id, scene_allocator)
    read_component_map(app, lvl_data, &app.game_state.skinned_models, &read_head, string_table_offset, &largest_saved_entity_id, scene_allocator)
    read_component_map(app, lvl_data, &app.game_state.debug_models, &read_head, string_table_offset, &largest_saved_entity_id, scene_allocator)

    // Read stateless entities
    app.game_state.looping_animations = read_stateless_entities(lvl_data, &read_head)
    app.game_state.coins = read_stateless_entities(lvl_data, &read_head)

    // Should have read entire buffer
    assert(read_head == string_table_offset)

    app.game_state._next_id = largest_saved_entity_id + 1

    path_base := filepath.stem(path)
    path_clone, err := strings.clone(path_base, scene_allocator)
    if err != nil {
        log.errorf("Error allocating current_level_path string: %v", err)
    }
    app.current_level = path_clone

    // Move players to spawn
    for id in app.game_state.local_players {
        tform := &app.game_state.transforms[id]
        tform.position = app.game_state.level_start
    }

    return true
}

_reencode_level_file :: proc(app: ^App, level_name: string, temp_allocator := context.temp_allocator) {
    sb: strings.Builder
    strings.builder_init(&sb, temp_allocator)

    out_path := fmt.sbprintf(&sb, "data/levels/new_%v.lvl", level_name)
    log.infof("Saving %v...", out_path)
    save_level_file(app, out_path, temp_allocator)
}

_reencode_level_files :: proc(app: ^App, temp_allocator := context.temp_allocator) {
    w: os.Walker
    os.walker_init_path(&w, "data/levels")
	defer os.walker_destroy(&w)

    sb: strings.Builder
    strings.builder_init(&sb, temp_allocator)
    for info in os.walker_walk(&w) {
        level_name := filepath.stem(info.name)
        load_path := fmt.sbprintf(&sb, "data/levels/%v", info.name)
        strings.builder_reset(&sb)
        load_level_file(app, load_path, context.allocator)
        _reencode_level_file(app, level_name, temp_allocator)
    }
}

// Strings in the StringTable are written back-to-back when serialized
// Components can have a pair of u32 (offset, size) to address into it
StringTable :: struct {
    data: [dynamic]StringTableEntry,
    string_map: map[string]int,
    total_len: int
}
StringTableEntry :: struct {
    str: string,
    offset: u32,
}
string_table_init :: proc(capacity: int, allocator := context.allocator) -> StringTable {
    table: StringTable
    table.data = make([dynamic]StringTableEntry, 0, capacity, allocator)
    table.string_map = make(map[string]int, capacity, allocator)
    return table
}
string_table_append :: proc(table: ^StringTable, elem: string) -> StringTableEntry {
    idx, ok := table.string_map[elem]
    if ok {
        return table.data[idx]
    } else {
        entry: StringTableEntry
        l := len(elem)
        entry.str = elem
        entry.offset = u32(table.total_len)
        table.total_len += l
        table.string_map[elem] = len(table.data)
        append(&table.data, entry)
        return entry
    }
}
write_string_table_to_buffer :: proc(buffer: []byte, table: StringTable, head: ^u32) {
    // Because each component stores the offset and length of the strings in the table,
    // we just have to write out each string back-to-back
    for entry in table.data {
        str_len := len(entry.str)
        mem.copy_non_overlapping(&buffer[head^], raw_data(entry.str), str_len)
        head^ += u32(str_len)
    }
}

save_level_file :: proc(
    app: ^App,
    path: string,
    temp_allocator := context.temp_allocator
) {
    // Returns the size in bytes of component when serialized
    get_serialized_size :: proc(renderer: ^Renderer, string_table: ^StringTable, component: $ComponentType) -> int {
        string_table_insert_string :: proc(string_table: ^StringTable, str: string) -> int {
            // This proc returns the size in bytes of _this_
            // instance of the string in the level file
            // u32 offset + length
            size := 2 * size_of(u32)
            seen_it := str in string_table.string_map
            if !seen_it {
                // Only if this is the first time seeing this string
                // do we want to add it's length to the total size
                size += len(str)
                string_table_append(string_table, str)
            }

            return size
        }

        // Each component has it's EntityID written before it
        size := size_of(EntityID)

        when ComponentType == TriangleMesh {
            size += string_table_insert_string(string_table, component.name)
        } else when ComponentType == StaticModelInstance {
            size += size_of(component.pos_offset)
            size += size_of(component.flags)

            // Size of string instance
            model := get_static_model(renderer, component.handle)
            size += string_table_insert_string(string_table, model.name)
        } else when ComponentType == SkinnedModelInstance {
            size += size_of(component.pos_offset)
            size += size_of(component.flags)
            size += size_of(component.anim_idx)

            // Size of string instance
            model := get_skinned_model(renderer, component.handle)
            size += string_table_insert_string(string_table, model.name)
        } else when ComponentType == DebugModelInstance {
            size += size_of(component.pos_offset)
            size += size_of(component.color)
            size += size_of(component.scale)

            // Size of string instance
            model := get_static_model(renderer, component.handle)
            size += string_table_insert_string(string_table, model.name)
        } else {
            // Type doesn't need special handling
            size += size_of(ComponentType)
        }

        return size
    }
    calc_level_file_size :: proc(
        app: ^App,
        string_table: ^StringTable
    ) -> u32 {
        calc_component_map_size :: proc(app: ^App, string_table: ^StringTable, component_map: map[EntityID]$T) -> int {
            size := size_of(u32)
            for _, comp in component_map {
                size += get_serialized_size(&app.renderer, string_table, comp)
            }
            return size
        }

        final_size := 0

        // Magic string
        final_size += size_of(u32)
        final_size += len(LEVEL_FILE_MAGIC_STRING)

        // Global offset of string table
        final_size += size_of(u32)

        // Size of player spawn position
        final_size += size_of(hlsl.float3)

        bgm_string: string
        if len(app.audio_system.music_files) > int(app.game_state.bgm_id) {
            bgm_string = app.audio_system.music_files[app.game_state.bgm_id].name
        }

        // Size of bgm pascal string
        final_size += size_of(u32)
        final_size += size_of(byte) * len(bgm_string)

        // Directional lights count + data
        final_size += size_of(u32)
        final_size += size_of(NewDirectionalLight) * int(app.renderer.directional_light_count)

        // Component data + counts
        final_size += calc_component_map_size(app, string_table, app.game_state.transforms)
        final_size += calc_component_map_size(app, string_table, app.game_state.transform_deltas)
        final_size += calc_component_map_size(app, string_table, app.game_state.enemy_ais)
        final_size += calc_component_map_size(app, string_table, app.game_state.hovering_enemies)
        final_size += calc_component_map_size(app, string_table, app.game_state.thrown_enemy_ais)
        final_size += calc_component_map_size(app, string_table, app.game_state.spherical_bodies)
        final_size += calc_component_map_size(app, string_table, app.game_state.triangle_meshes)
        final_size += calc_component_map_size(app, string_table, app.game_state.static_models)
        final_size += calc_component_map_size(app, string_table, app.game_state.skinned_models)
        final_size += calc_component_map_size(app, string_table, app.game_state.debug_models)

        // Special entities that don't need extra state
        final_size += size_of(u32)
        final_size += len(app.game_state.looping_animations) * size_of(EntityID)
        final_size += size_of(u32)
        final_size += len(app.game_state.coins) * size_of(EntityID)

        // Don't need to compute string table size explicitly bc
        // string sizes are accounted for in get_serialized_size()

        return u32(final_size)
    }

    write_thing_to_buffer :: proc(buffer: []byte, ptr: ^$T, head: ^u32) {
        amount := size_of(T)
        mem.copy_non_overlapping(&buffer[head^], ptr, amount)
        head^ += u32(amount)
    }

    write_string_to_buffer :: proc(buffer: []byte, st: string, head: ^u32) {
        amount := u32(len(st))
        write_thing_to_buffer(buffer, &amount, head)
        mem.copy_non_overlapping(&buffer[head^], raw_data(st), int(amount))
        head^ += amount
    }

    write_component_map :: proc(renderer: ^Renderer, string_table: ^StringTable, buffer: []byte, components: map[EntityID]$T, head: ^u32) {
        write_component_string_to_table :: proc(buffer: []byte, string_table: ^StringTable, str: string, head: ^u32) {
            table_entry := string_table_append(string_table, str)
            l := u32(len(table_entry.str))
            write_thing_to_buffer(buffer, &table_entry.offset, head)
            write_thing_to_buffer(buffer, &l, head)
        }

        component_count := u32(len(components))
        write_thing_to_buffer(buffer, &component_count, head)

        for id, &comp in components {
            id := id
            write_thing_to_buffer(buffer, &id, head)
            when T == TriangleMesh {
                write_component_string_to_table(buffer, string_table, comp.name, head)
            } else when T == StaticModelInstance {
                write_thing_to_buffer(buffer, &comp.pos_offset, head)
                write_thing_to_buffer(buffer, &comp.flags, head)

                model := get_static_model(renderer, comp.handle)
                write_component_string_to_table(buffer, string_table, model.name, head)

            } else when T == SkinnedModelInstance {
                write_thing_to_buffer(buffer, &comp.pos_offset, head)
                write_thing_to_buffer(buffer, &comp.flags, head)
                write_thing_to_buffer(buffer, &comp.anim_idx, head)

                model := get_skinned_model(renderer, comp.handle)
                write_component_string_to_table(buffer, string_table, model.name, head)

            } else when T == DebugModelInstance {
                write_thing_to_buffer(buffer, &comp.pos_offset, head)
                write_thing_to_buffer(buffer, &comp.color, head)
                write_thing_to_buffer(buffer, &comp.scale, head)

                model := get_static_model(renderer, comp.handle)
                write_component_string_to_table(buffer, string_table, model.name, head)
            } else {
                // Directly serialize the component struct
                write_thing_to_buffer(buffer, &comp, head)
            }
        }
    }

    write_stateless_entities :: proc(buffer: []byte, ids: []EntityID, head: ^u32) {
        size := u32(len(ids))
        write_thing_to_buffer(buffer, &size, head)
        if size == 0 {
            return
        }

        len_bytes := size * size_of(EntityID)
        mem.copy_non_overlapping(&buffer[head^], &ids[0], int(len_bytes))
        head^ += len_bytes
    }

    // Set up intermediate buffer for gathering file data
    string_table := string_table_init(64, temp_allocator)
    total_size := calc_level_file_size(app, &string_table)
    write_head : u32 = 0
    output_buffer := make([dynamic]byte, total_size, temp_allocator)

    // Write magic string
    write_string_to_buffer(output_buffer[:], LEVEL_FILE_MAGIC_STRING, &write_head)

    // Write global offset of string table
    {
        global_offset := total_size - u32(string_table.total_len)
        write_thing_to_buffer(output_buffer[:], &global_offset, &write_head)
    }

    // Write player spawn position
    write_thing_to_buffer(output_buffer[:], &app.game_state.level_start, &write_head)

    // Write bgm filename
    if len(app.audio_system.music_files) > int(app.game_state.bgm_id) {
        bgm := &app.audio_system.music_files[app.game_state.bgm_id]
        write_string_to_buffer(output_buffer[:], bgm.name, &write_head)
    } else {
        write_string_to_buffer(output_buffer[:], "", &write_head)
    }

    // Write directional lights data
    {
        count := app.renderer.directional_light_count
        write_thing_to_buffer(output_buffer[:], &count, &write_head)
        for i in 0..<count {
            light := &app.renderer.directional_lights[i]
            write_thing_to_buffer(output_buffer[:], light, &write_head)
        }
    }

    // Write components to file
    write_component_map(&app.renderer, &string_table, output_buffer[:], app.game_state.transforms, &write_head)
    write_component_map(&app.renderer, &string_table, output_buffer[:], app.game_state.transform_deltas, &write_head)
    write_component_map(&app.renderer, &string_table, output_buffer[:], app.game_state.enemy_ais, &write_head)
    write_component_map(&app.renderer, &string_table, output_buffer[:], app.game_state.hovering_enemies, &write_head)
    write_component_map(&app.renderer, &string_table, output_buffer[:], app.game_state.thrown_enemy_ais, &write_head)
    write_component_map(&app.renderer, &string_table, output_buffer[:], app.game_state.spherical_bodies, &write_head)
    write_component_map(&app.renderer, &string_table, output_buffer[:], app.game_state.triangle_meshes, &write_head)
    write_component_map(&app.renderer, &string_table, output_buffer[:], app.game_state.static_models, &write_head)
    write_component_map(&app.renderer, &string_table, output_buffer[:], app.game_state.skinned_models, &write_head)
    write_component_map(&app.renderer, &string_table, output_buffer[:], app.game_state.debug_models, &write_head)

    // Write the looping animations and coins lists
    write_stateless_entities(output_buffer[:], app.game_state.looping_animations[:], &write_head)
    write_stateless_entities(output_buffer[:], app.game_state.coins[:], &write_head)

    write_string_table_to_buffer(output_buffer[:], string_table, &write_head)

    // Should have written exactly as many bytes as were allocated
    assert(write_head == total_size)

    // Actually write the buffer to the file
    lvl_file, lvl_err := os.create(path)
    if lvl_err != nil {
        log.errorf("Error opening level file: %v", lvl_err)
    }
    defer os.close(lvl_file)

    _, err := os.write(lvl_file, output_buffer[:])
    if err != nil {
        log.errorf("Error writing level data: %v", err)
    }

    base_path := filepath.stem(path)
    path_clone, p_err := strings.clone(base_path)
    if p_err != nil {
        log.errorf("Error allocating current_level_path string: %v", err)
    }
    app.current_level = path_clone

    log.infof("Finished saving level to \"%v\"", path)
}
