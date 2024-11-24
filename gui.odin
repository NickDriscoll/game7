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

MAX_IMGUI_VERTICES :: 64 * 1024 * 1024
MAX_IMGUI_INDICES :: 16 * 1024 * 1024

ImguiPushConstants :: struct {
    font_idx: u32,
    sampler: vkw.Immutable_Sampler_Index,
    vertex_offset: u32,
    uniform_data: vk.DeviceAddress,
    vertex_data: vk.DeviceAddress
}

ImguiUniforms :: struct {
    clip_from_screen: hlsl.float4x4
}

ImguiState :: struct {
    ctxt: ^imgui.Context,
    font_atlas: vkw.Image_Handle,
    vertex_buffer: vkw.Buffer_Handle,
    index_buffer: vkw.Buffer_Handle,
    uniform_buffer: vkw.Buffer_Handle,
    pipeline: vkw.Pipeline_Handle,
    show_gui: bool
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
        name = "Dear ImGUI font atlas"
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
        required_flags = {.DEVICE_LOCAL}
    }
    imgui_state.vertex_buffer = vkw.create_buffer(gd, &buffer_info)

    // Allocate imgui index buffer
    buffer_info = vkw.Buffer_Info {
        size = MAX_IMGUI_INDICES * size_of(imgui.DrawIdx),
        usage = {.INDEX_BUFFER,.TRANSFER_DST},
        alloc_flags = nil,
        required_flags = {.DEVICE_LOCAL}
    }
    imgui_state.index_buffer = vkw.create_buffer(gd, &buffer_info)

    // Create uniform buffer
    {
        info := vkw.Buffer_Info {
            size = size_of(ImguiUniforms),
            usage = {.UNIFORM_BUFFER,.TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL,.HOST_VISIBLE,.HOST_COHERENT}
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
            primitive_restart_enabled = false
        },
        tessellation_state = {},
        rasterization_state = raster_state,
        multisample_state = vkw.Multisample_State {
            sample_count = {._1},
            do_sample_shading = false,
            min_sample_shading = 0.0,
            sample_mask = nil,
            do_alpha_to_coverage = false,
            do_alpha_to_one = false
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
            max_depth_bounds = 1.0
        },
        colorblend_state = vkw.default_colorblend_state(),
        renderpass_state = vkw.PipelineRenderpass_Info {
            color_attachment_formats = {vk.Format.B8G8R8A8_SRGB},
            depth_attachment_format = nil
        }
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
    imgui_state: ^ImguiState
) {
    // Update uniform buffer
    
    io := imgui.GetIO()
    uniforms: ImguiUniforms
    uniforms.clip_from_screen = {
        2.0 / io.DisplaySize.x, 0.0, 0.0, -1.0,
        0.0, 2.0 / io.DisplaySize.y, 0.0, -1.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0
    }
    u_slice := slice.from_ptr(&uniforms, 1)
    vkw.sync_write_buffer(ImguiUniforms, gd, imgui_state.uniform_buffer, u_slice)

    imgui.Render()
    
    draw_data := imgui.GetDrawData()

    // Temp buffers for collecting imgui vertices/indices from all cmd lists
    vertex_staging := make(
        [dynamic]imgui.DrawVert,
        0,
        draw_data.TotalVtxCount,
        allocator = context.temp_allocator
    )
    index_staging := make(
        [dynamic]imgui.DrawIdx,
        0,
        draw_data.TotalIdxCount,
        allocator = context.temp_allocator
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
                        y = i32(cmd.ClipRect.y)
                    },
                    extent = {
                        width = u32(cmd.ClipRect.z - cmd.ClipRect.x),
                        height = u32(cmd.ClipRect.a - cmd.ClipRect.y)
                    }
                }
            })

            tex_handle := hm.rawptr_to_handle(cmd.TextureId)
            vkw.cmd_push_constants_gfx(ImguiPushConstants, gd, gfx_cb_idx, &ImguiPushConstants {
                font_idx = tex_handle.index,
                sampler = .Point,
                vertex_offset = cmd.VtxOffset + global_vtx_offset + local_vtx_offset,
                uniform_data = uniform_buf.address,
                vertex_data = imgui_vertex_buffer.address
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
    vkw.sync_write_buffer(imgui.DrawVert, gd, imgui_state.vertex_buffer, vertex_staging[:], global_vtx_offset)
    vkw.sync_write_buffer(imgui.DrawIdx, gd, imgui_state.index_buffer, index_staging[:], global_idx_offset)
    
}

imgui_cleanup :: proc(vgd: ^vkw.Graphics_Device, using is: ^ImguiState) {
    imgui.DestroyContext(ctxt)
    vkw.delete_buffer(vgd, vertex_buffer)
    vkw.delete_buffer(vgd, index_buffer)
    vkw.delete_buffer(vgd, uniform_buffer)
}




// Utility funcs

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

