package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg/hlsl"
import "core:slice"
import "core:strings"

import "vendor:sdl2"

import imgui "odin-imgui"

AXIS_DEADZONE :: 0.1

VerbType :: enum {
    Quit,

    MoveWindow,
    ResizeWindow,
    MinimizeWindow,
    FocusWindow,
    
    MouseMotion,
    MouseMotionRel,

    ToggleImgui,
    ToggleMouseLook,

    TranslateFreecamLeft,
    TranslateFreecamRight,
    TranslateFreecamForward,
    TranslateFreecamBack,
    TranslateFreecamDown,
    TranslateFreecamUp,

    TranslateFreecamX,
    TranslateFreecamY,
    RotateCamera,

    Sprint,
    Crawl,

    PlaceThing,

    PlayerJump,
    PlayerReset,
    // PlayerTranslateX,
    // PlayerTranslateY,
    PlayerTranslate,
    PlayerTranslateLeft,
    PlayerTranslateRight,
    PlayerTranslateBack,
    PlayerTranslateForward,
}

ControllerStickAxis :: enum {
    Left,
    Right
}

// @TODO: This would be problematic if any of the enum values here are identical
RemapInput :: struct #raw_union {
    key: sdl2.Scancode,
    button: sdl2.GameControllerButton,
    axis: sdl2.GameControllerAxis,
}

InputSystem :: struct {
    // For the purposes of simple remapping, user code is expected to maintain
    // these maps for the same lifetime as the input system
    key_mappings: ^map[sdl2.Scancode]VerbType,
    mouse_mappings: map[u8]VerbType,
    button_mappings: map[sdl2.GameControllerButton]VerbType,
    axis_mappings: map[sdl2.GameControllerAxis]VerbType,
    stick_mappings: map[ControllerStickAxis]VerbType,

    reverse_axes: bit_set[sdl2.GameControllerAxis],
    deadzone_axes: bit_set[sdl2.GameControllerAxis],
    deadzone_sticks: bit_set[ControllerStickAxis],
    axis_sensitivities: map[sdl2.GameControllerAxis]f32,
    stick_sensitivities: map[ControllerStickAxis]f32,

    input_being_remapped: RemapInput,
    currently_remapping: bool,

    controller_one: ^sdl2.GameController,
}

init_input_system :: proc(init_key_bindings: ^map[sdl2.Scancode]VerbType) -> InputSystem {
    mouse_mappings, err2 := make(map[u8]VerbType, 64)
    if err2 != nil {
        log.errorf("Error making mouse map: %v", err2)
    }

    axis_mappings, err3 := make(map[sdl2.GameControllerAxis]VerbType, 64)
    if err3 != nil {
        log.errorf("Error making axis map: %v", err2)
    }

    button_mappings, err4 := make(map[sdl2.GameControllerButton]VerbType, 64)
    if err4 != nil {
        log.errorf("Error making button map: %v", err2)
    }

    stick_mappings, err6 := make(map[ControllerStickAxis]VerbType, 64)
    if err6 != nil {
        log.errorf("Error making stick map: %v", err2)
    }

    axis_sensitivities, err5 := make(map[sdl2.GameControllerAxis]f32, 8)
    if err5 != nil {
        log.errorf("Error making axis sensitivity map: %v", err2)
    }

    stick_sensitivities, err7 := make(map[ControllerStickAxis]f32, 8)
    if err7 != nil {
        log.errorf("Error making stick sensitivity map: %v", err2)
    }

    // Hardcoded default mouse mappings
    mouse_mappings[sdl2.BUTTON_LEFT] = .PlaceThing
    mouse_mappings[sdl2.BUTTON_RIGHT] = .ToggleMouseLook

    // Hardcoded axis mappings
    // axis_mappings[.LEFTX] = .TranslateFreecamX
    // axis_mappings[.LEFTY] = .TranslateFreecamY
    // axis_mappings[.LEFTX] = .PlayerTranslateX
    // axis_mappings[.LEFTY] = .PlayerTranslateY
    // axis_mappings[.RIGHTX] = .RotateFreecamX
    // axis_mappings[.RIGHTY] = .RotateFreecamY
    axis_mappings[.TRIGGERRIGHT] = .Sprint

    // Stick sensitivities
    //stick_sensitivities[.Left] = 5.0
    stick_sensitivities[.Right] = 5.0

    // Hardcoded button mappings
    button_mappings[.A] = .PlayerJump
    button_mappings[.Y] = .PlayerReset
    button_mappings[.LEFTSHOULDER] = .TranslateFreecamDown
    button_mappings[.RIGHTSHOULDER] = .TranslateFreecamUp

    stick_mappings[.Left] = .PlayerTranslate
    stick_mappings[.Right] = .RotateCamera

    return InputSystem {
        key_mappings = init_key_bindings,
        mouse_mappings = mouse_mappings,
        button_mappings = button_mappings,
        axis_mappings = axis_mappings,
        stick_mappings = stick_mappings,
        reverse_axes = {.LEFTY},
        deadzone_axes = {.LEFTX,.LEFTY,.RIGHTX,.RIGHTY},
        deadzone_sticks = {.Left,.Right},
        axis_sensitivities = axis_sensitivities,
        stick_sensitivities = stick_sensitivities,
    }
}

destroy_input_system :: proc(using s: ^InputSystem) {
    delete(mouse_mappings)
    delete(button_mappings)
    delete(axis_mappings)
    delete(axis_sensitivities)
    delete(stick_mappings)
    delete(stick_sensitivities)
    if controller_one != nil do sdl2.GameControllerClose(controller_one)
}

default_axis_mappings :: proc(using s: ^InputSystem) {

}

replace_keybindings :: proc(using s: ^InputSystem, new_keybindings: ^map[sdl2.Scancode]VerbType) {
    key_mappings = new_keybindings
}

// Per-frame representation of what actions the
// user wants to perform this frame
OutputVerbs :: struct {
    bools: map[VerbType]bool,
    ints: map[VerbType]i64,
    int2s: map[VerbType][2]i64,
    floats: map[VerbType]f32,
    float2s: map[VerbType][2]f32,
}

// Main once-per-frame input proc
poll_sdl2_events :: proc(
    using state: ^InputSystem,
    allocator := context.temp_allocator
) -> OutputVerbs {
    
    outputs: OutputVerbs
    outputs.bools = make(map[VerbType]bool, 16, allocator)
    outputs.ints = make(map[VerbType]i64, 16, allocator)
    outputs.int2s = make(map[VerbType][2]i64, 16, allocator)
    outputs.floats = make(map[VerbType]f32, 16, allocator)
    outputs.float2s = make(map[VerbType][2]f32, 16, allocator)
    using outputs

    // Reference to Dear ImGUI io struct
    io := imgui.GetIO()

    event: sdl2.Event
    for sdl2.PollEvent(&event) {
        #partial switch event.type {
            case .QUIT: {
                bools[.Quit] = true
            }
            case .WINDOWEVENT: {
                #partial switch (event.window.event) {
                    case .RESIZED: {
                        int2s[.ResizeWindow] = { i64(event.window.data1), i64(event.window.data2) }
                    }
                    case .MOVED: {
                        int2s[.MoveWindow] = {i64(event.window.data1), i64(event.window.data2)}
                    }
                    case .FOCUS_GAINED: {
                        bools[.FocusWindow] = true
                    }
                    case .MINIMIZED: {
                        bools[.MinimizeWindow] = true
                    }
                }
            }
            case .TEXTINPUT: {
                for ch in event.text.text {
                    if ch == 0x00 do break
                    imgui.IO_AddInputCharacter(io, c.uint(ch))
                }
            }
            case .KEYDOWN: {
                sc := event.key.keysym.scancode

                // Handle key remapping here
                if currently_remapping {
                    verb, ok := key_mappings[input_being_remapped.key]
                    if ok {
                        existing_verb, key_exists := key_mappings[sc]
                        if key_exists {
                            log.warnf("Tried to bind key %v that is already bound to %v", sc, existing_verb)
                            input_being_remapped.key = nil
                            currently_remapping = false
                            continue
                        }

                        key_mappings[sc] = verb
                        delete_key(key_mappings, input_being_remapped.key)
                        input_being_remapped.key = nil
                        currently_remapping = false
                        continue
                    }
                }

                imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(sc), true)

                // Do nothing if Dear ImGUI wants keyboard input
                if io.WantCaptureKeyboard do continue

                verbtype, found := key_mappings[sc]
                if found {
                    bools[verbtype] = true
                }
            }
            case .KEYUP: {
                imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.scancode), false)
                
                // Do nothing if Dear ImGUI wants keyboard input
                if io.WantCaptureKeyboard do continue

                verbtype, found := key_mappings[event.key.keysym.scancode]
                if found {
                    bools[verbtype] = false
                }
            }
            case .MOUSEBUTTONDOWN: {
                verbtype, found := mouse_mappings[event.button.button]
                if found {
                    int2s[verbtype] = {i64(event.button.x), i64(event.button.y)}
                }

                imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), true)
            }
            case .MOUSEBUTTONUP: {
                verbtype, found := mouse_mappings[event.button.button]
                if found {
                    int2s[verbtype] = {0, 0}
                }
                imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), false)
            }
            case .MOUSEMOTION: {
                old_motion := int2s[.MouseMotion]
                old_relmotion := int2s[.MouseMotionRel]
                int2s[.MouseMotion] = old_motion + {i64(event.motion.x), i64(event.motion.y)}
                int2s[.MouseMotionRel] = old_relmotion + {i64(event.motion.xrel), i64(event.motion.yrel)}
            }
            case .MOUSEWHEEL: {
                log.info(event.wheel.which)
                imgui.IO_AddMouseWheelEvent(io, f32(event.wheel.x), f32(event.wheel.y))
            }
            case .CONTROLLERDEVICEADDED: {
                controller_idx := event.cdevice.which
                controller_one = sdl2.GameControllerOpen(controller_idx)
                type := sdl2.GameControllerGetType(controller_one)
                name := sdl2.GameControllerName(controller_one)
                led := sdl2.GameControllerHasLED(controller_one)
                if led do sdl2.GameControllerSetLED(controller_one, 0xFF, 0x00, 0xFF)
                log.infof("%v connected (%v)", name, type)
            }
            case .CONTROLLERDEVICEREMOVED: {
                controller_idx := event.cdevice.which
                if controller_idx == 0 {
                    sdl2.GameControllerClose(controller_one)
                    controller_one = nil
                }
                log.infof("Controller %v removed.", controller_idx)
            }
            case .CONTROLLERBUTTONDOWN: {
                button := sdl2.GameControllerButton(event.cbutton.button)

                // Handle button remapping here
                if currently_remapping {
                    verb, ok := button_mappings[input_being_remapped.button]
                    if ok {
                        existing_verb, button_exists := button_mappings[button]
                        if button_exists {
                            log.warnf("Tried to bind button %v that is already bound to %v", button, existing_verb)
                            input_being_remapped.key = nil
                            currently_remapping = false
                            continue
                        }
                        
                        button_mappings[button] = verb
                        delete_key(&button_mappings, input_being_remapped.button)
                        input_being_remapped.button = nil
                        currently_remapping = false
                        continue
                    }
                }

                verbtype, found := button_mappings[sdl2.GameControllerButton(button)]
                if found {
                    bools[verbtype] = true
                }
            }
            case .CONTROLLERBUTTONUP: {
                verbtype, found := button_mappings[sdl2.GameControllerButton(event.cbutton.button)]
                if found {
                    bools[verbtype] = false
                }
            }
            case: {
                //log.debugf("Unhandled event: %v", event.type)
            }
        }
    }
    
    // Set imgui mod keys
    io.KeyCtrl = imgui.IsKeyDown(.LeftCtrl) || imgui.IsKeyDown(.RightCtrl)
    io.KeyShift = imgui.IsKeyDown(.LeftShift) || imgui.IsKeyDown(.RightShift)
    io.KeyAlt = imgui.IsKeyDown(.LeftAlt) || imgui.IsKeyDown(.RightAlt)

    // Poll controller axes and emit appropriate verbs
    {
        stick := ControllerStickAxis.Left
        verbtype, found := stick_mappings[stick]
        if found {
            x := axis_to_f32(controller_one, .LEFTX)
            y := axis_to_f32(controller_one, .LEFTY)
            if .LEFTX in reverse_axes do x = -x
            if .LEFTY in reverse_axes do y = -y
            dist := math.abs(hlsl.distance(hlsl.float2{0.0, 0.0}, hlsl.float2{x, y}))
            if stick not_in deadzone_sticks || dist > AXIS_DEADZONE {
                sensitivity, found2 := stick_sensitivities[.Left]
                if !found2 do sensitivity = 1.0
                float2s[verbtype] = sensitivity * [2]f32{x, y}
            }
        }
    }
    {
        stick := ControllerStickAxis.Right
        verbtype, found := stick_mappings[stick]
        if found {
            x := axis_to_f32(controller_one, .RIGHTX)
            y := axis_to_f32(controller_one, .RIGHTY)
            if .RIGHTX in reverse_axes do x = -x
            if .RIGHTY in reverse_axes do y = -y
            dist := math.abs(hlsl.distance(hlsl.float2{0.0, 0.0}, hlsl.float2{x, y}))
            if stick not_in deadzone_sticks || dist > AXIS_DEADZONE {
                sensitivity, found2 := stick_sensitivities[.Right]
                if !found2 do sensitivity = 1.0
                float2s[verbtype] = sensitivity * [2]f32{x, y}
            }   
        }
    }

    for i in 0..<u32(sdl2.GameControllerAxis.MAX) {
        ax := sdl2.GameControllerAxis(i)

        verbtype, found := axis_mappings[ax]
        if found {
            val := axis_to_f32(controller_one, ax)
            if val == 0.0 do continue
            abval := math.abs(val)
            if ax in deadzone_axes && abval <= AXIS_DEADZONE do continue
            if ax in reverse_axes do val = -val
        
            sensitivity, found2 := axis_sensitivities[ax]
            if found2 do val *= sensitivity

            floats[verbtype] = val
        }
    }

    return outputs
}

// @TODO: Clean up proc
input_gui :: proc(using s: ^InputSystem, open: ^bool, allocator := context.temp_allocator) {
    sb: strings.Builder
    strings.builder_init(&sb, allocator)
    defer strings.builder_destroy(&sb)

    KEY_REBIND_TEXT :: " --- PUSH ANY KEY TO REBIND --- "
    BUTTON_REBIND_TEXT :: " --- PUSH ANY BUTTON TO REBIND --- "
    AXIS_REBIND_TEXT :: " --- PUSH ANY AXIS TO REBIND --- "

    build_cstring :: proc(x: $T, sb: ^strings.Builder, allocator: runtime.Allocator) -> cstring {
        t_str := fmt.sbprintf(sb, "%v", x)
        defer strings.builder_reset(sb)
        return strings.clone_to_cstring(t_str, allocator)
    }

    display_sorted_table :: proc(
        using s: ^InputSystem,
        m: ^map[$K]$V,
        button_width: f32,
        remap_value: ^K,
        rebind_text: cstring,
        sb: ^strings.Builder,
        allocator: runtime.Allocator
    ) {
        keys := make([dynamic]K, 0, len(m), allocator)
        verbs := make([dynamic]V, 0, len(m), allocator)
        verb_strings := make([dynamic]cstring, 0, len(m), allocator)
        for k, v in m {
            v_str := build_cstring(v, sb, allocator)
            append(&verbs, v)
            append(&verb_strings, v_str)
            append(&keys, k)
        }
        indices := slice.sort_by_with_indices(verb_strings[:], proc(lhs, rhs: cstring) -> bool {
            return strings.compare(string(lhs), string(rhs)) == -1
        }, allocator)

        for i in indices {
            key := keys[i]
            verb := m[key]
            
            imgui.TableNextRow()

            imgui.TableNextColumn()
            vs := build_cstring(verb, sb, allocator)
            imgui.Text(vs)

            imgui.TableNextColumn()
            if currently_remapping && remap_value^ == key {
                if imgui.Button(rebind_text) {
                    input_being_remapped.key = nil
                    currently_remapping = false
                }
            } else {
                ks := build_cstring(key, sb, allocator)
                if imgui.Button(ks, {button_width, 0.0}) {
                    remap_value^ = key
                    currently_remapping = true
                }
            }
        }
        imgui.EndTable()
    }

    // Get widest string
    largest_button_width : f32 = imgui.CalcTextSize(BUTTON_REBIND_TEXT).x
    for k, _ in key_mappings {
        keystr := fmt.sbprintf(&sb, "%v", k)
        ks := strings.clone_to_cstring(keystr, allocator)
        width := imgui.CalcTextSize(ks).x
        if width > largest_button_width do largest_button_width = width
        
        strings.builder_reset(&sb)
    }

    table_flags := imgui.TableFlags_Borders |
                   imgui.TableFlags_RowBg

    if imgui.Begin("Input configuration", open) {
        if imgui.BeginTable("Keybinds", 2, table_flags) {
            imgui.TableSetupColumn("Verb")
            imgui.TableSetupColumn("Key")
            imgui.TableHeadersRow()

            display_sorted_table(
                s,
                key_mappings,
                largest_button_width,
                &input_being_remapped.key,
                KEY_REBIND_TEXT,
                &sb,
                allocator
            )
        }

        if imgui.BeginTable("Controller buttons", 2, table_flags) {
            imgui.TableSetupColumn("Verb")
            imgui.TableSetupColumn("Button")
            imgui.TableHeadersRow()

            display_sorted_table(
                s,
                &button_mappings,
                largest_button_width,
                &input_being_remapped.button,
                BUTTON_REBIND_TEXT,
                &sb,
                allocator
            )
        }

        if imgui.BeginTable("Axes", 2, table_flags) {
            imgui.TableSetupColumn("Verb")
            imgui.TableSetupColumn("Axis")
            imgui.TableHeadersRow()

            display_sorted_table(
                s,
                &axis_mappings,
                largest_button_width,
                &input_being_remapped.axis,
                AXIS_REBIND_TEXT,
                &sb,
                allocator
            )
        }

        imgui.Text("Axis sensitivities")
        imgui.Separator()
        i := 0
        for axis, &sensitivity in axis_sensitivities {
            as := build_cstring(axis, &sb, allocator)
            imgui.Text("%s ", as)
            imgui.SameLine()
            slider_id := fmt.sbprintf(&sb, "Sensitivity###%v", i)
            ss := strings.clone_to_cstring(slider_id, allocator)
            strings.builder_reset(&sb)
            imgui.SliderFloat(ss, &sensitivity, 0.0, 10.0)
            
            i += 1
        }

        imgui.Text("Stick sensitivities")
        imgui.Separator()
        for stick, &sensitivity in stick_sensitivities {
            as := build_cstring(stick, &sb, allocator)
            imgui.Text("%s ", as)
            imgui.SameLine()
            slider_id := fmt.sbprintf(&sb, "Sensitivity###%v", i)
            ss := strings.clone_to_cstring(slider_id, allocator)
            strings.builder_reset(&sb)
            imgui.SliderFloat(ss, &sensitivity, 0.0, 10.0)
            
            i += 1
        }
    }
    imgui.End()
}

axis_to_f32 :: proc(cont: ^sdl2.GameController, axis: sdl2.GameControllerAxis) -> f32 {
    s := sdl2.GameControllerGetAxis(cont, axis)
    return f32(s) / sdl2.JOYSTICK_AXIS_MAX
}
