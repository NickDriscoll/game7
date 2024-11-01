package main

import "core:math/linalg/hlsl"
import "core:math"
import hm "desktop_vulkan_wrapper/handlemap"
import imgui "odin-imgui"
import vk "vendor:vulkan"
import vkw "desktop_vulkan_wrapper"

MAX_PER_FRAME_DRAW_CALLS :: 1024
MAX_GLOBAL_VERTICES :: 4*1024*1024
MAX_GLOBAL_INDICES :: 1024*1024

UniformBufferData :: struct {
    clip_from_world: hlsl.float4x4,
    clip_from_screen: hlsl.float4x4
}

PushConstants :: struct {
    time: f32,
    image: u32,
    sampler: vkw.Immutable_Samplers,
    uniform_buffer_address: vk.DeviceAddress
}

AttributeView :: struct {
    start: u32,
    offset: u32
}

Mesh_Handle :: distinct hm.Handle

RenderingState :: struct {
    // Vertex attribute buffers
    positions_buffer: vkw.Buffer_Handle,
    uvs_buffer: vkw.Buffer_Handle,

    // Vertex metadata
    positions_views: hm.Handle_Map(AttributeView),
    positions_offset: u32,
    uvs_offset: u32,

    index_buffer: vkw.Buffer_Handle,
    draw_buffer: vkw.Buffer_Handle,
    uniform_buffer: vkw.Buffer_Handle,
    gfx_pipeline: vkw.Pipeline_Handle,
    gfx_timeline: vkw.Semaphore_Handle,
    gfx_sync_info: vkw.Sync_Info,
}

init_rendering_state :: proc(gd: ^vkw.Graphics_Device) -> RenderingState {
    render_state: RenderingState
    hm.init(&render_state.positions_views)

    // Pipeline creation
    {
        // Load shader bytecode
        // This will be embedded into the executable at compile-time
        vertex_spv := #load("data/shaders/test.vert.spv", []u32)
        fragment_spv := #load("data/shaders/test.frag.spv", []u32)

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

        render_state.gfx_pipeline = handles[0]
    }

    // Create main timeline semaphore
    {
        info := vkw.Semaphore_Info {
            type = .TIMELINE,
            init_value = 0
        }
        render_state.gfx_timeline = vkw.create_semaphore(gd, &info)
    }

    // Create vertex buffers
    {
        info := vkw.Buffer_Info {
            size = size_of(hlsl.float4) * MAX_GLOBAL_VERTICES,
            usage = {.STORAGE_BUFFER,.TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL}
        }
        render_state.positions_buffer = vkw.create_buffer(gd, &info)

        info.size = size_of(hlsl.float2) * MAX_GLOBAL_VERTICES
        render_state.uvs_buffer = vkw.create_buffer(gd, &info)
    }

    // Create index buffer
    {
        info := vkw.Buffer_Info {
            size = size_of(u16) * MAX_GLOBAL_INDICES,
            usage = {.INDEX_BUFFER, .TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL}
        }
        render_state.index_buffer = vkw.create_buffer(gd, &info)
    }

    // Create indirect draw buffer
    {
        info := vkw.Buffer_Info {
            size = 64,
            usage = {.INDIRECT_BUFFER,.TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL}
        }
        render_state.draw_buffer = vkw.create_buffer(gd, &info)
    }

    // Create uniform buffer
    {
        info := vkw.Buffer_Info {
            size = size_of(UniformBufferData),
            usage = {.UNIFORM_BUFFER,.TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL,.HOST_VISIBLE,.HOST_COHERENT}
        }
        render_state.uniform_buffer = vkw.create_buffer(gd, &info)
    }

    return render_state
}

delete_rendering_state :: proc(vgd: ^vkw.Graphics_Device, r: ^RenderingState) {
    vkw.delete_sync_info(&r.gfx_sync_info)
}

create_mesh :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^RenderingState,
    positions: []hlsl.float4,
    indices: []u16
) {
    positions_len := u32(len(positions))
    assert(positions_offset + positions_len < MAX_GLOBAL_VERTICES)

    start := positions_offset
    positions_offset += positions_len

    vkw.sync_write_buffer(hlsl.float4, gd, positions_buffer, positions, start)

    positions_view_handle := hm.insert(&positions_views, AttributeView {
        start = start,
        offset = positions_offset
    })


}