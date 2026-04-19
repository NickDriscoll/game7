package imgui_example_js_wgpu

// This is an example of using the bindings with JS and WebGPU.
// It is also made cross-platform utilizing the GLFW backend on native builds.

import    "base:runtime"

import    "core:fmt"
import    "core:math/linalg"

import    "vendor:wgpu"

import im "../.."
import    "../../imgui_impl_wgpu"

g := struct {
	ctx:      runtime.Context,

	instance: wgpu.Instance,
	adapter:  wgpu.Adapter,
	device:   wgpu.Device,
	surface:  wgpu.Surface,
	queue:    wgpu.Queue,
	config:   wgpu.SurfaceConfiguration,

	platform: Platform,
}{}

main :: proc() {
	g.ctx = context

	im.CHECKVERSION()
	im.CreateContext()
	io := im.GetIO()
	io.ConfigFlags += { .NavEnableKeyboard, .NavEnableGamepad, .DockingEnable }

	im.StyleColorsDark()

	g.instance = wgpu.CreateInstance()
	if !platform_init() {
		return
	}

	wgpu.InstanceRequestAdapter(g.instance, nil, { callback = on_adapter })

	on_adapter :: proc "c" (status: wgpu.RequestAdapterStatus, adapter: wgpu.Adapter, msg: string, _, _: rawptr) {
		context = g.ctx

		if status != .Success {
			fmt.panicf("Could not get WebGPU adapter: %v: %v", status, msg)
		}

		g.adapter = adapter
		assert(g.adapter != nil)

		wgpu.AdapterRequestDevice(g.adapter, nil, { callback = on_device })
	}

	on_device :: proc "c" (status: wgpu.RequestDeviceStatus, device: wgpu.Device, msg: string, _, _: rawptr) {
		context = g.ctx

		if status != .Success {
			fmt.panicf("Could not get WebGPU device: %v: %v", status, msg)
		}

		g.device = device
		assert(g.device != nil)

		g.queue = wgpu.DeviceGetQueue(g.device)

		surface_capabilities, _ := wgpu.SurfaceGetCapabilities(g.surface, g.adapter)
		assert(surface_capabilities.formatCount >= 1)
		// The first present mode is the preferred one
		preferred_surface_format := surface_capabilities.formats[0]

		g.config = {
			device      = g.device,
			format      = preferred_surface_format,
			usage       = { .RenderAttachment },
			alphaMode   = .Opaque,
			presentMode = .Fifo,
		}

		init_info := imgui_impl_wgpu.INIT_INFO_DEFAULT
		init_info.Device = g.device
		init_info.NumFramesInFlight = 3
		init_info.RenderTargetFormat = preferred_surface_format

		imgui_impl_wgpu.Init(init_info)

		platform_run()
	}
}

step :: proc() {
	defer free_all(context.temp_allocator)

	io := im.GetIO()
	sz := linalg.to_u32(io.DisplaySize * io.DisplayFramebufferScale)
	if sz != ([2]u32{g.config.width, g.config.height}) {
		g.config.width  = sz.x
		g.config.height = sz.y
		wgpu.SurfaceConfigure(g.surface, &g.config)
	}

	imgui_impl_wgpu.NewFrame()
	im.NewFrame()

	im.ShowDemoWindow()

	im.Render()

	surface_texture := wgpu.SurfaceGetCurrentTexture(g.surface)
	defer wgpu.TextureRelease(surface_texture.texture)

	surface_view := wgpu.TextureCreateView(surface_texture.texture)
	defer wgpu.TextureViewRelease(surface_view)

	encoder := wgpu.DeviceCreateCommandEncoder(g.device)
	defer wgpu.CommandEncoderRelease(encoder)

	pass := wgpu.CommandEncoderBeginRenderPass(encoder, &{
		colorAttachmentCount = 1,
		colorAttachments     = &wgpu.RenderPassColorAttachment{
			view       = surface_view,
			loadOp     = .Clear,
			storeOp    = .Store,
			clearValue = { 0, 0, 0, 1 },
			depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
		},
	})

	imgui_impl_wgpu.RenderDrawData(im.GetDrawData(), pass)

	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)

	cmd_buffer := wgpu.CommandEncoderFinish(encoder)
	defer wgpu.CommandBufferRelease(cmd_buffer)

	wgpu.QueueSubmit(g.queue, { cmd_buffer })

	wgpu.SurfacePresent(g.surface)
}

fini :: proc() {
	if g.device != nil {
		imgui_impl_wgpu.Shutdown()
	}

	if g.queue    != nil { wgpu.QueueRelease(g.queue) }
	if g.surface  != nil { wgpu.SurfaceRelease(g.surface) }
	if g.device   != nil { wgpu.DeviceRelease(g.device) }
	if g.adapter  != nil { wgpu.AdapterRelease(g.adapter) }
	if g.instance != nil { wgpu.InstanceRelease(g.instance) }

	im.DestroyContext()
}
