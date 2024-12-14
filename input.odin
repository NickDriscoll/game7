package main

import "core:c"
import "core:log"

import "vendor:sdl2"

import imgui "odin-imgui"

VerbType :: enum {
    Quit,
    MoveWindow,
    ResizeWindow,
    MinimizeWindow,
    FocusWindow,
    MouseMotion,
    ToggleImgui,
    ToggleMouseLook,
    TranslateFreecamLeft,
    TranslateFreecamRight,
    TranslateFreecamForward,
    TranslateFreecamBack,
    TranslateFreecamDown,
    TranslateFreecamUp,
    Sprint,
    Crawl,
}

AppVerb :: struct($ValueType: typeid) {
    type: VerbType,
    value: ValueType
}

InputState :: struct {
    key_mappings: map[sdl2.Scancode]VerbType,
    mouse_mappings: map[u8]VerbType,
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

    return InputState {
        key_mappings = key_mappings,
        mouse_mappings = mouse_mappings
    }
}

destroy_input_state :: proc(using s: ^InputState) {
    delete(key_mappings)
    delete(mouse_mappings)
    if controller_one != nil do sdl2.GameControllerClose(controller_one)
}

// Main once-per-frame input proc
pump_sdl2_events :: proc(
    using state: ^InputState,
    imgui_wants_keyboard: bool,
    imgui_wants_mouse: bool,
    allocator := context.temp_allocator
) -> OutputVerbs {
    
    outputs: OutputVerbs
    outputs.bools = make([dynamic]AppVerb(bool), 0, 16, allocator)
    outputs.ints = make([dynamic]AppVerb(i64), 0, 16, allocator)
    outputs.int2s = make([dynamic]AppVerb([2]i64), 0, 16, allocator)
    outputs.floats = make([dynamic]AppVerb(f32), 0, 16, allocator)
    outputs.float2s = make([dynamic]AppVerb([2]f32), 0, 16, allocator)

    //using viewport_camera

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
                imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.scancode), true)

                // Do nothing if Dear ImGUI wants keyboard input
                if imgui_wants_keyboard do continue

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
                    value = {i64(event.motion.xrel), i64(event.motion.yrel)}
                })
                imgui.IO_AddMousePosEvent(io, f32(event.motion.x), f32(event.motion.y))
            }
            case .MOUSEWHEEL: {
                imgui.IO_AddMouseWheelEvent(io, f32(event.wheel.x), f32(event.wheel.y))
            }
            case .CONTROLLERDEVICEADDED: {
                controller_idx := event.cdevice.which
                controller_one = sdl2.GameControllerOpen(controller_idx)
                log.debugf("Controller %v connected.", controller_idx)
            }
            case .CONTROLLERDEVICEREMOVED: {
                controller_idx := event.cdevice.which
                if controller_idx == 0 {
                    sdl2.GameControllerClose(controller_one)
                    controller_one = nil
                }
                log.debugf("Controller %v removed.", controller_idx)
            }
            case .CONTROLLERBUTTONDOWN: {
                log.debug(sdl2.GameControllerGetStringForButton(sdl2.GameControllerButton(event.cbutton.button)))
                // if sdl2.GameControllerRumble(controller_one, 0xFFFF, 0xFFFF, 500) != 0 {
                //     log.error("Rumble not supported!")
                // }
            }
            case .CONTROLLERAXISMOTION: {
                corrected_value := f32(event.caxis.value) / sdl2.JOYSTICK_AXIS_MAX
                log.debugf("Axis %v motion: %v", event.caxis.axis, corrected_value)
            }
            case: {
                //log.debugf("Unhandled event: %v", event.type)
            }
        }
    }

    return outputs
}
