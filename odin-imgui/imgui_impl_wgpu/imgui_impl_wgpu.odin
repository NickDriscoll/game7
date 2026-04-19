package imgui_impl_wgpu

import       "core:math/linalg"
import       "core:mem"
import       "core:reflect"
import       "core:strings"

import       "vendor:wgpu"

import imgui ".."

InitInfo :: struct {
	Device:                   wgpu.Device,
	NumFramesInFlight:        int,
	RenderTargetFormat:       wgpu.TextureFormat,
	DepthStencilFormat:       wgpu.TextureFormat,
	PipelineMultisampleState: wgpu.MultisampleState,
}

INIT_INFO_DEFAULT :: InitInfo {
	NumFramesInFlight = 3,
	PipelineMultisampleState = {
		count = 1,
		mask  = max(u32),
	},
}

Init :: proc(init_info: InitInfo = INIT_INFO_DEFAULT, allocator := context.allocator) {
	io := imgui.GetIO()
	assert(io.BackendRendererUserData == nil, "Already initialized a renderer backend!")
	assert(init_info.Device != nil, "No device given!")

	bd := new(Data, allocator)
	bd.allocator = allocator
	io.BackendRendererUserData = bd
	io.BackendRendererName = "imgui_impl_webgpu"

	io.BackendFlags += {.RendererHasVtxOffset}

	bd.initInfo           = init_info
	bd.device             = init_info.Device
	bd.defaultQueue       = wgpu.DeviceGetQueue(init_info.Device)
	bd.renderTargetFormat = init_info.RenderTargetFormat
	bd.depthStencilFormat = init_info.DepthStencilFormat
	bd.numFramesInFlight  = init_info.NumFramesInFlight
	bd.frameIndex         = max(uint)

	bd.renderResources.imageBindGroups.allocator = allocator

	bd.frameResources = make([]FrameResource, bd.numFramesInFlight, allocator)
	for &fr in bd.frameResources {
		fr.vertexBufferHost.allocator = allocator
		fr.indexBufferHost.allocator  = allocator
		resize(&fr.indexBufferHost, 10000)
		resize(&fr.vertexBufferHost, 5000)
	}
}

Shutdown :: proc() {
	bd := GetBackendData()
	assert(bd != nil, "No renderer backend to shutdown, or already shutdown?")
	io := imgui.GetIO()

	InvalidateDeviceObjects()

	delete(bd.renderResources.imageBindGroups)
	delete(bd.frameResources, bd.allocator)

	wgpu.QueueRelease(bd.defaultQueue)

	io.BackendRendererName = nil
	io.BackendRendererUserData = nil
	io.BackendFlags -= {.RendererHasVtxOffset}

	allocator := bd.allocator
	free(bd, allocator)
}

NewFrame :: proc() {
	bd := GetBackendData()
	if bd.pipelineState == nil {
		CreateDeviceObjects()
	}
}

RenderDrawData :: proc(draw_data: ^imgui.DrawData, pass_encoder: wgpu.RenderPassEncoder) {
	fb := draw_data.DisplaySize * draw_data.FramebufferScale
	if fb.x <= 0 || fb.y <= 0 || draw_data.CmdListsCount == 0 {
		return
	}

	bd := GetBackendData()
	bd.frameIndex += 1
	fr := &bd.frameResources[bd.frameIndex % uint(bd.numFramesInFlight)]

	if fr.vertexBuffer == nil || len(fr.vertexBufferHost) < int(draw_data.TotalVtxCount) {
		if fr.vertexBuffer != nil {
			wgpu.BufferDestroy(fr.vertexBuffer)
			wgpu.BufferRelease(fr.vertexBuffer)
		}

		clear(&fr.vertexBufferHost)
		resize(&fr.vertexBufferHost, draw_data.TotalVtxCount+5000)

		fr.vertexBuffer = wgpu.DeviceCreateBuffer(bd.device, &{
			label = "Dear ImGUi Vertex buffer",
			usage = {.CopyDst, .Vertex},
			size  = u64(len(fr.vertexBufferHost)) * size_of(imgui.DrawVert),
		})
	}

	if fr.indexBuffer == nil || len(fr.indexBufferHost) < int(draw_data.TotalIdxCount) {
		if fr.indexBuffer != nil {
			wgpu.BufferDestroy(fr.indexBuffer)
			wgpu.BufferRelease(fr.indexBuffer)
		}

		clear(&fr.indexBufferHost)
		resize(&fr.indexBufferHost, draw_data.TotalIdxCount+10000)

		fr.indexBuffer = wgpu.DeviceCreateBuffer(bd.device, &{
			label = "Dear ImGui Index buffer",
			usage = {.CopyDst, .Index},
			size  = cast(u64)mem.align_forward_uint(len(fr.indexBufferHost) * size_of(imgui.DrawIdx), 4),
		})
	}

	vtx_dst := fr.vertexBufferHost[:]
	idx_dst := fr.indexBufferHost[:]
	vtx_dst_off, idx_dst_off: int
	for n in 0..<draw_data.CmdListsCount {
		draw_list := (cast([^]^imgui.DrawList)draw_data.CmdLists.Data)[n]
		vtx_dst_off += copy(vtx_dst[vtx_dst_off:], (cast([^]imgui.DrawVert)draw_list.VtxBuffer.Data)[:draw_list.VtxBuffer.Size])
		idx_dst_off += copy(idx_dst[idx_dst_off:], (cast([^]imgui.DrawIdx)draw_list.IdxBuffer.Data)[:draw_list.IdxBuffer.Size])
	}
	vb_write_size := cast(uint)vtx_dst_off * size_of(imgui.DrawVert)
	ib_write_size := mem.align_forward_uint(cast(uint)idx_dst_off * size_of(imgui.DrawIdx), 4)
	wgpu.QueueWriteBuffer(bd.defaultQueue, fr.vertexBuffer, 0, raw_data(vtx_dst), vb_write_size)
	wgpu.QueueWriteBuffer(bd.defaultQueue, fr.indexBuffer,  0, raw_data(idx_dst), ib_write_size)

	SetupRenderState(draw_data, pass_encoder, fr)

	global_vtx_offset: u32 = 0
	global_idx_offset: u32 = 0
	clip_scale := draw_data.FramebufferScale
	clip_off   := draw_data.DisplayPos
	for n in 0..<draw_data.CmdListsCount {
		draw_list := (cast([^]^imgui.DrawList)draw_data.CmdLists.Data)[n]
		for cmd_i in 0..<draw_list.CmdBuffer.Size {
			pcmd := &(cast([^]imgui.DrawCmd)draw_list.CmdBuffer.Data)[cmd_i]
			if pcmd.UserCallback != nil {
				pcmd.UserCallback(draw_list, pcmd)
			} else {
				tex_id := imgui.DrawCmd_GetTexID(pcmd)
				// TODO: error?
				_, val, is_new, _ := map_entry(&bd.renderResources.imageBindGroups, tex_id)
				if is_new {
					bind_group := CreateImageBindGroup(bd.renderResources.imageBindGroupLayout, cast(wgpu.TextureView)cast(uintptr)tex_id)
					val^ = bind_group
				}
				wgpu.RenderPassEncoderSetBindGroup(pass_encoder, 1, val^)

				clip_min := (pcmd.ClipRect.xy - clip_off) * clip_scale
				clip_max := (pcmd.ClipRect.zw - clip_off) * clip_scale

				if clip_min.x < 0 { clip_min.x = 0 }
				if clip_min.y < 0 { clip_min.y = 0 }
				if clip_max.x > fb.x { clip_max.x = fb.x }
				if clip_max.y > fb.y { clip_max.y = fb.y }

				if clip_max.x <= clip_min.x || clip_max.y <= clip_min.y {
					continue
				}

				wgpu.RenderPassEncoderSetScissorRect(pass_encoder, cast(u32)clip_min.x, cast(u32)clip_min.y, u32(clip_max.x - clip_min.x), u32(clip_max.y - clip_min.y))
				wgpu.RenderPassEncoderDrawIndexed(pass_encoder, pcmd.ElemCount, 1, pcmd.IdxOffset + global_idx_offset, i32(pcmd.VtxOffset + global_vtx_offset), 0)
			}
		}
		global_idx_offset += cast(u32)draw_list.IdxBuffer.Size
		global_vtx_offset += cast(u32)draw_list.VtxBuffer.Size
	}

	for _, image_bind_group in bd.renderResources.imageBindGroups {
		wgpu.BindGroupRelease(image_bind_group)
	}
	clear(&bd.renderResources.imageBindGroups)
}

@(private)
RenderResources :: struct {
	fontTexture:          wgpu.Texture,
	fontTextureView:      wgpu.TextureView,
	sampler:              wgpu.Sampler,
	uniforms:             wgpu.Buffer,
	commonBindGroup:      wgpu.BindGroup,
	imageBindGroups:      map[imgui.TextureID]wgpu.BindGroup,
	imageBindGroupLayout: wgpu.BindGroupLayout,
}

@(private)
FrameResource :: struct {
	indexBuffer:      wgpu.Buffer,
	vertexBuffer:     wgpu.Buffer,
	indexBufferHost:  [dynamic]imgui.DrawIdx,
	vertexBufferHost: [dynamic]imgui.DrawVert,
}

@(private)
Uniforms :: struct {
	MVP:   matrix[4,4]f32,
	gamma: f32,
}

@(private)
Data :: struct {
	allocator:          mem.Allocator,
	initInfo:           InitInfo,
	device:             wgpu.Device,
	defaultQueue:       wgpu.Queue,
	renderTargetFormat: wgpu.TextureFormat,
	depthStencilFormat: wgpu.TextureFormat,
	pipelineState:      wgpu.RenderPipeline,
	renderResources:    RenderResources,
	frameResources:     []FrameResource,
	numFramesInFlight:  int,
	frameIndex:         uint,
}

@(private)
GetBackendData :: proc() -> ^Data {
	if imgui.GetCurrentContext() != nil {
		io := imgui.GetIO()
		return cast(^Data)io.BackendRendererUserData
	}
	return nil
}

@(private)
CreateShaderModule :: proc(source: string) -> (stage_desc: wgpu.ProgrammableStageDescriptor) {
	bd := GetBackendData()

	stage_desc.module = wgpu.DeviceCreateShaderModule(bd.device, &{
		nextInChain = &wgpu.ShaderSourceWGSL{
			sType = .ShaderSourceWGSL,
			code  = source,
		},
	})

	stage_desc.entryPoint = "main"
	return
}

@(private)
CreateImageBindGroup :: proc(layout: wgpu.BindGroupLayout, texture: wgpu.TextureView) -> wgpu.BindGroup {
	bd := GetBackendData()

	return wgpu.DeviceCreateBindGroup(bd.device, &{
		layout     = layout,
		entryCount = 1,
		entries    = &wgpu.BindGroupEntry{
			textureView = texture,
		},
	})
}

@(private)
SetupRenderState :: proc(draw_data: ^imgui.DrawData, ctx: wgpu.RenderPassEncoder, fr: ^FrameResource) {
	bd := GetBackendData()

	L   := draw_data.DisplayPos.x
	R   := draw_data.DisplayPos.x + draw_data.DisplaySize.x
	T   := draw_data.DisplayPos.y
	B   := draw_data.DisplayPos.y + draw_data.DisplaySize.y
	mvp := linalg.matrix_ortho3d(L, R, B, T, -1024, 1024)
	wgpu.QueueWriteBuffer(bd.defaultQueue, bd.renderResources.uniforms, cast(u64)offset_of(Uniforms, MVP), &mvp, size_of(mvp))

	name, _ := reflect.enum_name_from_value(bd.renderTargetFormat)
	gamma: f32 = 2.2 if strings.ends_with(name, "Srgb") else 1.
	wgpu.QueueWriteBuffer(bd.defaultQueue, bd.renderResources.uniforms, cast(u64)offset_of(Uniforms, gamma), &gamma, size_of(gamma))

	wgpu.RenderPassEncoderSetViewport(ctx, 0, 0, draw_data.FramebufferScale.x * draw_data.DisplaySize.x, draw_data.FramebufferScale.y * draw_data.DisplaySize.y, 0, 1)

	wgpu.RenderPassEncoderSetVertexBuffer(ctx, 0, fr.vertexBuffer, 0, u64(len(fr.vertexBufferHost)) * size_of(imgui.DrawVert))
	wgpu.RenderPassEncoderSetIndexBuffer(ctx, fr.indexBuffer, size_of(imgui.DrawIdx) == 2 ? .Uint16 : .Uint32, 0, u64(len(fr.indexBufferHost)) * size_of(imgui.DrawIdx))
	wgpu.RenderPassEncoderSetPipeline(ctx, bd.pipelineState)
	wgpu.RenderPassEncoderSetBindGroup(ctx, 0, bd.renderResources.commonBindGroup)

	wgpu.RenderPassEncoderSetBlendConstant(ctx, &{0, 0, 0, 0})
}

@(private)
CreateFontsTexture :: proc() {
	bd := GetBackendData()
	io := imgui.GetIO()
	pixels: ^byte
	width, height, size_pp: i32
	imgui.FontAtlas_GetTexDataAsRGBA32(io.Fonts, &pixels, &width, &height, &size_pp)

	bd.renderResources.fontTexture = wgpu.DeviceCreateTexture(bd.device, &{
		label     = "Dear ImGui font Texture",
		dimension = ._2D,
		size = {
			width              = cast(u32)width,
			height             = cast(u32)height,
			depthOrArrayLayers = 1,
		},
		sampleCount   = 1,
		format        = .RGBA8Unorm,
		mipLevelCount = 1,
		usage         = {.CopyDst, .TextureBinding},
	})
	bd.renderResources.fontTextureView = wgpu.TextureCreateView(bd.renderResources.fontTexture, &{
		format          = .RGBA8Unorm,
		dimension       = ._2D,
		mipLevelCount   = 1,
		arrayLayerCount = 1,
		aspect          = .All,
	})

	wgpu.QueueWriteTexture(
		bd.defaultQueue,
		&{
			texture = bd.renderResources.fontTexture,
			aspect  = .All,
		},
		pixels,
		cast(uint)width * cast(uint)height * cast(uint)size_pp,
		&{
			bytesPerRow  = cast(u32)width * cast(u32)size_pp,
			rowsPerImage = cast(u32)height,
		},
		&{ cast(u32)width, cast(u32)height, 1 },
	)

	bd.renderResources.sampler = wgpu.DeviceCreateSampler(bd.device, &{
		minFilter     = .Linear,
		magFilter     = .Linear,
		mipmapFilter  = .Linear,
		addressModeU  = .ClampToEdge,
		addressModeV  = .ClampToEdge,
		addressModeW  = .ClampToEdge,
		maxAnisotropy = 1,
	})

	imgui.FontAtlas_SetTexID(io.Fonts, cast(imgui.TextureID)cast(uintptr)bd.renderResources.fontTextureView)
}

@(private)
CreateUniformBuffer :: proc() {
	bd := GetBackendData()

	bd.renderResources.uniforms = wgpu.DeviceCreateBuffer(bd.device, &{
		label = "Dear ImGui Uniform buffer",
		usage = {.CopyDst, .Uniform},
		size  = cast(u64)mem.align_forward_uint(size_of(Uniforms), 16),
	})
}

@(private)
CreateDeviceObjects :: proc() {
	bd := GetBackendData()
	if bd.device == nil {
		return
	}

	if bd.pipelineState != nil {
		InvalidateDeviceObjects()
	}

	bg_layouts: [2]wgpu.BindGroupLayout
	bg_layouts[0] = wgpu.DeviceCreateBindGroupLayout(bd.device, &{
		entryCount = 2,
		entries    = raw_data([]wgpu.BindGroupLayoutEntry{
			{
				visibility = {.Vertex, .Fragment},
				buffer     = {
					type = .Uniform,
				},
			},
			{
				binding = 1,
				visibility = {.Fragment},
				sampler    = {
					type = .Filtering,
				},
			},
		}),
	})
	bg_layouts[1] = wgpu.DeviceCreateBindGroupLayout(bd.device, &{
		entryCount = 1,
		entries = &wgpu.BindGroupLayoutEntry{
			visibility = {.Fragment},
			texture = {
				sampleType    = .Float,
				viewDimension = ._2D,
			},
		},
	})

	pipeline_layout := wgpu.DeviceCreatePipelineLayout(bd.device, &{
		bindGroupLayoutCount = len(bg_layouts),
		bindGroupLayouts     = raw_data(&bg_layouts),
	})

	vertex_shader_desc := CreateShaderModule(#load("vertex.wgsl"))
	pixel_shader_desc  := CreateShaderModule(#load("fragment.wgsl"))

	bd.pipelineState = wgpu.DeviceCreateRenderPipeline(bd.device, &{
		layout = pipeline_layout,
		vertex = {
			module     = vertex_shader_desc.module,
			entryPoint = vertex_shader_desc.entryPoint,
			bufferCount = 1,
			buffers     = &wgpu.VertexBufferLayout{
				arrayStride    = size_of(imgui.DrawVert),
				stepMode       = .Vertex,
				attributeCount = 3,
				attributes     = raw_data([]wgpu.VertexAttribute{
					{.Float32x2, cast(u64)offset_of(imgui.DrawVert, pos), 0},
					{.Float32x2, cast(u64)offset_of(imgui.DrawVert, uv),  1},
					{.Unorm8x4,  cast(u64)offset_of(imgui.DrawVert, col), 2},
				}),
			},
		},
		fragment = &{
			module      = pixel_shader_desc.module,
			entryPoint  = pixel_shader_desc.entryPoint,
			targetCount = 1,
			targets     = &wgpu.ColorTargetState{
				format = bd.renderTargetFormat,
				blend = &{
					alpha = { .Add, .One, .OneMinusSrcAlpha },
					color = { .Add, .SrcAlpha, .OneMinusSrcAlpha },
				},
				writeMask = wgpu.ColorWriteMaskFlags_All,
			},
		},
		primitive = {
			topology         = .TriangleList,
			stripIndexFormat = .Undefined,
			frontFace        = .CW,
			cullMode         = .None,
		},
		multisample = bd.initInfo.PipelineMultisampleState,
		depthStencil = nil if bd.depthStencilFormat == .Undefined else &{
			format            = bd.depthStencilFormat,
			depthWriteEnabled = .False,
			depthCompare      = .Always,
			stencilFront      = { .Always, .Keep, .Keep, .Keep },
			stencilBack       = { .Always, .Keep, .Keep, .Keep },
		},
	})

	CreateFontsTexture()
	CreateUniformBuffer()

	bd.renderResources.commonBindGroup = wgpu.DeviceCreateBindGroup(bd.device, &{
		layout = bg_layouts[0],
		entryCount = 2,
		entries = raw_data([]wgpu.BindGroupEntry{
			{
				buffer = bd.renderResources.uniforms,
				size   = cast(u64)mem.align_forward_uint(size_of(Uniforms), 16),
			},
			{
				binding = 1,
				sampler = bd.renderResources.sampler,
			},
		}),
	})
	bd.renderResources.imageBindGroupLayout = bg_layouts[1]

	wgpu.ShaderModuleRelease(vertex_shader_desc.module)
	wgpu.ShaderModuleRelease(pixel_shader_desc.module)
	wgpu.PipelineLayoutRelease(pipeline_layout)
	wgpu.BindGroupLayoutRelease(bg_layouts[0])
}

@(private)
InvalidateDeviceObjects :: proc() {
	bd := GetBackendData()
	if bd.device == nil {
		return
	}

	wgpu.RenderPipelineRelease(bd.pipelineState)

	wgpu.TextureRelease(bd.renderResources.fontTexture)
	wgpu.TextureViewRelease(bd.renderResources.fontTextureView)
	wgpu.SamplerRelease(bd.renderResources.sampler)
	wgpu.BufferRelease(bd.renderResources.uniforms)
	wgpu.BindGroupRelease(bd.renderResources.commonBindGroup)
	wgpu.BindGroupLayoutRelease(bd.renderResources.imageBindGroupLayout)

	io := imgui.GetIO()
	imgui.FontAtlas_SetTexID(io.Fonts, imgui.TextureID{})

	for &frame in bd.frameResources {
		wgpu.BufferRelease(frame.indexBuffer)
		wgpu.BufferRelease(frame.vertexBuffer)
		delete(frame.indexBufferHost)
		delete(frame.vertexBufferHost)
		frame.indexBufferHost = {}
		frame.indexBufferHost.allocator = bd.allocator
		frame.vertexBufferHost = {}
		frame.vertexBufferHost.allocator = bd.allocator
	}
}
