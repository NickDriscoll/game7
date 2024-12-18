package main

import "core:c"
import "core:fmt"
import "core:log"
import "core:math"
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
    RotateFreecamX,
    RotateFreecamY,

    Sprint,
    Crawl,
}

AppVerb :: struct($ValueType: typeid) {
    type: VerbType,
    value: ValueType
}

InputState :: struct {
    key_mappings: map[sdl2.Scancode]VerbType,
    key_being_remapped: sdl2.Scancode,

    mouse_mappings: map[u8]VerbType,
    button_mappings: map[sdl2.GameControllerButton]VerbType,

    axis_mappings: map[sdl2.GameControllerAxis]VerbType,
    reverse_axes: bit_set[sdl2.GameControllerAxis],
    deadzone_axes: bit_set[sdl2.GameControllerAxis],
    axis_sensitivities: map[sdl2.GameControllerAxis]f32,

    ctrl_pressed: bool,

    controller_one: ^sdl2.GameController,

}

// Per-frame representation of what actions the
// user wants to perform this frame
OutputVerbs :: struct {
    bools: [dynamic]AppVerb(bool),
    ints: [dynamic]AppVerb(i64),
    int2s: [dynamic]AppVerb([2]i64),
    floats: [dynamic]AppVerb(f32),
    float2s: [dynamic]AppVerb([2]f32),
}

init_input_state :: proc() -> InputState {
    key_mappings, err := make(map[sdl2.Scancode]VerbType, 64)
    if err != nil {
        log.errorf("Error making key map: %v", err)
    }

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

    axis_sensitivities, err5 := make(map[sdl2.GameControllerAxis]f32, 8)
    if err5 != nil {
        log.errorf("Error making button map: %v", err2)
    }

    // Hardcoded default keybindings
    key_mappings[.ESCAPE] = .ToggleImgui
    key_mappings[.W] = .TranslateFreecamForward
    key_mappings[.S] = .TranslateFreecamBack
    key_mappings[.A] = .TranslateFreecamLeft
    key_mappings[.D] = .TranslateFreecamRight
    key_mappings[.Q] = .TranslateFreecamDown
    key_mappings[.E] = .TranslateFreecamUp
    key_mappings[.LSHIFT] = .Sprint
    key_mappings[.LCTRL] = .Crawl

    // Hardcoded default mouse mappings
    mouse_mappings[sdl2.BUTTON_RIGHT] = .ToggleMouseLook

    // Hardcoded axis mappings
    axis_mappings[.LEFTX] = .TranslateFreecamX
    axis_mappings[.LEFTY] = .TranslateFreecamY
    axis_mappings[.RIGHTX] = .RotateFreecamX
    axis_mappings[.RIGHTY] = .RotateFreecamY
    axis_mappings[.TRIGGERRIGHT] = .Sprint

    // Axis sensitivities
    axis_sensitivities[.RIGHTX] = 0.02
    axis_sensitivities[.RIGHTY] = 0.02

    // Hardcoded button mappings
    button_mappings[.LEFTSHOULDER] = .TranslateFreecamDown
    button_mappings[.RIGHTSHOULDER] = .TranslateFreecamUp

    return InputState {
        key_mappings = key_mappings,
        mouse_mappings = mouse_mappings,
        button_mappings = button_mappings,
        axis_mappings = axis_mappings,
        reverse_axes = {.LEFTY},
        deadzone_axes = {.LEFTX,.LEFTY,.RIGHTX,.RIGHTY},
        axis_sensitivities = axis_sensitivities
    }
}

destroy_input_state :: proc(using s: ^InputState) {
    delete(key_mappings)
    delete(mouse_mappings)
    delete(axis_mappings)
    if controller_one != nil do sdl2.GameControllerClose(controller_one)
}

// Main once-per-frame input proc
poll_sdl2_events :: proc(
    using state: ^InputState,
    allocator := context.temp_allocator
) -> OutputVerbs {
    
    outputs: OutputVerbs
    outputs.bools = make([dynamic]AppVerb(bool), 0, 16, allocator)
    outputs.ints = make([dynamic]AppVerb(i64), 0, 16, allocator)
    outputs.int2s = make([dynamic]AppVerb([2]i64), 0, 16, allocator)
    outputs.floats = make([dynamic]AppVerb(f32), 0, 16, allocator)
    outputs.float2s = make([dynamic]AppVerb([2]f32), 0, 16, allocator)

    // Reference to Dear ImGUI io struct
    io := imgui.GetIO()

    event: sdl2.Event
    for sdl2.PollEvent(&event) {
        #partial switch event.type {
            case .QUIT: {
                append(&outputs.bools, AppVerb(bool) {
                    type = .Quit,
                    value = true
                })
            }
            case .WINDOWEVENT: {
                #partial switch (event.window.event) {
                    case .RESIZED: {
                        append(&outputs.int2s, AppVerb([2]i64) {
                            type = .ResizeWindow,
                            value = {
                                i64(event.window.data1),
                                i64(event.window.data2)
                            }
                        })
                    }
                    case .MOVED: {
                        append(&outputs.int2s, AppVerb([2]i64) {
                            type = .MoveWindow,
                            value = {i64(event.window.data1), i64(event.window.data2)}
                        })
                    }
                    case .FOCUS_GAINED: {
                        append(&outputs.bools, AppVerb(bool) {
                            type = .FocusWindow,
                            value = true
                        })
                    }
                    case .MINIMIZED: {
                        append(&outputs.bools, AppVerb(bool) {
                            type = .MinimizeWindow,
                            value = true
                        })
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
                // Handle key remapping here
                if key_being_remapped != nil {
                    verb, ok := key_mappings[key_being_remapped]
                    if !ok do log.error("Key remapping fail that should never fail")
                    key_mappings[event.key.keysym.scancode] = verb
                    delete_key(&key_mappings, key_being_remapped)
                    key_being_remapped = nil
                    continue
                }

                imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.scancode), true)
                if event.key.keysym.scancode == .LCTRL || event.key.keysym.scancode == .RCTRL {
                    ctrl_pressed = true
                }

                // Do nothing if Dear ImGUI wants keyboard input
                if io.WantCaptureKeyboard do continue

                verbtype, found := key_mappings[event.key.keysym.scancode]
                if found {
                    append(&outputs.bools, AppVerb(bool) {
                        type = verbtype,
                        value = true
                    })
                }
            }
            case .KEYUP: {
                imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.scancode), false)
                if event.key.keysym.scancode == .LCTRL || event.key.keysym.scancode == .RCTRL {
                    ctrl_pressed = false
                }
                
                // Do nothing if Dear ImGUI wants keyboard input
                if io.WantCaptureKeyboard do continue

                verbtype, found := key_mappings[event.key.keysym.scancode]
                if found {
                    append(&outputs.bools, AppVerb(bool) {
                        type = verbtype,
                        value = false
                    })
                }
            }
            case .MOUSEBUTTONDOWN: {
                verbtype, found := mouse_mappings[event.button.button]
                if found {
                    append(&outputs.int2s, AppVerb([2]i64) {
                        type = verbtype,
                        value = {i64(event.button.x), i64(event.button.y)}
                    }) 
                }

                imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), true)
            }
            case .MOUSEBUTTONUP: {
                imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), false)
            }
            case .MOUSEMOTION: {
                append(&outputs.int2s, AppVerb([2]i64) {
                    type = .MouseMotion,
                    value = {i64(event.motion.x), i64(event.motion.y)}
                })
                append(&outputs.int2s, AppVerb([2]i64) {
                    type = .MouseMotionRel,
                    value = {i64(event.motion.xrel), i64(event.motion.yrel)}
                })
            }
            case .MOUSEWHEEL: {
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
                verbtype, found := button_mappings[sdl2.GameControllerButton(event.cbutton.button)]
                if found {
                    append(&outputs.bools, AppVerb(bool) {
                        type = verbtype,
                        value = true
                    })
                }
            }
            case .CONTROLLERBUTTONUP: {
                verbtype, found := button_mappings[sdl2.GameControllerButton(event.cbutton.button)]
                if found {
                    append(&outputs.bools, AppVerb(bool) {
                        type = verbtype,
                        value = false
                    })
                }
            }
            case: {
                //log.debugf("Unhandled event: %v", event.type)
            }
        }
    }

    // Poll controller axes and emit appropriate verbs
    for i in 0..<u32(sdl2.GameControllerAxis.MAX) {
        ax := sdl2.GameControllerAxis(i)

        verbtype, found := axis_mappings[ax]
        if found {val := axis_to_f32(controller_one, ax)
            if val == 0.0 do continue
            abval := math.abs(val)
            if ax in deadzone_axes && abval <= AXIS_DEADZONE do continue
            if ax in reverse_axes do val = -val
        
            sensitivity, found2 := axis_sensitivities[ax]
            if found2 do val *= sensitivity

            append(&outputs.floats, AppVerb(f32) {
                type = verbtype,
                value = val
            })
        }
    }

    return outputs
}

input_gui :: proc(using s: ^InputState, open: ^bool, allocator := context.temp_allocator) {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)

    if imgui.Begin("Input configuration", open) {
        imgui.Text("Keybindings")
        imgui.Separator()
        for key, verb in key_mappings {
            verbstr := fmt.sbprintf(&sb, "%v", verb)
            vs := strings.clone_to_cstring(verbstr, allocator)
            imgui.Text("%s: ", vs)
            strings.builder_reset(&sb)
            imgui.SameLine()

            if key_being_remapped == key {
                imgui.Button(" --- PRESS KEY TO REBIND --- ")
            } else {
                keystr := fmt.sbprintf(&sb, "%v", key)
                cs := strings.clone_to_cstring(keystr, allocator)
                if imgui.Button(cs) {
                    key_being_remapped = key
                }
            }


            strings.builder_reset(&sb)
        }

        imgui.Text("Axis sensitivities")
        imgui.Separator()
        i := 0
        for axis, &sensitivity in axis_sensitivities {
            axis_str := fmt.sbprintf(&sb, "%v", axis)
            as := strings.clone_to_cstring(axis_str, allocator)
            strings.builder_reset(&sb)
            imgui.Text("%s ", as)
            imgui.SameLine()
            slider_id := fmt.sbprintf(&sb, "Sensitivity###%v", i)
            ss := strings.clone_to_cstring(slider_id, allocator)
            imgui.SliderFloat(ss, &sensitivity, 0.0, 0.1)
            
            strings.builder_reset(&sb)
            i += 1
        }
        i = 0
    }
    imgui.End()
}

axis_to_f32 :: proc(cont: ^sdl2.GameController, axis: sdl2.GameControllerAxis) -> f32 {
    s := sdl2.GameControllerGetAxis(cont, axis)
    return f32(s) / sdl2.JOYSTICK_AXIS_MAX
}
