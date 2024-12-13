package main

import "core:c"
import "core:log"

import "vendor:sdl2"

import imgui "odin-imgui"

ApplicationVerb :: enum {
    Quit,
    ResizeWindow,
    ToggleImgui,
    TranslateFreecamLeft,
    TranslateFreecamRight,
    TranslateFreecamForward,
    TranslateFreecamBack,
    TranslateFreecamDown,
    TranslateFreecamUp,
}

BooleanVerb :: struct {
    type: ApplicationVerb
}

IntegerVerb :: struct {
    type: ApplicationVerb,
    value: i64
}

FloatVerb :: struct {
    type: ApplicationVerb,
    value: f32
}

Float2Verb :: struct {
    type: ApplicationVerb,
    value: [2]f32
}

InputState :: struct {
    key_mappings: map[sdl2.Scancode]ApplicationVerb
}

// Per-frame representation of what actions the
// user wants to perform this frame
OutputVerbs :: struct {
    bools: [dynamic]BooleanVerb,
    ints: [dynamic]IntegerVerb,
    floats: [dynamic]FloatVerb,
    float2s: [dynamic]Float2Verb,
}

init_input_state :: proc() -> InputState {
    key_mappings, err := make(map[sdl2.Scancode]ApplicationVerb, 64)
    if err != nil {
        log.errorf("Error making key map: %v", err)
    }

    // Hardcoded default keybindings
    key_mappings[.ESCAPE] = .ToggleImgui
    key_mappings[.W] = .TranslateFreecamForward
    key_mappings[.S] = .TranslateFreecamBack

    return InputState {
        key_mappings = key_mappings
    }
}

// Main once-per-frame input proc
pump_sdl2_events :: proc(
    using state: ^InputState,
    imgui_wants_keyboard: bool,
    imgui_wants_mouse: bool,
    allocator := context.temp_allocator
) -> OutputVerbs {
    
    outputs: OutputVerbs
    outputs.bools = make([dynamic]BooleanVerb, 16, allocator)
    outputs.ints = make([dynamic]IntegerVerb, 16, allocator)
    outputs.floats = make([dynamic]FloatVerb, 16, allocator)
    outputs.float2s = make([dynamic]Float2Verb, 16, allocator)

    //using viewport_camera

    // Reference to Dear ImGUI io struct
    io := imgui.GetIO()

    event: sdl2.Event
    for sdl2.PollEvent(&event) {
        #partial switch event.type {
            case .QUIT: {
                append(&outputs.bools, BooleanVerb {
                    type = .Quit
                })
            }
            case .WINDOWEVENT: {
                #partial switch (event.window.event) {
                    case .RESIZED: {
                        new_x := event.window.data1
                        new_y := event.window.data2

                        resolution.x = u32(new_x)
                        resolution.y = u32(new_y)

                        io.DisplaySize.x = f32(new_x)
                        io.DisplaySize.y = f32(new_y)

                        vgd.resize_window = true
                    }
                    case .MOVED: {
                        user_config.ints["window_x"] = i64(event.window.data1)
                        user_config.ints["window_y"] = i64(event.window.data2)
                    }
                    case .MINIMIZED: window_minimized = true
                    case .FOCUS_GAINED: window_minimized = false
                }
            }
            case .TEXTINPUT: {
                for ch in event.text.text {
                    if ch == 0x00 do break
                    imgui.IO_AddInputCharacter(io, c.uint(ch))
                }
            }
            case .KEYDOWN: {
                imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.sym), true)

                // Do nothing if Dear ImGUI wants keyboard input
                if imgui_wants_keyboard do continue

                verb, found := key_mappings[event.key.keysym.scancode]
                if found {

                }

                // #partial switch event.key.keysym.sym {
                //     case .ESCAPE: {
                //         append(&outputs.bools, BooleanVerb {
                //             type = .ToggleImgui
                //         })
                //     }
                //     case .W: control_flags += {.MoveForward}
                //     case .S: control_flags += {.MoveBackward}
                //     case .A: control_flags += {.MoveLeft}
                //     case .D: control_flags += {.MoveRight}
                //     case .Q: control_flags += {.MoveDown}
                //     case .E: control_flags += {.MoveUp}
                // }

                // #partial switch event.key.keysym.scancode {
                //     case .LSHIFT: control_flags += {.Speed}
                //     case .LCTRL: control_flags += {.Slow}
                // }
            }
            case .KEYUP: {
                imgui.IO_AddKeyEvent(io, SDL2ToImGuiKey(event.key.keysym.sym), false)
                
                // Do nothing if Dear ImGUI wants keyboard input
                if io.WantCaptureKeyboard do continue

                // #partial switch event.key.keysym.sym {
                //     case .W: control_flags -= {.MoveForward}
                //     case .S: control_flags -= {.MoveBackward}
                //     case .A: control_flags -= {.MoveLeft}
                //     case .D: control_flags -= {.MoveRight}
                //     case .Q: control_flags -= {.MoveDown}
                //     case .E: control_flags -= {.MoveUp}
                // }

                // #partial switch event.key.keysym.scancode {
                //     case .LSHIFT: control_flags -= {.Speed}
                //     case .LCTRL: control_flags -= {.Slow}
                // }
            }
            case .MOUSEBUTTONDOWN: {
                switch event.button.button {
                    case sdl2.BUTTON_LEFT: {
                    }
                    case sdl2.BUTTON_RIGHT: {
                        // Do nothing if Dear ImGUI wants mouse input
                        if io.WantCaptureMouse do continue

                        // The ~ is "symmetric difference" for bit_sets
                        // Basically like XOR
                        // control_flags ~= {.MouseLook}
                        // mlook := .MouseLook in control_flags

                        // sdl2.SetRelativeMouseMode(sdl2.bool(mlook))
                        // if mlook {
                        //     saved_mouse_coords.x = event.button.x
                        //     saved_mouse_coords.y = event.button.y
                        // } else {
                        //     sdl2.WarpMouseInWindow(sdl_window, saved_mouse_coords.x, saved_mouse_coords.y)
                        // }
                    }
                }
                imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), true)
            }
            case .MOUSEBUTTONUP: {
                imgui.IO_AddMouseButtonEvent(io, SDL2ToImGuiMouseButton(event.button.button), false)
            }
            case .MOUSEMOTION: {
                // camera_rotation.x += f32(event.motion.xrel)
                // camera_rotation.y += f32(event.motion.yrel)
                // if .MouseLook not_in control_flags {
                //     imgui.IO_AddMousePosEvent(io, f32(event.motion.x), f32(event.motion.y))
                // }
            }
            case .MOUSEWHEEL: {
                imgui.IO_AddMouseWheelEvent(io, f32(event.wheel.x), f32(event.wheel.y))
            }
            case .CONTROLLERDEVICEADDED: {
                controller_idx := event.cdevice.which
                //controller_one = sdl2.GameControllerOpen(controller_idx)
                log.debugf("Controller %v connected.", controller_idx)
            }
            case .CONTROLLERDEVICEREMOVED: {
                controller_idx := event.cdevice.which
                if controller_idx == 0 {
                    // sdl2.GameControllerClose(controller_one)
                    // controller_one = nil
                }
                log.debugf("Controller %v removed.", controller_idx)
            }
            case .CONTROLLERBUTTONDOWN: {
                log.debug(sdl2.GameControllerGetStringForButton(sdl2.GameControllerButton(event.cbutton.button)))
                // if sdl2.GameControllerRumble(controller_one, 0xFFFF, 0xFFFF, 500) != 0 {
                //     log.error("Rumble not supported!")
                // }
            }
            case: {
                log.debugf("Unhandled event: %v", event.type)
            }
        }
    }
}