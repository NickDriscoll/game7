#+build darwin
package imgui_impl_metal

import imgui "../"
import mtl "vendor:darwin/Metal"

when      ODIN_OS == .Windows { foreign import lib "../imgui_windows_x64.lib" }
else when ODIN_OS == .Linux   { foreign import lib "../imgui_linux_x64.a" }
else when ODIN_OS == .Darwin  {
	when ODIN_ARCH == .amd64 { 
		foreign import lib {
			"../imgui_darwin_x64.a",
			"system:QuartzCore.framework",
		}
	} else {
		foreign import lib {
			"../imgui_darwin_arm64.a",
			"system:QuartzCore.framework",
		}
	}
}

// imgui_impl_metal.h
// Last checked `v1.91.7-docking` (a9cd0f5)
@(link_prefix="ImGui_ImplMetal_")
foreign lib {
	Init           :: proc(device: ^mtl.Device) -> bool ---
	Shutdown       :: proc() ---
	NewFrame       :: proc(renderPassDescriptor: ^mtl.RenderPassDescriptor) ---
	RenderDrawData :: proc(draw_data: ^imgui.DrawData,
						   commandBuffer: ^mtl.CommandBuffer,
						   commandEncoder: ^mtl.RenderCommandEncoder) ---

	// Called by Init/NewFrame/Shutdown
	CreateFontsTexture   :: proc(device: ^mtl.Device) -> bool ---
	DestroyFontsTexture  :: proc() ---
	CreateDeviceObjects  :: proc(device: ^mtl.Device) -> bool ---
	DestroyDeviceObjects :: proc() ---
}
