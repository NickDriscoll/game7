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
    ToggleMouseLook,

    ToggleImgui,

    Resume,
    FrameAdvance,
    FullscreenHotkey,

    TranslateFreecamLeft,
    TranslateFreecamRight,
    TranslateFreecamForward,
    TranslateFreecamBack,
    TranslateFreecamDown,
    TranslateFreecamUp,

    TranslateFreecamX,
    TranslateFreecamY,
    RotateCamera,
    CameraFollowDistance,

    Sprint,
    Crawl,

    PlaceThing,

    PlayerJump,
    PlayerShoot,
    PlayerReset,
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
    mouse_mappings: ^map[u8]VerbType,
    button_mappings: ^map[sdl2.GameControllerButton]VerbType,
    wheel_mappings: map[u32]VerbType,
    axis_mappings: map[sdl2.GameControllerAxis]VerbType,
    stick_mappings: map[ControllerStickAxis]VerbType,

    reverse_axes: bit_set[sdl2.GameControllerAxis],
    deadzone_axes: bit_set[sdl2.GameControllerAxis],
    deadzone_sticks: bit_set[ControllerStickAxis],
    axis_sensitivities: [len(sdl2.GameControllerAxis) - 2]f32,
    stick_sensitivities: [len(ControllerStickAxis)]f32,

    mouse_location: [2]i32,
    mouse_clicked: bool,

    input_being_remapped: RemapInput,
    currently_remapping: bool,

    controller_one: ^sdl2.GameController,
}

init_input_system :: proc(
    init_key_bindings: ^map[sdl2.Scancode]VerbType,
    init_mouse_bindings: ^map[u8]VerbType,
    init_button_mappings: ^map[sdl2.GameControllerButton]VerbType
) -> InputSystem {
    axis_mappings := make(map[sdl2.GameControllerAxis]VerbType, 64)
    stick_mappings := make(map[ControllerStickAxis]VerbType, 64)
    wheel_mappings := make(map[u32]VerbType, 64)
    axis_sensitivities: [len(sdl2.GameControllerAxis) - 2]f32 = {1.0, 1.0, 1.0, 1.0, 1.0, 1.0}
    stick_sensitivities: [len(ControllerStickAxis)]f32 = {1.0, 1.0}

    // 0 bc there's just one mouse wheel... right?
    wheel_mappings[0] = .CameraFollowDistance

    // Hardcoded axis mappings
    axis_mappings[.TRIGGERRIGHT] = .Sprint

    // Stick sensitivities
    stick_sensitivities[ControllerStickAxis.Right] = 5.0

    stick_mappings[.Left] = .PlayerTranslate
    stick_mappings[.Right] = .RotateCamera

    return InputSystem {
        key_mappings = init_key_bindings,
        mouse_mappings = init_mouse_bindings,
        button_mappings = init_button_mappings,
        wheel_mappings = wheel_mappings,
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
    delete(wheel_mappings)
    delete(axis_mappings)
    delete(stick_mappings)
    if controller_one != nil {
        sdl2.GameControllerClose(controller_one)
    }
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
    state: ^InputSystem,
    allocator := context.temp_allocator
) -> OutputVerbs {
    
    outputs: OutputVerbs
    outputs.bools = make(map[VerbType]bool, 16, allocator)
    outputs.ints = make(map[VerbType]i64, 16, allocator)
    outputs.int2s = make(map[VerbType][2]i64, 16, allocator)
    outputs.floats = make(map[VerbType]f32, 16, allocator)
    outputs.float2s = make(map[VerbType][2]f32, 16, allocator)
    using outputs

    state.mouse_clicked = false

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
                    case .MAXIMIZED: {
                        bools[.MinimizeWindow] = false
                    }
                }
            }
            case .TEXTINPUT: {
                for ch in event.text.text {
                    if ch == 0x00 {
                        break
                    }
                    imgui.IO_AddInputCharacter(io, c.uint(ch))
                }
            }
            case .KEYDOWN: {
                // Just ignore if it's a repeat event
                if event.key.repeat > 0 {
                    continue
                }

                sc := event.key.keysym.scancode

                // Handle key remapping here
                if state.currently_remapping {
                    verb, ok := state.key_mappings[state.input_being_remapped.key]
                    if ok {
                        existing_verb, key_exists := state.key_mappings[sc]
                        if key_exists {
                            log.warnf("Tried to bind key %v that is already bound to %v", sc, existing_verb)
                            state.input_being_remapped.key = nil
                            state.currently_remapping = false
                            continue
                        }

                        state.key_mappings[sc] = verb
                        delete_key(state.key_mappings, state.input_being_remapped.key)
                        state.input_being_remapped.key = nil
                        state.currently_remapping = false
                        continue
                    }
                }

                imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(sc), true)

                // Do nothing if Dear ImGUI wants keyboard input
                if io.WantCaptureKeyboard {
                    continue
                }

                verbtype, found := state.key_mappings[sc]
                if found {
                    bools[verbtype] = true
                } else {
                    log.debugf("Unbound keypress: %v", event.key.keysym.scancode)
                }
            }
            case .KEYUP: {
                imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.scancode), false)
                
                // Do nothing if Dear ImGUI wants keyboard input
                if io.WantCaptureKeyboard {
                    continue
                }

                verbtype, found := state.key_mappings[event.key.keysym.scancode]
                if found {
                    bools[verbtype] = false
                }
            }
            case .MOUSEBUTTONDOWN: {
                imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), true)
                if io.WantCaptureMouse {
                    continue
                }
                verbtype, found := state.mouse_mappings[event.button.button]
                if found {
                    bools[verbtype] = true
                    int2s[verbtype] = {i64(event.button.x), i64(event.button.y)}
                }
                if event.button.button == sdl2.BUTTON_LEFT {
                    state.mouse_clicked = true
                }
            }
            case .MOUSEBUTTONUP: {
                imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), false)
                if io.WantCaptureMouse {
                    continue
                }
                verbtype, found := state.mouse_mappings[event.button.button]
                if found {
                    bools[verbtype] = false
                    int2s[verbtype] = {0, 0}
                }
            }
            case .MOUSEMOTION: {
                old_motion := int2s[.MouseMotion]
                old_relmotion := int2s[.MouseMotionRel]
                state.mouse_location.x = event.motion.x
                state.mouse_location.y = event.motion.y
                int2s[.MouseMotion] = old_motion + {i64(event.motion.x), i64(event.motion.y)}
                int2s[.MouseMotionRel] = old_relmotion + {i64(event.motion.xrel), i64(event.motion.yrel)}
            }
            case .MOUSEWHEEL: {
                imgui.IO_AddMouseWheelEvent(io, f32(event.wheel.x), f32(event.wheel.y))
                if io.WantCaptureMouse {
                    continue
                }
                verbtype, found := state.wheel_mappings[event.wheel.which]
                if found {
                    old := floats[verbtype]
                    floats[verbtype] = old + f32(event.wheel.y)
                }
            }
            case .CONTROLLERDEVICEADDED: {
                controller_idx := event.cdevice.which
                state.controller_one = sdl2.GameControllerOpen(controller_idx)
                type := sdl2.GameControllerGetType(state.controller_one)
                name := sdl2.GameControllerName(state.controller_one)
                led := sdl2.GameControllerHasLED(state.controller_one)
                if led {
                    sdl2.GameControllerSetLED(state.controller_one, 0xFF, 0x00, 0xFF)
                }
                log.infof("%v connected (%v)", name, type)
            }
            case .CONTROLLERDEVICEREMOVED: {
                controller_idx := event.cdevice.which
                if controller_idx == 0 {
                    sdl2.GameControllerClose(state.controller_one)
                    state.controller_one = nil
                }
                log.infof("Controller %v removed.", controller_idx)
            }
            case .CONTROLLERBUTTONDOWN: {
                button := sdl2.GameControllerButton(event.cbutton.button)

                // Handle button remapping here
                if state.currently_remapping {
                    verb, ok := state.button_mappings[state.input_being_remapped.button]
                    if ok {
                        existing_verb, button_exists := state.button_mappings[button]
                        if button_exists {
                            log.warnf("Tried to bind button %v that is already bound to %v", button, existing_verb)
                            state.input_being_remapped.key = nil
                            state.currently_remapping = false
                            continue
                        }
                        
                        state.button_mappings[button] = verb
                        delete_key(state.button_mappings, state.input_being_remapped.button)
                        state.input_being_remapped.button = nil
                        state.currently_remapping = false
                        continue
                    }
                }

                verbtype, found := state.button_mappings[sdl2.GameControllerButton(button)]
                if found {
                    bools[verbtype] = true
                }
            }
            case .CONTROLLERBUTTONUP: {
                verbtype, found := state.button_mappings[sdl2.GameControllerButton(event.cbutton.button)]
                if found {
                    bools[verbtype] = false
                }
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
        verbtype, found := state.stick_mappings[stick]
        if found {
            x := axis_to_f32(state.controller_one, .LEFTX)
            y := axis_to_f32(state.controller_one, .LEFTY)
            if .LEFTX in state.reverse_axes {
                x = -x
            }
            if .LEFTY in state.reverse_axes {
                y = -y
            }
            dist := math.abs(hlsl.distance(hlsl.float2{0.0, 0.0}, hlsl.float2{x, y}))
            if stick not_in state.deadzone_sticks || dist > AXIS_DEADZONE {
                sensitivity := state.stick_sensitivities[ControllerStickAxis.Left]
                float2s[verbtype] = sensitivity * [2]f32{x, y}
            }
        }
    }
    {
        stick := ControllerStickAxis.Right
        verbtype, found := state.stick_mappings[stick]
        if found {
            x := axis_to_f32(state.controller_one, .RIGHTX)
            y := axis_to_f32(state.controller_one, .RIGHTY)
            if .RIGHTX in state.reverse_axes {
                x = -x
            }
            if .RIGHTY in state.reverse_axes {
                y = -y
            }
            dist := math.abs(hlsl.distance(hlsl.float2{0.0, 0.0}, hlsl.float2{x, y}))
            if stick not_in state.deadzone_sticks || dist > AXIS_DEADZONE {
                sensitivity:= state.stick_sensitivities[ControllerStickAxis.Right]
                float2s[verbtype] = sensitivity * [2]f32{x, y}
            }   
        }
    }

    for i in 0..<u32(sdl2.GameControllerAxis.MAX) {
        ax := sdl2.GameControllerAxis(i)

        verbtype, found := state.axis_mappings[ax]
        if found {
            val := axis_to_f32(state.controller_one, ax)
            if val == 0.0 {
                continue
            }
            abval := math.abs(val)
            if ax in state.deadzone_axes && abval <= AXIS_DEADZONE {
                continue
            }
            if ax in state.reverse_axes {
                val = -val
            }
        
            sensitivity := state.axis_sensitivities[ax]

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
        if width > largest_button_width {
            largest_button_width = width
        }
        
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
                button_mappings,
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

        sensitivity_sliders :: proc(
            label: cstring,
            sensitivities: []f32,
            sb: ^strings.Builder,
            discriminator: ^u32,
            allocator: runtime.Allocator
        ) {
            if len(sensitivities) == 0 {
                return
            }
            imgui.Text(label)
            imgui.Separator()
            for i in 0..<len(sensitivities) {
                axis := sdl2.GameControllerAxis(i)
                sensitivity := &sensitivities[i]

                as := build_cstring(axis, sb, allocator)
                imgui.Text("%s ", as)
                imgui.SameLine()
                slider_id := fmt.sbprintf(sb, "Sensitivity###%v", discriminator^)
                ss := strings.clone_to_cstring(slider_id, allocator)
                strings.builder_reset(sb)
                imgui.SliderFloat(ss, sensitivity, 0.0, 10.0)
                
                discriminator^ += 1
            }
        }

        i : u32 = 0
        sensitivity_sliders("Axis sensitivities", axis_sensitivities[:], &sb, &i, allocator)
        sensitivity_sliders("Stick sensitivities", stick_sensitivities[:], &sb, &i, allocator)
    }
    imgui.End()
}

axis_to_f32 :: proc(cont: ^sdl2.GameController, axis: sdl2.GameControllerAxis) -> f32 {
    s := sdl2.GameControllerGetAxis(cont, axis)
    return f32(s) / sdl2.JOYSTICK_AXIS_MAX
}
