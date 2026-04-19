#+build !js
package imgui_example_js_wgpu

import "core:fmt"

import "vendor:glfw"
import "vendor:wgpu/glfwglue"

import "../../imgui_impl_glfw"

Platform :: struct {
	window: glfw.WindowHandle,
}

platform_init :: proc() -> bool {
	if !glfw.Init() {
		fmt.eprintfln("GLFW Init failed: %v %v", glfw.GetError())
		return false
	}
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)

	g.platform.window = glfw.CreateWindow(1280, 720, "Dear ImGui GLFW+WebGPU example", nil, nil)
	if g.platform.window == nil {
		fmt.eprintfln("GLFW CreateWindow failed: %v %v", glfw.GetError())
		return false
	}

	if !imgui_impl_glfw.InitForOther(g.platform.window, true) {
		fmt.eprintln("imgui_impl_glfw InitForOther failed")
		return false
	}

	g.surface = glfwglue.GetSurface(g.instance, g.platform.window)
	return true
}

platform_run :: proc() {
	for !glfw.WindowShouldClose(g.platform.window) {
		glfw.PollEvents()

		imgui_impl_glfw.NewFrame()
		step()
	}

	imgui_impl_glfw.Shutdown()

	fini()

	glfw.DestroyWindow(g.platform.window)
	glfw.Terminate()
}
