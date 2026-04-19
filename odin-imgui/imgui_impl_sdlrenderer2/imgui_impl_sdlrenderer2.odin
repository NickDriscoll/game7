package imgui_impl_sdlrenderer2

import imgui "../"
import sdl "vendor:sdl2"

when      ODIN_OS == .Windows { foreign import lib "../imgui_windows_x64.lib" }
else when ODIN_OS == .Linux   { foreign import lib "../imgui_linux_x64.a" }
else when ODIN_OS == .Darwin  {
	when ODIN_ARCH == .amd64 { foreign import lib "../imgui_darwin_x64.a" } else { foreign import lib "../imgui_darwin_arm64.a" }
}

// imgui_impl_sdlrenderer2.h
// Last checked `v1.91.7-docking` (a9cd0f5)
@(link_prefix="ImGui_ImplSDLRenderer2_")
foreign lib {
	Init           :: proc(renderer: ^sdl.Renderer) -> bool ---
	Shutdown       :: proc() ---
	NewFrame       :: proc() ---
	RenderDrawData :: proc(draw_data: ^imgui.DrawData, renderer: ^sdl.Renderer) ---

	// Called by Init/NewFrame/Shutdown
	CreateFontsTexture   :: proc() -> bool ---
	DestroyFontsTexture  :: proc() ---
	CreateDeviceObjects  :: proc() -> bool ---
	DestroyDeviceObjects :: proc() ---
}

// [BETA] Selected render state data shared with callbacks.
// This is temporarily stored in GetPlatformIO().Renderer_RenderState during the ImGui_ImplSDLRenderer2_RenderDrawData() call.
// (Please open an issue if you feel you need access to more data)
RenderState :: struct {
	Renderer: ^sdl.Renderer,
}
