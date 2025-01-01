package main

import "core:c"
import "core:math/linalg/hlsl"
import "core:log"
import "core:slice"
import "vendor:sdl2"
import vk "vendor:vulkan"
import imgui "odin-imgui"
import vkw "desktop_vulkan_wrapper"
import hm "desktop_vulkan_wrapper/handlemap"

// @TODO: This is probably waaaaay bigger than necessary
MAX_IMGUI_VERTICES :: 64 * 1024 * 1024
MAX_IMGUI_INDICES :: 16 * 1024 * 1024

ImguiPushConstants :: struct {
    font_idx: u32,
    sampler: vkw.Immutable_Sampler_Index,
    vertex_offset: u32,
    uniform_data: vk.DeviceAddress,
    vertex_data: vk.DeviceAddress,
}

ImguiUniforms :: struct {
    clip_from_screen: hlsl.float4x4,
}

ImguiState :: struct {
    ctxt: ^imgui.Context,
    font_atlas: vkw.Image_Handle,
    vertex_buffer: vkw.Buffer_Handle,
    index_buffer: vkw.Buffer_Handle,
    uniform_buffer: vkw.Buffer_Handle,
    pipeline: vkw.Pipeline_Handle,
    show_gui: bool,
}

imgui_init :: proc(gd: ^vkw.Graphics_Device, resolution: hlsl.uint2) -> ImguiState {
    imgui_state: ImguiState
    imgui_state.show_gui = true
    imgui_state.ctxt = imgui.CreateContext()
    
    io := imgui.GetIO()
    io.DisplaySize.x = f32(resolution.x)
    io.DisplaySize.y = f32(resolution.y)
    io.ConfigFlags += {.DockingEnable}

    // Create font atlas and upload its texture data
    font_data: ^c.uchar
    width: c.int
    height: c.int
    imgui.FontAtlas_GetTexDataAsRGBA32(io.Fonts, &font_data, &width, &height)        
    info := vkw.Image_Create {
        flags = nil,
        image_type = .D2,
        format = .R8G8B8A8_SRGB,
        extent = {
            width = u32(width),
            height = u32(height),
            depth = 1,
        },
        supports_mipmaps = false,
        array_layers = 1,
        samples = {._1},
        tiling = .OPTIMAL,
        usage = {.SAMPLED,.TRANSFER_DST},
        alloc_flags = nil,
        name = "Dear ImGUI font atlas",
    }
    font_bytes_slice := slice.from_ptr(font_data, int(width * height * 4))
    ok: bool
    imgui_state.font_atlas, ok = vkw.sync_create_image_with_data(gd, &info, font_bytes_slice)
    if !ok {
        log.error("Failed to upload imgui font atlas data.")
    }

    // Free CPU-side texture data
    imgui.FontAtlas_ClearTexData(io.Fonts)

    imgui.FontAtlas_SetTexID(io.Fonts, hm.handle_to_rawptr(imgui_state.font_atlas))

    // Allocate imgui vertex buffer
    buffer_info := vkw.Buffer_Info {
        size = MAX_IMGUI_VERTICES * size_of(imgui.DrawVert),
        usage = {.STORAGE_BUFFER,.TRANSFER_DST},
        alloc_flags = nil,
        required_flags = {.DEVICE_LOCAL},
    }
    imgui_state.vertex_buffer = vkw.create_buffer(gd, &buffer_info)

    // Allocate imgui index buffer
    buffer_info = vkw.Buffer_Info {
        size = MAX_IMGUI_INDICES * size_of(imgui.DrawIdx),
        usage = {.INDEX_BUFFER,.TRANSFER_DST},
        alloc_flags = nil,
        required_flags = {.DEVICE_LOCAL},
    }
    imgui_state.index_buffer = vkw.create_buffer(gd, &buffer_info)

    // Create uniform buffer
    {
        info := vkw.Buffer_Info {
            size = size_of(ImguiUniforms),
            usage = {.UNIFORM_BUFFER,.TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL,.HOST_VISIBLE,.HOST_COHERENT},
        }
        imgui_state.uniform_buffer = vkw.create_buffer(gd, &info)
    }

    // Create pipeline for drawing

    // Load shader bytecode
    // This will be embedded into the executable at compile-time
    vertex_spv :: #load("data/shaders/imgui.vert.spv", []u32)
    fragment_spv :: #load("data/shaders/imgui.frag.spv", []u32)

    raster_state := vkw.default_rasterization_state()
    raster_state.cull_mode = nil

    pipeline_info := vkw.Graphics_Pipeline_Info {
        vertex_shader_bytecode = vertex_spv,
        fragment_shader_bytecode = fragment_spv,
        input_assembly_state = vkw.Input_Assembly_State {
            topology = .TRIANGLE_LIST,
            primitive_restart_enabled = false,
        },
        tessellation_state = {},
        rasterization_state = raster_state,
        multisample_state = vkw.Multisample_State {
            sample_count = {._1},
            do_sample_shading = false,
            min_sample_shading = 0.0,
            sample_mask = nil,
            do_alpha_to_coverage = false,
            do_alpha_to_one = false,
        },
        depthstencil_state = vkw.DepthStencil_State {
            flags = nil,
            do_depth_test = false,
            do_depth_write = false,
            depth_compare_op = .GREATER_OR_EQUAL,
            do_depth_bounds_test = false,
            do_stencil_test = false,
            // front = nil,
            // back = nil,
            min_depth_bounds = 0.0,
            max_depth_bounds = 1.0,
        },
        colorblend_state = vkw.default_colorblend_state(),
        renderpass_state = vkw.PipelineRenderpass_Info {
            color_attachment_formats = {vk.Format.B8G8R8A8_SRGB},
            depth_attachment_format = nil,
        },
    }

    handles := vkw.create_graphics_pipelines(gd, {pipeline_info})
    defer delete(handles)

    imgui_state.pipeline = handles[0]

    return imgui_state
}

// Once-per-frame call to update imgui vtx/idx/uniform buffers
// and record imgui draw commands into current frame's command buffer
render_imgui :: proc(
    gd: ^vkw.Graphics_Device,
    gfx_cb_idx: vkw.CommandBuffer_Index,
    imgui_state: ^ImguiState,
) {
    // Update uniform buffer
    
    io := imgui.GetIO()
    uniforms: ImguiUniforms
    uniforms.clip_from_screen = {
        2.0 / io.DisplaySize.x, 0.0, 0.0, -1.0,
        0.0, 2.0 / io.DisplaySize.y, 0.0, -1.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    }
    u_slice := slice.from_ptr(&uniforms, 1)
    vkw.sync_write_buffer(gd, imgui_state.uniform_buffer, u_slice)

    imgui.Render()
    
    draw_data := imgui.GetDrawData()

    // Temp buffers for collecting imgui vertices/indices from all cmd lists
    vertex_staging := make(
        [dynamic]imgui.DrawVert,
        0,
        draw_data.TotalVtxCount,
        allocator = context.temp_allocator,
    )
    index_staging := make(
        [dynamic]imgui.DrawIdx,
        0,
        draw_data.TotalIdxCount,
        allocator = context.temp_allocator,
    )

    imgui_vertex_buffer, ok := vkw.get_buffer(gd, imgui_state.vertex_buffer)
    if !ok {
        log.error("Failed to get imgui vertex buffer")
    }

    if !vkw.cmd_bind_index_buffer(gd, gfx_cb_idx, imgui_state.index_buffer) {
        log.error("Failed to get imgui index buffer")  
    } 
    vkw.cmd_bind_pipeline(gd, gfx_cb_idx, .GRAPHICS, imgui_state.pipeline)
    vkw.cmd_bind_descriptor_set(gd, gfx_cb_idx)
    
    uniform_buf, ok2 := vkw.get_buffer(gd, imgui_state.uniform_buffer)

    // Compute a fixed vertex/index offset based on frame index
    // so that the CPU doesn't overwrite vertex data for a frame currently
    // being worked on
    frame_idx := gd.frame_count % FRAMES_IN_FLIGHT
    global_vtx_offset : u32 = u32(frame_idx * MAX_IMGUI_VERTICES / FRAMES_IN_FLIGHT)
    global_idx_offset : u32 = u32(frame_idx * MAX_IMGUI_INDICES / FRAMES_IN_FLIGHT)
    local_vtx_offset : u32 = 0
    local_idx_offset : u32 = 0

    cmd_lists := slice.from_ptr(draw_data.CmdLists.Data, int(draw_data.CmdListsCount))
    for cmd_list in cmd_lists {
        // Push this cmd_list's vertex data to the staging buffer
        vtx_slice := slice.from_ptr(cmd_list.VtxBuffer.Data, int(cmd_list.VtxBuffer.Size))
        append(&vertex_staging, ..vtx_slice)

        // Now the index data
        idx_slice := slice.from_ptr(cmd_list.IdxBuffer.Data, int(cmd_list.IdxBuffer.Size))
        append(&index_staging, ..idx_slice)

        // Record commands into command buffer
        cmds := slice.from_ptr(cmd_list.CmdBuffer.Data, int(cmd_list.CmdBuffer.Size))
        for cmd in cmds {
            vkw.cmd_set_scissor(gd, gfx_cb_idx, 0, {
                {
                    offset = {
                        x = i32(cmd.ClipRect.x),
                        y = i32(cmd.ClipRect.y),
                    },
                    extent = {
                        width = u32(cmd.ClipRect.z - cmd.ClipRect.x),
                        height = u32(cmd.ClipRect.a - cmd.ClipRect.y),
                    },
                },
            })

            tex_handle := hm.rawptr_to_handle(cmd.TextureId)
            vkw.cmd_push_constants_gfx(ImguiPushConstants, gd, gfx_cb_idx, &ImguiPushConstants {
                font_idx = tex_handle.index,
                sampler = .Point,
                vertex_offset = cmd.VtxOffset + global_vtx_offset + local_vtx_offset,
                uniform_data = uniform_buf.address,
                vertex_data = imgui_vertex_buffer.address,
            })

            vkw.cmd_draw_indexed(
                gd,
                gfx_cb_idx,
                cmd.ElemCount,
                1,
                cmd.IdxOffset + global_idx_offset + local_idx_offset,
                0, // This parameter is unused when doing vertex pulling
                0
            )
        }
        
        // Update offsets within local vertex/index buffers
        local_vtx_offset += u32(cmd_list.VtxBuffer.Size)
        local_idx_offset += u32(cmd_list.IdxBuffer.Size)
    }

    // Upload vertex and index data to GPU buffers
    vkw.sync_write_buffer(gd, imgui_state.vertex_buffer, vertex_staging[:], global_vtx_offset)
    vkw.sync_write_buffer(gd, imgui_state.index_buffer, index_staging[:], global_idx_offset)
    
}

imgui_cleanup :: proc(vgd: ^vkw.Graphics_Device, using is: ^ImguiState) {
    imgui.DestroyContext(ctxt)
    vkw.delete_buffer(vgd, vertex_buffer)
    vkw.delete_buffer(vgd, index_buffer)
    vkw.delete_buffer(vgd, uniform_buffer)
}


// Translated from imgui_demo.cpp
HelpMarker :: proc(desc: cstring) {
    imgui.TextDisabled("(?)")
    if (imgui.BeginItemTooltip()) {
        imgui.PushTextWrapPos(imgui.GetFontSize() * 35.0)
        imgui.TextUnformatted(desc)
        imgui.PopTextWrapPos()
        imgui.EndTooltip()
    }
}

// Utility funcs

SDL2ToImGuiKey :: proc(keycode: sdl2.Scancode) -> imgui.Key {
    #partial switch (keycode)
    {
        case .TAB: return imgui.Key.Tab
        case .LEFT: return imgui.Key.LeftArrow
        case .RIGHT: return imgui.Key.RightArrow
        case .UP: return imgui.Key.UpArrow
        case .DOWN: return imgui.Key.DownArrow
        case .PAGEUP: return imgui.Key.PageUp
        case .PAGEDOWN: return imgui.Key.PageDown
        case .HOME: return imgui.Key.Home
        case .END: return imgui.Key.End
        case .INSERT: return imgui.Key.Insert
        case .DELETE: return imgui.Key.Delete
        case .BACKSPACE: return imgui.Key.Backspace
        case .SPACE: return imgui.Key.Space
        case .RETURN: return imgui.Key.Enter
        case .ESCAPE: return imgui.Key.Escape
        case .APOSTROPHE: return imgui.Key.Apostrophe
        case .COMMA: return imgui.Key.Comma
        case .MINUS: return imgui.Key.Minus
        case .PERIOD: return imgui.Key.Period
        case .SLASH: return imgui.Key.Slash
        case .SEMICOLON: return imgui.Key.Semicolon
        case .EQUALS: return imgui.Key.Equal
        case .LEFTBRACKET: return imgui.Key.LeftBracket
        case .BACKSLASH: return imgui.Key.Backslash
        case .RIGHTBRACKET: return imgui.Key.RightBracket
        case .GRAVE: return imgui.Key.GraveAccent
        case .CAPSLOCK: return imgui.Key.CapsLock
        case .SCROLLLOCK: return imgui.Key.ScrollLock
        case .NUMLOCKCLEAR: return imgui.Key.NumLock
        case .PRINTSCREEN: return imgui.Key.PrintScreen
        case .PAUSE: return imgui.Key.Pause
        case .KP_0: return imgui.Key.Keypad0
        case .KP_1: return imgui.Key.Keypad1
        case .KP_2: return imgui.Key.Keypad2
        case .KP_3: return imgui.Key.Keypad3
        case .KP_4: return imgui.Key.Keypad4
        case .KP_5: return imgui.Key.Keypad5
        case .KP_6: return imgui.Key.Keypad6
        case .KP_7: return imgui.Key.Keypad7
        case .KP_8: return imgui.Key.Keypad8
        case .KP_9: return imgui.Key.Keypad9
        case .KP_PERIOD: return imgui.Key.KeypadDecimal
        case .KP_DIVIDE: return imgui.Key.KeypadDivide
        case .KP_MULTIPLY: return imgui.Key.KeypadMultiply
        case .KP_MINUS: return imgui.Key.KeypadSubtract
        case .KP_PLUS: return imgui.Key.KeypadAdd
        case .KP_ENTER: return imgui.Key.KeypadEnter
        case .KP_EQUALS: return imgui.Key.KeypadEqual
        case .LCTRL: return imgui.Key.LeftCtrl
        case .LSHIFT: return imgui.Key.LeftShift
        case .LALT: return imgui.Key.LeftAlt
        case .LGUI: return imgui.Key.LeftSuper
        case .RCTRL: return imgui.Key.RightCtrl
        case .RSHIFT: return imgui.Key.RightShift
        case .RALT: return imgui.Key.RightAlt
        case .RGUI: return imgui.Key.RightSuper
        case .APPLICATION: return imgui.Key.Menu
        case .NUM0: return imgui.Key._0
        case .NUM1: return imgui.Key._1
        case .NUM2: return imgui.Key._2
        case .NUM3: return imgui.Key._3
        case .NUM4: return imgui.Key._4
        case .NUM5: return imgui.Key._5
        case .NUM6: return imgui.Key._6
        case .NUM7: return imgui.Key._7
        case .NUM8: return imgui.Key._8
        case .NUM9: return imgui.Key._9
        case .A: return imgui.Key.A
        case .B: return imgui.Key.B
        case .C: return imgui.Key.C
        case .D: return imgui.Key.D
        case .E: return imgui.Key.E
        case .F: return imgui.Key.F
        case .G: return imgui.Key.G
        case .H: return imgui.Key.H
        case .I: return imgui.Key.I
        case .J: return imgui.Key.J
        case .K: return imgui.Key.K
        case .L: return imgui.Key.L
        case .M: return imgui.Key.M
        case .N: return imgui.Key.N
        case .O: return imgui.Key.O
        case .P: return imgui.Key.P
        case .Q: return imgui.Key.Q
        case .R: return imgui.Key.R
        case .S: return imgui.Key.S
        case .T: return imgui.Key.T
        case .U: return imgui.Key.U
        case .V: return imgui.Key.V
        case .W: return imgui.Key.W
        case .X: return imgui.Key.X
        case .Y: return imgui.Key.Y
        case .Z: return imgui.Key.Z
        case .F1: return imgui.Key.F1
        case .F2: return imgui.Key.F2
        case .F3: return imgui.Key.F3
        case .F4: return imgui.Key.F4
        case .F5: return imgui.Key.F5
        case .F6: return imgui.Key.F6
        case .F7: return imgui.Key.F7
        case .F8: return imgui.Key.F8
        case .F9: return imgui.Key.F9
        case .F10: return imgui.Key.F10
        case .F11: return imgui.Key.F11
        case .F12: return imgui.Key.F12
        case .F13: return imgui.Key.F13
        case .F14: return imgui.Key.F14
        case .F15: return imgui.Key.F15
        case .F16: return imgui.Key.F16
        case .F17: return imgui.Key.F17
        case .F18: return imgui.Key.F18
        case .F19: return imgui.Key.F19
        case .F20: return imgui.Key.F20
        case .F21: return imgui.Key.F21
        case .F22: return imgui.Key.F22
        case .F23: return imgui.Key.F23
        case .F24: return imgui.Key.F24
        case .AC_BACK: return imgui.Key.AppBack
        case .AC_FORWARD: return imgui.Key.AppForward
    }
    return imgui.Key.None
}

SDL2ToImGuiMouseButton :: proc(button: u8) -> i32 {
    button := i32(button)
    switch button {
        case sdl2.BUTTON_MIDDLE: return sdl2.BUTTON_RIGHT - 1
        case sdl2.BUTTON_RIGHT: return sdl2.BUTTON_MIDDLE - 1
    }
    return button - 1
}