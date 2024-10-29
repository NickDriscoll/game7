package main

import "vendor:sdl2"
import imgui "odin-imgui"

SDL2ToImGuiKey :: proc(keycode: sdl2.Keycode) -> imgui.Key {
    #partial switch (keycode)
    {
        case sdl2.Keycode.TAB: return imgui.Key.Tab;
        case sdl2.Keycode.LEFT: return imgui.Key.LeftArrow;
        case sdl2.Keycode.RIGHT: return imgui.Key.RightArrow;
        case sdl2.Keycode.UP: return imgui.Key.UpArrow;
        case sdl2.Keycode.DOWN: return imgui.Key.DownArrow;
        case sdl2.Keycode.PAGEUP: return imgui.Key.PageUp;
        case sdl2.Keycode.PAGEDOWN: return imgui.Key.PageDown;
        case sdl2.Keycode.HOME: return imgui.Key.Home;
        case sdl2.Keycode.END: return imgui.Key.End;
        case sdl2.Keycode.INSERT: return imgui.Key.Insert;
        case sdl2.Keycode.DELETE: return imgui.Key.Delete;
        case sdl2.Keycode.BACKSPACE: return imgui.Key.Backspace;
        case sdl2.Keycode.SPACE: return imgui.Key.Space;
        case sdl2.Keycode.RETURN: return imgui.Key.Enter;
        case sdl2.Keycode.ESCAPE: return imgui.Key.Escape;
        case sdl2.Keycode.QUOTE: return imgui.Key.Apostrophe;
        case sdl2.Keycode.COMMA: return imgui.Key.Comma;
        case sdl2.Keycode.MINUS: return imgui.Key.Minus;
        case sdl2.Keycode.PERIOD: return imgui.Key.Period;
        case sdl2.Keycode.SLASH: return imgui.Key.Slash;
        case sdl2.Keycode.SEMICOLON: return imgui.Key.Semicolon;
        case sdl2.Keycode.EQUALS: return imgui.Key.Equal;
        case sdl2.Keycode.LEFTBRACKET: return imgui.Key.LeftBracket;
        case sdl2.Keycode.BACKSLASH: return imgui.Key.Backslash;
        case sdl2.Keycode.RIGHTBRACKET: return imgui.Key.RightBracket;
        case sdl2.Keycode.BACKQUOTE: return imgui.Key.GraveAccent;
        case sdl2.Keycode.CAPSLOCK: return imgui.Key.CapsLock;
        case sdl2.Keycode.SCROLLLOCK: return imgui.Key.ScrollLock;
        case sdl2.Keycode.NUMLOCKCLEAR: return imgui.Key.NumLock;
        case sdl2.Keycode.PRINTSCREEN: return imgui.Key.PrintScreen;
        case sdl2.Keycode.PAUSE: return imgui.Key.Pause;
        case sdl2.Keycode.KP_0: return imgui.Key.Keypad0;
        case sdl2.Keycode.KP_1: return imgui.Key.Keypad1;
        case sdl2.Keycode.KP_2: return imgui.Key.Keypad2;
        case sdl2.Keycode.KP_3: return imgui.Key.Keypad3;
        case sdl2.Keycode.KP_4: return imgui.Key.Keypad4;
        case sdl2.Keycode.KP_5: return imgui.Key.Keypad5;
        case sdl2.Keycode.KP_6: return imgui.Key.Keypad6;
        case sdl2.Keycode.KP_7: return imgui.Key.Keypad7;
        case sdl2.Keycode.KP_8: return imgui.Key.Keypad8;
        case sdl2.Keycode.KP_9: return imgui.Key.Keypad9;
        case sdl2.Keycode.KP_PERIOD: return imgui.Key.KeypadDecimal;
        case sdl2.Keycode.KP_DIVIDE: return imgui.Key.KeypadDivide;
        case sdl2.Keycode.KP_MULTIPLY: return imgui.Key.KeypadMultiply;
        case sdl2.Keycode.KP_MINUS: return imgui.Key.KeypadSubtract;
        case sdl2.Keycode.KP_PLUS: return imgui.Key.KeypadAdd;
        case sdl2.Keycode.KP_ENTER: return imgui.Key.KeypadEnter;
        case sdl2.Keycode.KP_EQUALS: return imgui.Key.KeypadEqual;
        case sdl2.Keycode.LCTRL: return imgui.Key.LeftCtrl;
        case sdl2.Keycode.LSHIFT: return imgui.Key.LeftShift;
        case sdl2.Keycode.LALT: return imgui.Key.LeftAlt;
        case sdl2.Keycode.LGUI: return imgui.Key.LeftSuper;
        case sdl2.Keycode.RCTRL: return imgui.Key.RightCtrl;
        case sdl2.Keycode.RSHIFT: return imgui.Key.RightShift;
        case sdl2.Keycode.RALT: return imgui.Key.RightAlt;
        case sdl2.Keycode.RGUI: return imgui.Key.RightSuper;
        case sdl2.Keycode.APPLICATION: return imgui.Key.Menu;
        case sdl2.Keycode.NUM0: return imgui.Key._0;
        case sdl2.Keycode.NUM1: return imgui.Key._1;
        case sdl2.Keycode.NUM2: return imgui.Key._2;
        case sdl2.Keycode.NUM3: return imgui.Key._3;
        case sdl2.Keycode.NUM4: return imgui.Key._4;
        case sdl2.Keycode.NUM5: return imgui.Key._5;
        case sdl2.Keycode.NUM6: return imgui.Key._6;
        case sdl2.Keycode.NUM7: return imgui.Key._7;
        case sdl2.Keycode.NUM8: return imgui.Key._8;
        case sdl2.Keycode.NUM9: return imgui.Key._9;
        case sdl2.Keycode.a: return imgui.Key.A;
        case sdl2.Keycode.b: return imgui.Key.B;
        case sdl2.Keycode.c: return imgui.Key.C;
        case sdl2.Keycode.d: return imgui.Key.D;
        case sdl2.Keycode.e: return imgui.Key.E;
        case sdl2.Keycode.f: return imgui.Key.F;
        case sdl2.Keycode.g: return imgui.Key.G;
        case sdl2.Keycode.h: return imgui.Key.H;
        case sdl2.Keycode.i: return imgui.Key.I;
        case sdl2.Keycode.j: return imgui.Key.J;
        case sdl2.Keycode.k: return imgui.Key.K;
        case sdl2.Keycode.l: return imgui.Key.L;
        case sdl2.Keycode.m: return imgui.Key.M;
        case sdl2.Keycode.n: return imgui.Key.N;
        case sdl2.Keycode.o: return imgui.Key.O;
        case sdl2.Keycode.p: return imgui.Key.P;
        case sdl2.Keycode.q: return imgui.Key.Q;
        case sdl2.Keycode.r: return imgui.Key.R;
        case sdl2.Keycode.s: return imgui.Key.S;
        case sdl2.Keycode.t: return imgui.Key.T;
        case sdl2.Keycode.u: return imgui.Key.U;
        case sdl2.Keycode.v: return imgui.Key.V;
        case sdl2.Keycode.w: return imgui.Key.W;
        case sdl2.Keycode.x: return imgui.Key.X;
        case sdl2.Keycode.y: return imgui.Key.Y;
        case sdl2.Keycode.z: return imgui.Key.Z;
        case sdl2.Keycode.F1: return imgui.Key.F1;
        case sdl2.Keycode.F2: return imgui.Key.F2;
        case sdl2.Keycode.F3: return imgui.Key.F3;
        case sdl2.Keycode.F4: return imgui.Key.F4;
        case sdl2.Keycode.F5: return imgui.Key.F5;
        case sdl2.Keycode.F6: return imgui.Key.F6;
        case sdl2.Keycode.F7: return imgui.Key.F7;
        case sdl2.Keycode.F8: return imgui.Key.F8;
        case sdl2.Keycode.F9: return imgui.Key.F9;
        case sdl2.Keycode.F10: return imgui.Key.F10;
        case sdl2.Keycode.F11: return imgui.Key.F11;
        case sdl2.Keycode.F12: return imgui.Key.F12;
        case sdl2.Keycode.F13: return imgui.Key.F13;
        case sdl2.Keycode.F14: return imgui.Key.F14;
        case sdl2.Keycode.F15: return imgui.Key.F15;
        case sdl2.Keycode.F16: return imgui.Key.F16;
        case sdl2.Keycode.F17: return imgui.Key.F17;
        case sdl2.Keycode.F18: return imgui.Key.F18;
        case sdl2.Keycode.F19: return imgui.Key.F19;
        case sdl2.Keycode.F20: return imgui.Key.F20;
        case sdl2.Keycode.F21: return imgui.Key.F21;
        case sdl2.Keycode.F22: return imgui.Key.F22;
        case sdl2.Keycode.F23: return imgui.Key.F23;
        case sdl2.Keycode.F24: return imgui.Key.F24;
        case sdl2.Keycode.AC_BACK: return imgui.Key.AppBack;
        case sdl2.Keycode.AC_FORWARD: return imgui.Key.AppForward;
    }
    return imgui.Key.None;
}

SDL2ToImGuiMouseButton :: proc(button: u8) -> i32 {
    button := i32(button)
    switch button {
        case sdl2.BUTTON_MIDDLE: return sdl2.BUTTON_RIGHT - 1
        case sdl2.BUTTON_RIGHT: return sdl2.BUTTON_MIDDLE - 1
    }
    return button - 1
}

