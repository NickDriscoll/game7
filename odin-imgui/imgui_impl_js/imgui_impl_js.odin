package imgui_impl_js

import       "base:runtime"

import       "core:sys/wasm/js"

import imgui ".."

@(private)
Data :: struct {
	allocator: runtime.Allocator,
	id:        string,
	has_focus: bool,
}

@(private)
GetBackendData :: proc() -> ^Data {
	if imgui.GetCurrentContext() != nil {
		io := imgui.GetIO()
		return (^Data)(io.BackendPlatformUserData)
	}
	return nil
}

Init :: proc(id: string, allocator := context.allocator) {
	io := imgui.GetIO()
	imgui.CHECKVERSION()
	assert(io.BackendPlatformUserData == nil, "Already initialized a platform backend!")

	io.BackendPlatformName = "imgui_impl_js"

	bd := new(Data, allocator)
	io.BackendPlatformUserData = bd
	io.BackendFlags += {.HasMouseCursors, .HasGamepad}

	bd.allocator = allocator
	bd.id = id
	bd.has_focus = true

	js.add_window_event_listener(.Key_Down, nil, on_key_down, true)
	js.add_window_event_listener(.Key_Press, nil, on_key_press, true)
	js.add_window_event_listener(.Key_Up, nil, on_key_up, true)
	js.add_window_event_listener(.Blur, nil, on_blur, true)
	js.add_window_event_listener(.Focus, nil, on_focus, true)

	js.add_event_listener(id, .Pointer_Move, nil, on_pointer_move, true)
	js.add_event_listener(id, .Pointer_Down, nil, on_pointer_down, true)
	js.add_event_listener(id, .Pointer_Up, nil, on_pointer_up, true)
	js.add_event_listener(id, .Wheel, nil, on_wheel, true)

	platform_io := imgui.GetPlatformIO()
	platform_io.Platform_OpenInShellFn = proc "c" (ctx: ^imgui.Context, url: cstring) -> bool {
		js.open(string(url), "_blank")
		return true
	}
}

Shutdown :: proc() {
	bd := GetBackendData()
	io := imgui.GetIO()

	js.remove_window_event_listener(.Key_Down, nil, on_key_down)
	js.remove_window_event_listener(.Key_Press, nil, on_key_press)
	js.remove_window_event_listener(.Key_Up, nil, on_key_up)
	js.remove_window_event_listener(.Blur, nil, on_blur)
	js.remove_window_event_listener(.Focus, nil, on_blur)

	js.remove_event_listener(bd.id, .Pointer_Move, nil, on_pointer_move)
	js.remove_event_listener(bd.id, .Pointer_Down, nil, on_pointer_down)
	js.remove_event_listener(bd.id, .Pointer_Up, nil, on_pointer_up)
	js.remove_event_listener(bd.id, .Wheel, nil, on_wheel)

	allocator := bd.allocator
	free(bd, allocator)

	io.BackendPlatformUserData = nil
	io.BackendFlags -= {.HasMouseCursors, .HasGamepad}
}

NewFrame :: proc(dt: f32) {
	io := imgui.GetIO()
	bd := GetBackendData()

	io.DeltaTime = dt

	last_size := io.DisplaySize * io.DisplayFramebufferScale

	rect := js.get_bounding_client_rect(bd.id)
	dpi  := js.device_pixel_ratio()
	io.DisplaySize             = {f32(rect.width), f32(rect.height)}
	io.DisplayFramebufferScale = {f32(dpi), f32(dpi)}

	size := io.DisplaySize * io.DisplayFramebufferScale
	if (last_size != size) {
		js.set_element_key_f64(bd.id, "width",  f64(size.x))
		js.set_element_key_f64(bd.id, "height", f64(size.y))
	}

	@(static)
	cursors := [imgui.MouseCursor]string {
		.None       = "none",
		.Arrow      = "default",
		.TextInput  = "text",
		.ResizeAll  = "move",
		.ResizeEW   = "ew-resize",
		.ResizeNS   = "ns-resize",
		.ResizeNESW = "nesw-resize",
		.ResizeNWSE = "nwse-resize",
		.Hand       = "grabbing",
		.NotAllowed = "not-allowed",
		.COUNT      = "default",
	}
	js.set_element_style(bd.id, "cursor", cursors[imgui.GetMouseCursor()])

	if bd.has_focus {
		state: js.Gamepad_State
		js.get_gamepad_state(0, &state) // NOTE: is this always 0?
		if state.connected {
			for key := imgui.Key.GamepadStart; key <= imgui.Key.GamepadR3; key += imgui.Key(1) {
				button := translate_gamepad(key, state.mapping)
				if button >= 0 {
					imgui.IO_AddKeyEvent(io, key, state.buttons[button].pressed)
				}
			}

			map_analog :: proc(state: ^js.Gamepad_State, key: imgui.Key, v0, v1: f64) {
				axis := translate_gamepad(key, state.mapping)
				if axis >= 0 {
					v := state.axes[axis]
					v = (v - v0) / (v1 - v0)
					imgui.IO_AddKeyAnalogEvent(imgui.GetIO(), key, v > .10, clamp(f32(v), 0, 1))
				}
			}

			map_analog(&state, .GamepadLStickLeft,  -.25, -1.)
			map_analog(&state, .GamepadLStickRight, +.25, +1.)
			map_analog(&state, .GamepadLStickUp,    -.25, -1.)
			map_analog(&state, .GamepadLStickDown,  +.25, +1.)
			map_analog(&state, .GamepadRStickLeft,  -.25, -1.)
			map_analog(&state, .GamepadRStickRight, +.25, +1.)
			map_analog(&state, .GamepadRStickUp,    -.25, -1.)
			map_analog(&state, .GamepadRStickDown,  +.25, +1.)
		}
	}
}

@(private)
translate_gamepad :: proc(key: imgui.Key, mapping: string) -> int {
	// NOTE: non-standard mappings are not supported.
	if mapping != "standard" {
		return -1
	}

	#partial switch key {
	case .GamepadStart:     return 9 
	case .GamepadBack:      return 8
	case .GamepadFaceLeft:  return 2
	case .GamepadFaceRight: return 1
	case .GamepadFaceUp:    return 3
	case .GamepadFaceDown:  return 0
	case .GamepadDpadLeft:  return 14
	case .GamepadDpadRight: return 15
	case .GamepadDpadUp:    return 12
	case .GamepadDpadDown:  return 13
	case .GamepadL1:        return 4
	case .GamepadR1:        return 5
	case .GamepadL2:        return 6
	case .GamepadR2:        return 7
	case .GamepadL3:        return 10
	case .GamepadR3:        return 11

	// Analog:
	case .GamepadLStickLeft:  return 0
	case .GamepadLStickRight: return 0
	case .GamepadLStickUp:    return 1
	case .GamepadLStickDown:  return 1
	case .GamepadRStickLeft:  return 2
	case .GamepadRStickRight: return 2
	case .GamepadRStickUp:    return 3
	case .GamepadRStickDown:  return 3

	case: unreachable()
	}
}

@(private)
translate_key :: proc(code: string) -> imgui.Key {
	switch code {
	case "Tab":            return .Tab
	case "ArrowLeft":      return .LeftArrow
	case "ArrowRight":     return .RightArrow
	case "ArrowUp":        return .UpArrow
	case "ArrowDown":      return .DownArrow
	case "PageUp":         return .PageUp
	case "PageDown":       return .PageDown
	case "Home":           return .Home
	case "End":            return .End
	case "Insert":         return .Insert
	case "Delete":         return .Delete
	case "Backspace":      return .Backspace
	case "Space":          return .Space
	case "Enter":          return .Enter
	case "Escape":         return .Escape
	case "ControlLeft":    return .LeftCtrl
	case "ShiftLeft":      return .LeftShift
	case "AltLeft":        return .LeftAlt
	case "MetaLeft":       return .LeftSuper
	case "ControlRight":   return .RightCtrl
	case "ShiftRight":     return .RightShift
	case "AltRight":       return .RightAlt
	case "MetaRight":      return .RightSuper
	// case "ContextMenu":    return .Menu
	case "Digit0":         return ._0
	case "Digit1":         return ._1
	case "Digit2":         return ._2
	case "Digit3":         return ._3
	case "Digit4":         return ._4
	case "Digit5":         return ._5
	case "Digit6":         return ._6
	case "Digit7":         return ._7
	case "Digit8":         return ._8
	case "Digit9":         return ._9
	case "KeyA":           return .A
	case "KeyB":           return .B
	case "KeyC":           return .C
	case "KeyD":           return .D
	case "KeyE":           return .E
	case "KeyF":           return .F
	case "KeyG":           return .G
	case "KeyH":           return .H
	case "KeyI":           return .I
	case "KeyJ":           return .J
	case "KeyK":           return .K
	case "KeyL":           return .L
	case "KeyM":           return .M
	case "KeyN":           return .N
	case "KeyO":           return .O
	case "KeyP":           return .P
	case "KeyQ":           return .Q
	case "KeyR":           return .R
	case "KeyS":           return .S
	case "KeyT":           return .T
	case "KeyU":           return .U
	case "KeyV":           return .V
	case "KeyW":           return .W
	case "KeyX":           return .X
	case "KeyY":           return .Y
	case "KeyZ":           return .Z
	case "F1":             return .F1
	case "F2":             return .F2
	case "F3":             return .F3
	case "F4":             return .F4
	case "F5":             return .F5
	case "F6":             return .F6
	case "F7":             return .F7
	case "F8":             return .F8
	case "F9":             return .F9
	case "F10":            return .F10
	case "F11":            return .F11
	case "F12":            return .F12
	case "F13":            return .F13
	case "F14":            return .F14
	case "F15":            return .F15
	case "F16":            return .F16
	case "F17":            return .F17
	case "F18":            return .F18
	case "F19":            return .F19
	case "F20":            return .F20
	case "F21":            return .F21
	case "F22":            return .F22
	case "F23":            return .F23
	case "F24":            return .F24
	case "Quote":          return .Apostrophe
	case "Comma":          return .Comma
	case "Minus":          return .Minus
	case "Period":         return .Period
	case "Slash":          return .Slash
	case "Semicolon":      return .Semicolon
	case "Equal":          return .Equal
	case "BracketLeft":    return .LeftBracket
	case "Backslash":      return .Backslash
	case "BracketRight":   return .RightBracket
	case "Backquote":      return .GraveAccent
	case "CapsLock":       return .CapsLock
	case "ScrollLock":     return .ScrollLock
	case "NumLock":        return .NumLock
	case "PrintScreen":    return .PrintScreen
	case "Pause":          return .Pause
	case "Numpad0":        return .Keypad0
	case "Numpad1":        return .Keypad1
	case "Numpad2":        return .Keypad2
	case "Numpad3":        return .Keypad3
	case "Numpad4":        return .Keypad4
	case "Numpad5":        return .Keypad5
	case "Numpad6":        return .Keypad6
	case "Numpad7":        return .Keypad7
	case "Numpad8":        return .Keypad8
	case "Numpad9":        return .Keypad9
	case "NumpadDecimal":  return .KeypadDecimal
	case "NumpadDivide":   return .KeypadDivide
	case "NumpadMultiply": return .KeypadMultiply
	case "NumpadSubtract": return .KeypadSubtract
	case "NumpadAdd":      return .KeypadAdd
	case "NumpadEnter":    return .KeypadEnter
	case "NumpadEqual":    return .KeypadEqual
	// case "?":              return .AppBack
	// case "?":              return .AppForward

	case:                  return .None
	}
}

@(private)
translate_source :: proc(type: js.Pointer_Type) -> imgui.MouseSource {
	switch type {
	case .Mouse: return .Mouse
	case .Pen:   return .Pen
	case .Touch: return .TouchScreen
	case:        return .Mouse
	}
}

@(private)
update_key_modifiers :: proc(ctrl_ptr: [^]bool) {
	io := imgui.GetIO()
	imgui.IO_AddKeyEvent(io, .ImGuiMod_Ctrl,  ctrl_ptr[0])
	imgui.IO_AddKeyEvent(io, .ImGuiMod_Shift, ctrl_ptr[1])
	imgui.IO_AddKeyEvent(io, .ImGuiMod_Alt,   ctrl_ptr[2])
	imgui.IO_AddKeyEvent(io, .ImGuiMod_Super, ctrl_ptr[3])
}

@(private)
on_key_down :: proc(e: js.Event) {
	key := e.data.key
	update_key_modifiers(&key.ctrl)
	imgui.IO_AddKeyEvent(imgui.GetIO(), translate_key(key.code), true)

	switch key.code {
	case "Backspace", "Tab": js.event_prevent_default()
	}
}

@(private)
on_key_up :: proc(e: js.Event) {
	key := e.data.key
	update_key_modifiers(&key.ctrl)
	imgui.IO_AddKeyEvent(imgui.GetIO(), translate_key(key.code), false)
}

@(private)
on_key_press :: proc(e: js.Event) {
	i := e.data.key
	if i.ctrl || i.meta { return }
	if i.char >= 0x00 && i.char <= 0x1F { return }

	imgui.IO_AddInputCharacter(imgui.GetIO(), u32(i.char))
}

@(private)
on_blur :: proc(e: js.Event) {
	imgui.IO_AddFocusEvent(imgui.GetIO(), false)
	GetBackendData().has_focus = false
}

@(private)
on_focus :: proc(e: js.Event) {
	imgui.IO_AddFocusEvent(imgui.GetIO(), true)
	GetBackendData().has_focus = true
}

@(private)
on_pointer_move :: proc(e: js.Event) {
	io := imgui.GetIO()
	imgui.IO_AddMouseSourceEvent(io, translate_source(e.mouse.pointer.pointer_type))
	imgui.IO_AddMousePosEvent(io, f32(e.mouse.offset.x), f32(e.mouse.offset.y))
}

@(private)
on_pointer_down :: proc(e: js.Event) {
	mouse := e.data.mouse
	update_key_modifiers(&mouse.ctrl)

	mb := imgui.MouseButton(mouse.button)
	if mb >= .Left && mb < .COUNT {
		io := imgui.GetIO()
		imgui.IO_AddMouseSourceEvent(io, translate_source(mouse.pointer.pointer_type))
		imgui.IO_AddMouseButtonEvent(io, i32(mb), true)
	}
}

@(private)
on_pointer_up :: proc(e: js.Event) {
	mouse := e.data.mouse
	update_key_modifiers(&mouse.ctrl)

	mb := imgui.MouseButton(mouse.button)
	if mb >= .Left && mb < .COUNT {
		io := imgui.GetIO()
		imgui.IO_AddMouseSourceEvent(io, translate_source(mouse.pointer.pointer_type))
		imgui.IO_AddMouseButtonEvent(io, i32(mb), false)
	}
}

@(private)
on_wheel :: proc(e: js.Event) {
	multiplier: f64
	switch e.wheel.delta_mode {
	case .Pixel: multiplier = 1. / 100.
	case .Line:  multiplier = 1. / 3.
	case .Page:  multiplier = 80.
	}

	delta := e.scroll.delta * -multiplier
	imgui.IO_AddMouseWheelEvent(imgui.GetIO(), f32(delta.x), f32(delta.y))
	js.event_prevent_default()
}
