/*
Odin WebGL backend.

Heavily inspired by the default OpenGL 3 backend.
Only supports WebGL2.
*/
#+build js
package imgui_impl_webgl

import       "base:runtime"

import imgui ".."
import gl    "vendor:wasm/WebGL"
import glm   "core:math/linalg/glsl"

@(private)
Data :: struct {
	Allocator:                 runtime.Allocator,
	FontTexture:               gl.Texture,
	ShaderHandle:              gl.Program,
	AttribLocationTex:         i32,
	AttribLocationProjMtx:     i32,
	AttribLocationVtxPos:      i32,
	AttribLocationVtxUV:       i32,
	AttribLocationVtxColor:    i32,
	VboHandle, ElementsHandle: gl.Buffer,
	VertexBufferSize:          int,
	IndexBufferSize:           int,
}

@(private)
GetBackendData :: proc() -> ^Data {
	ctx := imgui.GetCurrentContext()
	if ctx != nil {
		return cast(^Data)imgui.GetIO().BackendRendererUserData
	}

	return nil
}

Init :: proc(allocator := context.allocator) {
	io := imgui.GetIO()
	imgui.CHECKVERSION()
	assert(io.BackendRendererUserData == nil, "Already initialized a renderer backend!")

	bd := new(Data, allocator)
	bd.Allocator = allocator
	io.BackendRendererUserData = bd
	io.BackendRendererName = "imgui_impl_webgl"

	ensure(gl.IsWebGL2Supported(), "WebGL2 is not supported!")
}

Shutdown :: proc() {
	bd := GetBackendData()
	assert(bd != nil, "No renderer backend to shutdown, or already shutdown?")
	io := imgui.GetIO()

	DestroyDeviceObjects()
	io.BackendRendererName = nil
	io.BackendRendererUserData = nil

	allocator := bd.Allocator
	free(bd, allocator)
}

NewFrame :: proc() {
	bd := GetBackendData()
	assert(bd != nil, "Context or backend not initialized! Did you call Init()?")

	if bd.ShaderHandle == 0 {
		CreateDeviceObjects()
	}
	if bd.FontTexture == 0 {
		CreateFontsTexture()
	}
}

@(private)
SetupRenderState :: proc(draw_data: ^imgui.DrawData, fb_width, fb_height: i32, vertex_array_object: gl.VertexArrayObject) {
	bd := GetBackendData()

	gl.Enable(gl.BLEND)
	gl.BlendEquation(gl.FUNC_ADD)
	gl.BlendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.STENCIL_TEST)
	gl.Enable(gl.SCISSOR_TEST)

	gl.Viewport(0, 0, fb_width, fb_height)
	L := draw_data.DisplayPos.x
	R := draw_data.DisplayPos.x + draw_data.DisplaySize.x
	T := draw_data.DisplayPos.y
	B := draw_data.DisplayPos.y + draw_data.DisplaySize.y
	ortho_projection := glm.mat4Ortho3d(L, R, B, T, -1024, 1024)
	gl.UseProgram(bd.ShaderHandle)
	gl.Uniform1i(bd.AttribLocationTex, 0)
	gl.UniformMatrix4fv(bd.AttribLocationProjMtx, ortho_projection)

	gl.BindSampler(0, 0)

	gl.BindVertexArray(vertex_array_object)

	gl.BindBuffer(gl.ARRAY_BUFFER, bd.VboHandle)
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, bd.ElementsHandle)
	gl.EnableVertexAttribArray(bd.AttribLocationVtxPos)
	gl.EnableVertexAttribArray(bd.AttribLocationVtxUV)
	gl.EnableVertexAttribArray(bd.AttribLocationVtxColor)
	gl.VertexAttribPointer(bd.AttribLocationVtxPos,   2, gl.FLOAT,         false, size_of(imgui.DrawVert), offset_of(imgui.DrawVert, pos))
	gl.VertexAttribPointer(bd.AttribLocationVtxUV,    2, gl.FLOAT,         false, size_of(imgui.DrawVert), offset_of(imgui.DrawVert, uv))
	gl.VertexAttribPointer(bd.AttribLocationVtxColor, 4, gl.UNSIGNED_BYTE, true,  size_of(imgui.DrawVert), offset_of(imgui.DrawVert, col))
}

RenderDrawData :: proc(draw_data: ^imgui.DrawData) {
	fb_width  := i32(draw_data.DisplaySize.x * draw_data.FramebufferScale.x)
	fb_height := i32(draw_data.DisplaySize.y * draw_data.FramebufferScale.y)
	if fb_width <= 0 || fb_height <= 0 {
		return
	}

	last_active_texture := cast(gl.Enum)gl.GetParameter(gl.ACTIVE_TEXTURE)
	gl.ActiveTexture(gl.TEXTURE0)
	last_program := cast(gl.Program)gl.GetParameter(gl.CURRENT_PROGRAM)
	last_texture := cast(gl.Texture)gl.GetParameter(gl.TEXTURE_BINDING_2D)
	last_sampler := cast(gl.Sampler)gl.GetParameter(gl.SAMPLER_BINDING)
	last_array_buffer := cast(gl.Buffer)gl.GetParameter(gl.ARRAY_BUFFER_BINDING)
	last_vertex_array_object := cast(gl.VertexArrayObject)gl.GetParameter(gl.VERTEX_ARRAY_BINDING)
	last_viewport: [4]i32
	gl.GetParameter4i(gl.VIEWPORT, &last_viewport[0], &last_viewport[1], &last_viewport[2], &last_viewport[3])
	last_scissor_box: [4]i32
	gl.GetParameter4i(gl.SCISSOR_BOX, &last_scissor_box[0], &last_scissor_box[1], &last_scissor_box[2], &last_scissor_box[3])
	last_blend_src_rgb := cast(gl.Enum)gl.GetParameter(gl.BLEND_SRC_RGB)
	last_blend_dst_rgb := cast(gl.Enum)gl.GetParameter(gl.BLEND_DST_RGB)
	last_blend_src_alpha := cast(gl.Enum)gl.GetParameter(gl.BLEND_SRC_ALPHA)
	last_blend_dst_alpha := cast(gl.Enum)gl.GetParameter(gl.BLEND_DST_ALPHA)
	last_blend_equation_rgb := cast(gl.Enum)gl.GetParameter(gl.BLEND_EQUATION_RGB)
	last_blend_equation_alpha := cast(gl.Enum)gl.GetParameter(gl.BLEND_EQUATION_ALPHA)
	last_enable_blend := gl.IsEnabled(gl.BLEND)
	last_enable_cull_face := gl.IsEnabled(gl.CULL_FACE)
	last_enable_depth_test := gl.IsEnabled(gl.DEPTH_TEST)
	last_enable_stencil_test := gl.IsEnabled(gl.STENCIL_TEST)
	last_enable_scissor_test := gl.IsEnabled(gl.SCISSOR_TEST)

	vertex_array_object := gl.CreateVertexArray()
	SetupRenderState(draw_data, fb_width, fb_height, vertex_array_object)

	clip_off := draw_data.DisplayPos
	clip_scale := draw_data.FramebufferScale

	for n in 0..<draw_data.CmdListsCount {
		draw_list := (cast([^]^imgui.DrawList)draw_data.CmdLists.Data)[n]

		vtx_buffer_size := int(draw_list.VtxBuffer.Size) * size_of(imgui.DrawVert)
		idx_buffer_size := int(draw_list.IdxBuffer.Size) * size_of(imgui.DrawIdx)

		gl.BufferData(gl.ARRAY_BUFFER, vtx_buffer_size, draw_list.VtxBuffer.Data, gl.STREAM_DRAW)
		gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, idx_buffer_size, draw_list.IdxBuffer.Data, gl.STREAM_DRAW)

		for cmd_i in 0..<draw_list.CmdBuffer.Size {
			pcmd := &(cast([^]imgui.DrawCmd)draw_list.CmdBuffer.Data)[cmd_i]
			if pcmd.UserCallback != nil {
				pcmd.UserCallback(draw_list, pcmd)
			} else {
				clip_min := (pcmd.ClipRect.xy - clip_off) * clip_scale
				clip_max := (pcmd.ClipRect.zw - clip_off) * clip_scale
				if clip_max.x <= clip_min.x || clip_max.y <= clip_min.y {
					continue
				}

				gl.Scissor(i32(clip_min.x), i32(f32(fb_height)-clip_max.y), i32(clip_max.x-clip_min.x), i32(clip_max.y - clip_min.y))

				gl.BindTexture(gl.TEXTURE_2D, cast(gl.Texture)uintptr(imgui.DrawCmd_GetTexID(pcmd)))

				gl.DrawElements(gl.TRIANGLES, int(pcmd.ElemCount), size_of(imgui.DrawIdx) == 2 ? gl.UNSIGNED_SHORT : gl.UNSIGNED_INT, cast(rawptr)uintptr(pcmd.IdxOffset * size_of(imgui.DrawIdx)))
			}
		}
	}

	gl.DeleteVertexArray(vertex_array_object)

	if last_program == 0 || gl.IsProgram(last_program) {
		gl.UseProgram(last_program)
	}
	gl.BindTexture(gl.TEXTURE_2D, last_texture)
	gl.BindSampler(0, last_sampler)
	gl.ActiveTexture(last_active_texture)
	gl.BindVertexArray(last_vertex_array_object)
	gl.BindBuffer(gl.ARRAY_BUFFER, last_array_buffer)
	gl.BlendEquationSeparate(last_blend_equation_rgb, last_blend_equation_alpha)
	gl.BlendFuncSeparate(last_blend_src_rgb, last_blend_dst_rgb, last_blend_src_alpha, last_blend_dst_alpha)

	if last_enable_blend        { gl.Enable(gl.BLEND)        } else { gl.Disable(gl.BLEND) }
	if last_enable_cull_face    { gl.Enable(gl.CULL_FACE)    } else { gl.Disable(gl.CULL_FACE) }
	if last_enable_depth_test   { gl.Enable(gl.DEPTH_TEST)   } else { gl.Disable(gl.DEPTH_TEST) }
	if last_enable_stencil_test { gl.Enable(gl.STENCIL_TEST) } else { gl.Disable(gl.STENCIL_TEST) }
	if last_enable_scissor_test { gl.Enable(gl.SCISSOR_TEST) } else { gl.Disable(gl.SCISSOR_TEST) }

	gl.Viewport(expand_values(last_viewport))
	gl.Scissor(expand_values(last_scissor_box))
}

@(private)
CreateFontsTexture :: proc() {
	io := imgui.GetIO()
	bd := GetBackendData()

	pixels: ^byte
	width, height: i32
	imgui.FontAtlas_GetTexDataAsRGBA32(io.Fonts, &pixels, &width, &height)

	last_texture := cast(gl.Texture)gl.GetParameter(gl.TEXTURE_BINDING_2D)
	bd.FontTexture = gl.CreateTexture()
	gl.BindTexture(gl.TEXTURE_2D, bd.FontTexture)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(gl.LINEAR))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, i32(gl.LINEAR))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, i32(gl.CLAMP_TO_EDGE))
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, i32(gl.CLAMP_TO_EDGE))
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, int(width)*int(height)*4, pixels)

	imgui.FontAtlas_SetTexID(io.Fonts, cast(rawptr)uintptr(bd.FontTexture))

	gl.BindTexture(gl.TEXTURE_2D, last_texture)
}

@(private)
DestroyFontsTexture :: proc() {
	io := imgui.GetIO()
	bd := GetBackendData()

	if bd.FontTexture != 0 {
		gl.DeleteTexture(bd.FontTexture)
		imgui.FontAtlas_SetTexID(io.Fonts, nil)
		bd.FontTexture = 0
	}
}

@(private)
CreateDeviceObjects :: proc() {
	bd := GetBackendData()

	last_texture := cast(gl.Texture)gl.GetParameter(gl.TEXTURE_BINDING_2D)
	last_array_buffer := cast(gl.Buffer)gl.GetParameter(gl.ARRAY_BUFFER_BINDING)
	last_pixel_unpack_buffer := cast(gl.Buffer)gl.GetParameter(gl.PIXEL_UNPACK_BUFFER_BINDING)
	last_vertex_array := cast(gl.VertexArrayObject)gl.GetParameter(gl.VERTEX_ARRAY_BINDING)

	vertex_shader_glsl_300_es   :: #load("vertex_300_es.glsl", string)
	fragment_shader_glsl_300_es :: #load("fragment_300_es.glsl", string)

	vertex_shader   := vertex_shader_glsl_300_es
	fragment_shader := fragment_shader_glsl_300_es

	bd.ShaderHandle, _ = gl.CreateProgramFromStrings({vertex_shader}, {fragment_shader})

	bd.AttribLocationTex = gl.GetUniformLocation(bd.ShaderHandle, "Texture")
	bd.AttribLocationProjMtx = gl.GetUniformLocation(bd.ShaderHandle, "ProjMtx")
	bd.AttribLocationVtxPos = gl.GetAttribLocation(bd.ShaderHandle, "Position")
	bd.AttribLocationVtxUV = gl.GetAttribLocation(bd.ShaderHandle, "UV")
	bd.AttribLocationVtxColor = gl.GetAttribLocation(bd.ShaderHandle, "Color")

	bd.VboHandle = gl.CreateBuffer()
	bd.ElementsHandle = gl.CreateBuffer()

	CreateFontsTexture()

	gl.BindTexture(gl.TEXTURE_2D, last_texture)
	gl.BindBuffer(gl.ARRAY_BUFFER, last_array_buffer)
	gl.BindBuffer(gl.PIXEL_UNPACK_BUFFER, last_pixel_unpack_buffer)
	gl.BindVertexArray(last_vertex_array)
}

@(private)
DestroyDeviceObjects :: proc() {
	bd := GetBackendData()
	if bd.VboHandle != 0      { gl.DeleteBuffer(bd.VboHandle);      bd.VboHandle = 0 }
	if bd.ElementsHandle != 0 { gl.DeleteBuffer(bd.ElementsHandle); bd.ElementsHandle = 0 }
	if bd.ShaderHandle != 0   { gl.DeleteProgram(bd.ShaderHandle);  bd.ShaderHandle = 0 }
	DestroyFontsTexture()
}
