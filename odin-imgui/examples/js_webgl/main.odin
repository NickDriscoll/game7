package imgui_example_js_webgl

// This is an example of using the bindings with JS and WebGPU.

import    "base:runtime"

import gl "vendor:wasm/webgl"

import im "../.."
import    "../../imgui_impl_webgl"
import    "../../imgui_impl_js"

g := struct {
	ctx: runtime.Context,
}{}

main :: proc() {
	g.ctx = context

	ok := gl.CreateCurrentContextById("webgl-canvas", gl.DEFAULT_CONTEXT_ATTRIBUTES)
	ensure(ok, "Creating context failed!")
	ensure(gl.IsWebGL2Supported(), "WebGL 2 must be supported!")

	gl.SetCurrentContextById("webgl-canvas")

	im.CHECKVERSION()
	im.CreateContext()
	io := im.GetIO()
	io.ConfigFlags += { .NavEnableKeyboard, .NavEnableGamepad, .DockingEnable }

	im.StyleColorsDark()

	imgui_impl_js.Init("webgl-canvas")
	imgui_impl_webgl.Init()
}

@(export)
step :: proc(dt: f64) -> (keep_going: bool) {
	context = g.ctx

	defer free_all(context.temp_allocator)

	imgui_impl_js.NewFrame(f32(dt))
	imgui_impl_webgl.NewFrame()
	im.NewFrame()

	im.ShowDemoWindow()

	if im.Begin("Window containing a quit button") {
		if im.Button("The quit button in question") {
			return false
		}
	}
	im.End()

	im.Render()

	gl.ClearColor(0, 0, 0, 1)
	gl.Clear(cast(u32)gl.COLOR_BUFFER_BIT)
	imgui_impl_webgl.RenderDrawData(im.GetDrawData())

	return true
}

@(fini)
fini :: proc() {
	context = g.ctx

	imgui_impl_js.Shutdown()
	imgui_impl_webgl.Shutdown()

	im.DestroyContext()
}
