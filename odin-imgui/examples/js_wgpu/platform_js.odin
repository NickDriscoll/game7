package imgui_example_js_wgpu

import "core:sys/wasm/js"

import "vendor:wgpu"

import "../../imgui_impl_js"

Platform :: struct {
	initialized: bool,
	exited:      bool,
}

platform_init :: proc() -> bool {
	imgui_impl_js.Init("wgpu-canvas")

	if g.instance == nil {
		js.set_element_style("wgpu-canvas", "display", "none")
		js.set_element_style("unsupported", "display", "block")
		g.platform.exited = true
		return false
	}

	g.surface = wgpu.InstanceCreateSurface(g.instance, &{
		nextInChain = &wgpu.SurfaceSourceCanvasHTMLSelector{
			sType = .SurfaceSourceCanvasHTMLSelector,
			selector = "#wgpu-canvas",
		},
	})

	return true
}

platform_run :: proc() {
	g.platform.initialized = true
}

@(export, link_name="step", private)
_step :: proc(dt: f64) -> (keep_going: bool) {
	context = g.ctx

	if g.platform.exited {
		return false
	}

	if !g.platform.initialized {
		return true
	}

	imgui_impl_js.NewFrame(f32(dt))

	step()

	return true
}

@(fini, private)
_fini :: proc() {
	context = g.ctx

	imgui_impl_js.Shutdown()

	fini()
}
