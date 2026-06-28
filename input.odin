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

VerbType :: enum {
    Quit,

    MoveWindow,
    ResizeWindow,
    MinimizeWindow,
    FocusWindow,

    NewLevel,
    ShowLoadLevel,

    MouseMotion,
    MouseMotionRel,
    ToggleMouseLook,

    ToggleImgui,
    ImguiScaleUp,
    ImguiScaleDown,

    TogglePause,
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

Verb :: struct {
    ty: VerbType,
    allow_repeat: bool,
}

ControllerStickAxis :: enum {
    Left,
    Right
}
stickaxis_to_sdl2 :: proc(axis: ControllerStickAxis) -> [2]sdl2.GameControllerAxis {
    res: [2]sdl2.GameControllerAxis
    switch axis {
        case .Left: { res = {.LEFTX,.LEFTY} }
        case .Right: { res = {.RIGHTX,.RIGHTY} }
    }
    return res
}

VerbRecipient :: enum {
    PlayerOne = 0,
    PlayerTwo = 1,
    PlayerThree = 2,
    PlayerFour = 3,
    System = 4,
}

// @TODO: This would be problematic if any of the enum values here are identical
RemapInput :: struct #raw_union {
    key: sdl2.Scancode,
    button: sdl2.GameControllerButton,
    axis: sdl2.GameControllerAxis,
}

InputStateFlag :: enum {
    MouseClicked,
    MouseHeld,
    MouseReleased,
    CtrlHeld,
    CurrentlyRemapping
}
InputStateFlags :: bit_set[InputStateFlag; u32]

InputSystem :: struct {
    // For the purposes of simple remapping, user code is expected to maintain
    // these maps for the same lifetime as the input system
    key_mappings: [len(VerbRecipient)]^map[sdl2.Scancode]VerbType,
    ctrl_key_mappings: ^map[sdl2.Scancode]VerbType,
    mouse_mappings: [len(VerbRecipient)]^map[u8]VerbType,
    button_mappings: [len(VerbRecipient)]^map[sdl2.GameControllerButton]VerbType,
    wheel_mappings: [len(VerbRecipient)]map[u32]VerbType,
    axis_mappings: [len(VerbRecipient)]map[sdl2.GameControllerAxis]VerbType,
    stick_mappings: [len(VerbRecipient)]map[ControllerStickAxis]VerbType,

    allow_repeat_keys: map[sdl2.Scancode]bool,

    reverse_axes: bit_set[sdl2.GameControllerAxis],
    deadzone_axes: bit_set[sdl2.GameControllerAxis],
    deadzone_sticks: bit_set[ControllerStickAxis],
    axis_sensitivities: [len(sdl2.GameControllerAxis) - 2]f32,
    stick_sensitivities: [len(ControllerStickAxis)]f32,

    control_stick_deadzone: f32,

    state_flags: InputStateFlags,

    mouse_location: [2]i32,

    input_being_remapped: RemapInput,

    //controller_one: ^sdl2.GameController,
    controllers: [MAX_SPLITSCREEN_PLAYERS]^sdl2.GameController,
    controller_instance_ids: [MAX_SPLITSCREEN_PLAYERS]sdl2.JoystickID,
    controller_ids_counter: u32,
}

init_input_system :: proc(allocator := context.allocator) -> InputSystem {
    system: InputSystem

    for recipient in VerbRecipient {

        system.axis_mappings[recipient] = make(map[sdl2.GameControllerAxis]VerbType, 64, allocator)
        system.stick_mappings[recipient] = make(map[ControllerStickAxis]VerbType, 64, allocator)
        system.wheel_mappings[recipient] = make(map[u32]VerbType, 64, allocator)
        system.allow_repeat_keys = make(map[sdl2.Scancode]bool, 64, allocator)
        
        // 0 bc there's just one mouse wheel... right?
        system.wheel_mappings[recipient][0] = .CameraFollowDistance
        
        // Hardcoded axis mappings
        system.axis_mappings[recipient][.TRIGGERRIGHT] = .Sprint
        
        system.stick_mappings[recipient][.Left] = .PlayerTranslate
        system.stick_mappings[recipient][.Right] = .RotateCamera
    }
    clear(&system.axis_mappings[VerbRecipient.System])
    clear(&system.stick_mappings[VerbRecipient.System])
    
    system.axis_sensitivities = {1.0, 1.0, 1.0, 1.0, 1.0, 1.0}
    system.stick_sensitivities = {1.0, 1.0}
    // Stick sensitivities
    system.stick_sensitivities[ControllerStickAxis.Right] = 5.0

    system.allow_repeat_keys[.EQUALS] = true
    system.allow_repeat_keys[.MINUS] = true

    system.reverse_axes = {.LEFTY}
    system.deadzone_axes = {.LEFTX,.LEFTY,.RIGHTX,.RIGHTY}
    system.deadzone_sticks = {.Left,.Right}
    system.control_stick_deadzone = 0.15
    return system
}

destroy_input_system :: proc(s: ^InputSystem) {
    for recipient in VerbRecipient {
        delete(s.wheel_mappings[recipient])
        delete(s.axis_mappings[recipient])
        delete(s.stick_mappings[recipient])
    }
    for &controller in s.controllers {
        if controller != nil {
            sdl2.GameControllerClose(controller)
        }
    }
}

replace_keybindings :: proc(s: ^InputSystem, recipient: VerbRecipient, new_keybindings: ^map[sdl2.Scancode]VerbType) {
    s.key_mappings[recipient] = new_keybindings
}

RecipientVerbs :: struct {
    bools: map[VerbType]bool,
    ints: map[VerbType]i64,
    int2s: map[VerbType][2]i64,
    floats: map[VerbType]f32,
    float2s: map[VerbType][2]f32,
}
init_receipient_verbs :: proc(allocator := context.allocator) -> RecipientVerbs {
    outputs: RecipientVerbs
    outputs.bools = make(map[VerbType]bool, 16, allocator)
    outputs.ints = make(map[VerbType]i64, 16, allocator)
    outputs.int2s = make(map[VerbType][2]i64, 16, allocator)
    outputs.floats = make(map[VerbType]f32, 16, allocator)
    outputs.float2s = make(map[VerbType][2]f32, 16, allocator)
    return outputs
}

// Per-frame representation of what actions the
// user wants to perform this frame
OutputVerbs :: struct {
    recipient_verbs: [len(VerbRecipient)]RecipientVerbs,
    // bools: map[VerbType]bool,
    // ints: map[VerbType]i64,
    // int2s: map[VerbType][2]i64,
    // floats: map[VerbType]f32,
    // float2s: map[VerbType][2]f32,
}

// Main once-per-frame input proc
poll_sdl2_events :: proc(
    state: ^InputSystem,
    allocator := context.temp_allocator
) -> OutputVerbs {

    outputs: OutputVerbs
    for recipient in VerbRecipient {
        outputs.recipient_verbs[recipient] = init_receipient_verbs(allocator)
    }

    state.state_flags -= {.MouseClicked,.MouseReleased}

    // Reference to Dear ImGUI io struct
    io := imgui.GetIO()

    event: sdl2.Event
    for sdl2.PollEvent(&event) {
        
        #partial switch event.type {
            case .QUIT: {
                outputs.recipient_verbs[VerbRecipient.System].bools[.Quit] = true
            }
            case .WINDOWEVENT: {
                #partial switch (event.window.event) {
                    case .RESIZED: {
                        outputs.recipient_verbs[VerbRecipient.System].int2s[.ResizeWindow] = { i64(event.window.data1), i64(event.window.data2) }
                    }
                    case .MOVED: {
                        outputs.recipient_verbs[VerbRecipient.System].int2s[.MoveWindow] = {i64(event.window.data1), i64(event.window.data2)}
                    }
                    case .FOCUS_GAINED: {
                        outputs.recipient_verbs[VerbRecipient.System].bools[.FocusWindow] = true
                    }
                    case .MINIMIZED: {
                        outputs.recipient_verbs[VerbRecipient.System].bools[.MinimizeWindow] = true
                    }
                    case .RESTORED: {
                        outputs.recipient_verbs[VerbRecipient.System].bools[.MinimizeWindow] = false
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
                sc := event.key.keysym.scancode

                // Just ignore if it's a repeat event
                if !state.allow_repeat_keys[sc] && event.key.repeat > 0 {
                    continue
                }

                for key_mappings, recipient in state.key_mappings {
                    // Mappings can be nil
                    if key_mappings == nil {
                        continue
                    }

                    // Handle key remapping here
                    if .CurrentlyRemapping in state.state_flags {
                        verb, ok := key_mappings[state.input_being_remapped.key]
                        if ok {
                            existing_verb, key_exists := key_mappings[sc]
                            if key_exists {
                                log.warnf("Tried to bind key %v that is already bound to %v", sc, existing_verb)
                                state.input_being_remapped.key = nil
                                state.state_flags -= {.CurrentlyRemapping}
                                continue
                            }
    
                            key_mappings[sc] = verb
                            delete_key(key_mappings, state.input_being_remapped.key)
                            state.input_being_remapped.key = nil
                            state.state_flags -= {.CurrentlyRemapping}
                            continue
                        }
                    }

                    imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(sc), true)
    
                    verbtype: VerbType
                    mapping_found: bool
                    if .CtrlHeld in state.state_flags {
                        verbtype, mapping_found = state.ctrl_key_mappings[sc]
                    }

                    // Only dispatch regular key mappings if Dear ImGUI doesn't wants keyboard input
                    if !io.WantCaptureKeyboard {
                        if !mapping_found {
                            verbtype, mapping_found = key_mappings[sc]
                        }
                        
                    }
                    if mapping_found {
                        outputs.recipient_verbs[recipient].bools[verbtype] = true
                    } else {
                        log.debugf("Unbound keypress: %v", event.key.keysym.scancode)
                    }
                }
            }
            case .KEYUP: {
                imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.scancode), false)

                for key_mappings, recipient in state.key_mappings {
                    // Mappings can be nil
                    if key_mappings == nil {
                        continue
                    }

                    verbtype, found := key_mappings[event.key.keysym.scancode]
                    if found {
                        outputs.recipient_verbs[recipient].bools[verbtype] = false
                    }
                }
            }
            case .MOUSEBUTTONDOWN: {
                imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), true)
                if io.WantCaptureMouse {
                    continue
                }
                for mouse_mappings, recipient in state.mouse_mappings {
                    // Mappings can be nil
                    if mouse_mappings == nil {
                        continue
                    }
                    verbtype, found := mouse_mappings[event.button.button]
                    if found {
                        outputs.recipient_verbs[recipient].bools[verbtype] = true
                        outputs.recipient_verbs[recipient].int2s[verbtype] = {i64(event.button.x), i64(event.button.y)}
                    }
                    if event.button.button == sdl2.BUTTON_LEFT {
                        state.state_flags += {.MouseClicked}
                        state.state_flags += {.MouseHeld}
                    }
                }
            }
            case .MOUSEBUTTONUP: {
                imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), false)
                if io.WantCaptureMouse {
                    continue
                }
                for mouse_mappings, recipient in state.mouse_mappings {
                    // Mappings can be nil
                    if mouse_mappings == nil {
                        continue
                    }
                    verbtype, found := mouse_mappings[event.button.button]
                    if found {
                        outputs.recipient_verbs[recipient].bools[verbtype] = false
                        outputs.recipient_verbs[recipient].int2s[verbtype] = {0, 0}
                    }
                    if event.button.button == sdl2.BUTTON_LEFT {
                        state.state_flags -= {.MouseHeld}
                        state.state_flags += {.MouseReleased}
                    }
                }
            }
            case .MOUSEMOTION: {
                old_motion := outputs.recipient_verbs[VerbRecipient.System].int2s[.MouseMotion]
                old_relmotion := outputs.recipient_verbs[VerbRecipient.System].int2s[.MouseMotionRel]
                state.mouse_location.x = event.motion.x
                state.mouse_location.y = event.motion.y
                outputs.recipient_verbs[VerbRecipient.System].int2s[.MouseMotion] = old_motion + {i64(event.motion.x), i64(event.motion.y)}
                outputs.recipient_verbs[VerbRecipient.System].int2s[.MouseMotionRel] = old_relmotion + {i64(event.motion.xrel), i64(event.motion.yrel)}
            }
            case .MOUSEWHEEL: {
                imgui.IO_AddMouseWheelEvent(io, f32(event.wheel.x), f32(event.wheel.y))
                if io.WantCaptureMouse {
                    continue
                }
                for wheel_mappings, recipient in state.wheel_mappings {
                    // Mappings can be nil
                    if wheel_mappings == nil {
                        continue
                    }
                    verbtype, found := wheel_mappings[event.wheel.which]
                    if found {
                        old := outputs.recipient_verbs[recipient].floats[verbtype]
                        outputs.recipient_verbs[recipient].floats[verbtype] = old + f32(event.wheel.y)
                    }
                }
            }
            case .CONTROLLERDEVICEADDED: {
                // Find an empty slot
                controller_idx : i32 = -1
                for i in 0..<MAX_SPLITSCREEN_PLAYERS {
                    if state.controllers[i] == nil {
                        controller_idx = i32(i)
                        break
                    }
                }
                if controller_idx == -1 {
                    log.error("Tried to add controller when four are already connected.")
                    continue
                }

                controller := sdl2.GameControllerOpen(event.cdevice.which)
                assert(controller != nil)
                state.controllers[controller_idx] = controller
                state.controller_instance_ids[controller_idx] = sdl2.JoystickInstanceID(sdl2.GameControllerGetJoystick(controller))
                type := sdl2.GameControllerGetType(controller)
                name := sdl2.GameControllerName(controller)
                led := sdl2.GameControllerHasLED(controller)
                if led {
                    sdl2.GameControllerSetLED(controller, 0xFF, 0x00, 0xFF)
                }
                log.infof("%v connected (%v) at index %v", name, type, controller_idx)
            }
            case .CONTROLLERDEVICEREMOVED: {
                controller_instance := sdl2.JoystickID(event.cdevice.which)
                controller_idx := -1
                for i in 0..<MAX_SPLITSCREEN_PLAYERS {
                    if controller_instance == state.controller_instance_ids[i] {
                        controller_idx = i
                        break
                    }
                }
                assert(controller_idx > -1)
                controller := state.controllers[controller_idx]
                assert(controller != nil)
                sdl2.GameControllerClose(controller)
                state.controllers[controller_idx] = nil
                log.infof("Controller %v removed.", controller_idx)
            }
            case .CONTROLLERBUTTONDOWN: {
                controller_instance := event.cbutton.which
                controller := sdl2.GameControllerFromInstanceID(controller_instance)
                controller_idx: int = -1
                for c, i in state.controllers {
                    if controller == c {
                        controller_idx = i
                        break
                    }
                }
                assert(controller_idx > -1)

                button := sdl2.GameControllerButton(event.cbutton.button)

                // Handle button remapping here
                {
                    button_mappings := state.button_mappings[controller_idx]
                    // Mappings can be nil
                    if button_mappings == nil {
                        log.debugf("Button mapping for controller %v were nil", controller_idx)
                        continue
                    }
                    if .CurrentlyRemapping in state.state_flags {
                        verb, ok := button_mappings[state.input_being_remapped.button]
                        if ok {
                            existing_verb, button_exists := button_mappings[button]
                            if button_exists {
                                log.warnf("Tried to bind button %v that is already bound to %v", button, existing_verb)
                                state.input_being_remapped.key = nil
                                state.state_flags -= {.CurrentlyRemapping}
                                continue
                            }
    
                            button_mappings[button] = verb
                            delete_key(button_mappings, state.input_being_remapped.button)
                            state.input_being_remapped.button = nil
                            state.state_flags -= {.CurrentlyRemapping}
                            continue
                        }
                    }
    
                    verbtype, found := button_mappings[sdl2.GameControllerButton(button)]
                    if found {
                        log.debugf("Sending verb %v to recipient %v", verbtype, VerbRecipient(controller_idx))
                        outputs.recipient_verbs[controller_idx].bools[verbtype] = true
                    }
                }
            }
            case .CONTROLLERBUTTONUP: {
                controller_instance := event.cbutton.which
                controller := sdl2.GameControllerFromInstanceID(controller_instance)
                controller_idx: int = -1
                for c, i in state.controllers {
                    if controller == c {
                        controller_idx = i
                        break
                    }
                }
                assert(controller_idx > -1)
                {
                    button_mappings := state.button_mappings[controller_idx]
                    // Mappings can be nil
                    if button_mappings == nil {
                        continue
                    }
                    verbtype, found := button_mappings[sdl2.GameControllerButton(event.cbutton.button)]
                    if found {
                        outputs.recipient_verbs[controller_idx].bools[verbtype] = false
                    }
                }
            }
            case: {
                log.debugf("Unhandled SDL2 event: %v", event.type)
            }
        }
    }

    // Set imgui mod keys
    io.KeyCtrl = imgui.IsKeyDown(.LeftCtrl) || imgui.IsKeyDown(.RightCtrl)
    io.KeyShift = imgui.IsKeyDown(.LeftShift) || imgui.IsKeyDown(.RightShift)
    io.KeyAlt = imgui.IsKeyDown(.LeftAlt) || imgui.IsKeyDown(.RightAlt)

    // Set input system mod keys
    if io.KeyCtrl {
        state.state_flags += {.CtrlHeld}
    } else {
        state.state_flags -= {.CtrlHeld} 
    }

    // Poll controller axes and emit appropriate verbs
    sticks := []ControllerStickAxis {.Left,.Right}
    for stick_mappings, recipient in state.stick_mappings {
        for stick in sticks {
            verbtype, found := stick_mappings[stick]
            if found {
                axes := stickaxis_to_sdl2(stick)
                controller := state.controllers[recipient]
                x := axis_to_f32(controller, axes[0])
                y := axis_to_f32(controller, axes[1])
                if axes[0] in state.reverse_axes {
                    x = -x
                }
                if axes[1] in state.reverse_axes {
                    y = -y
                }
                dist := math.abs(hlsl.distance(hlsl.float2{0.0, 0.0}, hlsl.float2{x, y}))
                if stick not_in state.deadzone_sticks || dist > state.control_stick_deadzone {
                    sensitivity := state.stick_sensitivities[stick]
                    outputs.recipient_verbs[recipient].float2s[verbtype] = sensitivity * [2]f32{x, y}
                }
            }
        }
    }

    for i in 0..<u32(sdl2.GameControllerAxis.MAX) {
        ax := sdl2.GameControllerAxis(i)
        for axis_mappings, recipient in state.axis_mappings {
            verbtype, found := axis_mappings[ax]
            if found {
                controller := state.controllers[recipient]
                val := axis_to_f32(controller, ax)
                if val == 0.0 {
                    continue
                }
                abval := math.abs(val)
                if ax in state.deadzone_axes && abval <= state.control_stick_deadzone {
                    continue
                }
                if ax in state.reverse_axes {
                    val = -val
                }
    
                sensitivity := state.axis_sensitivities[ax]
    
                outputs.recipient_verbs[recipient].floats[verbtype] = val
            }
        }
    }

    return outputs
}

// @TODO: Clean up proc
input_gui :: proc(s: ^InputSystem, open: ^bool, allocator := context.temp_allocator) {
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
        s: ^InputSystem,
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
            if .CurrentlyRemapping in s.state_flags && remap_value^ == key {
                if imgui.Button(rebind_text) {
                    s.input_being_remapped.key = nil
                    s.state_flags -= {.CurrentlyRemapping}
                }
            } else {
                ks := build_cstring(key, sb, allocator)
                if imgui.Button(ks, {button_width, 0.0}) {
                    remap_value^ = key
                    s.state_flags += {.CurrentlyRemapping}
                }
            }
        }
        imgui.EndTable()
    }

    // Get widest string
    largest_button_width : f32 = imgui.CalcTextSize(BUTTON_REBIND_TEXT).x
    for k, _ in s.key_mappings {
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

            for key_mappings in s.key_mappings {
                display_sorted_table(
                    s,
                    key_mappings,
                    largest_button_width,
                    &s.input_being_remapped.key,
                    KEY_REBIND_TEXT,
                    &sb,
                    allocator
                )
            }
        }

        if imgui.BeginTable("Controller buttons", 2, table_flags) {
            imgui.TableSetupColumn("Verb")
            imgui.TableSetupColumn("Button")
            imgui.TableHeadersRow()

            for button_mappings in s.button_mappings {
                display_sorted_table(
                    s,
                    button_mappings,
                    largest_button_width,
                    &s.input_being_remapped.button,
                    BUTTON_REBIND_TEXT,
                    &sb,
                    allocator
                )
            }
        }

        if imgui.BeginTable("Axes", 2, table_flags) {
            imgui.TableSetupColumn("Verb")
            imgui.TableSetupColumn("Axis")
            imgui.TableHeadersRow()

            for &axis_mappings in s.axis_mappings {
                display_sorted_table(
                    s,
                    &axis_mappings,
                    largest_button_width,
                    &s.input_being_remapped.axis,
                    AXIS_REBIND_TEXT,
                    &sb,
                    allocator
                )
            }
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
        sensitivity_sliders("Axis sensitivities", s.axis_sensitivities[:], &sb, &i, allocator)
        sensitivity_sliders("Stick sensitivities", s.stick_sensitivities[:], &sb, &i, allocator)

        imgui.SliderFloat("Axis deadzone", &s.control_stick_deadzone, 0.0, 0.5)
    }
    imgui.End()
}

axis_to_f32 :: proc(cont: ^sdl2.GameController, axis: sdl2.GameControllerAxis) -> f32 {
    s := sdl2.GameControllerGetAxis(cont, axis)
    return f32(s) / sdl2.JOYSTICK_AXIS_MAX
}
