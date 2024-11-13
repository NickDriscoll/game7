package main

import "core:math/linalg/hlsl"
import "core:math"
import hm "desktop_vulkan_wrapper/handlemap"
import imgui "odin-imgui"
import vk "vendor:vulkan"
import vkw "desktop_vulkan_wrapper"

MAX_PER_FRAME_DRAW_CMDS :: 1024
MAX_GLOBAL_VERTICES :: 4*1024*1024
MAX_GLOBAL_INDICES :: 1024*1024
MAX_GLOBAL_MESHES :: 64 * 1024
MAX_GLOBAL_MATERIALS :: 64 * 1024
MAX_GLOBAL_INSTANCES :: 1024 * 1024

UniformBufferData :: struct {
    clip_from_world: hlsl.float4x4,
    clip_from_screen: hlsl.float4x4,
    mesh_ptr: vk.DeviceAddress,
    instance_ptr: vk.DeviceAddress,
    position_ptr: vk.DeviceAddress,
    uv_ptr: vk.DeviceAddress
}

TestPushConstants :: struct {
    time: f32,
    image: u32,
    sampler: vkw.Immutable_Samplers,
    uniform_buffer_address: vk.DeviceAddress
}

PushConstants :: struct {
    time: f32,
    uniform_buffer_ptr: vk.DeviceAddress,
}

AttributeView :: struct {
    start: u32,
    offset: u32
}

PositionViewKey :: distinct hm.Handle
IndexViewKey :: distinct hm.Handle

MeshData :: struct {
    indices_start: u32,
    indices_len: u32,
    position_start: u32,
    uv_start: u32
}

GPUMeshData :: struct {
    position_offset: u32,
    uv_offset: u32,
}

MaterialData :: struct {
    base_color: hlsl.float4
}

DrawData :: struct {
    instance_count: u32,
    position_offset: u32,
    index_offset: u32,
    mesh_idx: Mesh_Handle
}

InstanceData :: struct {
    world_from_model: hlsl.float4x4,
}

GPUInstanceData :: struct {
    world_from_model: hlsl.float4x4,
    // normal_matrix: hlsl.float4x4, // cofactor matrix of above
    mesh_idx: u32,
}

Mesh_Handle :: distinct hm.Handle

GPUBufferFlags :: bit_set[enum{
    Mesh,
    Material,
    Instance,
    Draw
}]

RenderingState :: struct {
    // Vertex attribute buffers
    positions_buffer: vkw.Buffer_Handle,        // Global GPU buffer of vertex positions
    uvs_buffer: vkw.Buffer_Handle,              // Global GPU buffer of vertex uvs

    index_buffer: vkw.Buffer_Handle,            // Global GPU buffer of draw indices

    cpu_meshes: hm.Handle_Map(GPUMeshData),
    mesh_buffer: vkw.Buffer_Handle,             // Global GPU buffer of mesh metadata

    material_buffer: vkw.Buffer_Handle,         // Global GPU buffer of materials

    cpu_instances: [dynamic]InstanceData,
    instance_buffer: vkw.Buffer_Handle,         // Global GPU buffer of instances

    cpu_draws: [dynamic]DrawData,
    draw_buffer: vkw.Buffer_Handle,             // Global GPU buffer of indirect draw args

    uniform_buffer: vkw.Buffer_Handle,          // Uniform buffer

    dirty_flags: GPUBufferFlags,                // Represents which CPU/GPU buffers need synced this cycle

    // Vertex metadata
    // positions_views: hm.Handle_Map(AttributeView),
    // indices_views: hm.Handle_Map(AttributeView),
    positions_offset: u32,
    uvs_offset: u32,
    indices_offset: u32,

    test_pipeline: vkw.Pipeline_Handle,

    // Pipeline buckets
    ps1_pipeline: vkw.Pipeline_Handle,
    ps1_draw_list: [dynamic]DrawData,


    gfx_timeline: vkw.Semaphore_Handle,
    gfx_sync_info: vkw.Sync_Info,
}

init_renderer :: proc(gd: ^vkw.Graphics_Device) -> RenderingState {
    render_state: RenderingState
    //hm.init(&render_state.positions_views)

    // Pipeline creation
    {
        // Load shader bytecode
        // This will be embedded into the executable at compile-time
        vertex_spv := #load("data/shaders/test.vert.spv", []u32)
        fragment_spv := #load("data/shaders/test.frag.spv", []u32)

        ps1_vert_spv := #load("data/shaders/ps1.vert.spv", []u32)
        ps1_frag_spv := #load("data/shaders/ps1.frag.spv", []u32)

        raster_state := vkw.default_rasterization_state()
        raster_state.cull_mode = nil

        pipeline_infos := make([dynamic]vkw.Graphics_Pipeline_Info, context.temp_allocator)

        // Test pipeline
        append(&pipeline_infos, vkw.Graphics_Pipeline_Info {
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
        })

        // PS1 pipeline
        append(&pipeline_infos, vkw.Graphics_Pipeline_Info {
            vertex_shader_bytecode = ps1_vert_spv,
            fragment_shader_bytecode = ps1_frag_spv,
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
        })

        handles := vkw.create_graphics_pipelines(gd, pipeline_infos[:])
        defer delete(handles)

        render_state.test_pipeline = handles[0]
        render_state.ps1_pipeline = handles[1]
    }

    // Create main timeline semaphore
    {
        info := vkw.Semaphore_Info {
            type = .TIMELINE,
            init_value = 0
        }
        render_state.gfx_timeline = vkw.create_semaphore(gd, &info)
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

    // Create storage buffers
    {
        info := vkw.Buffer_Info {
            usage = {.STORAGE_BUFFER,.TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL}
        }

        info.size = size_of(hlsl.float4) * MAX_GLOBAL_VERTICES
        render_state.positions_buffer = vkw.create_buffer(gd, &info)

        info.size = size_of(hlsl.float2) * MAX_GLOBAL_VERTICES
        render_state.uvs_buffer = vkw.create_buffer(gd, &info)

        info.size = size_of(GPUMeshData) * MAX_GLOBAL_MESHES
        render_state.mesh_buffer = vkw.create_buffer(gd, &info)

        info.size = size_of(MaterialData) * MAX_GLOBAL_MATERIALS
        render_state.material_buffer = vkw.create_buffer(gd, &info)

        info.size = size_of(GPUInstanceData) * MAX_GLOBAL_INSTANCES
        render_state.instance_buffer = vkw.create_buffer(gd, &info)
    }

    // Create indirect draw buffer
    {
        info := vkw.Buffer_Info {
            size = size_of(vk.DrawIndexedIndirectCommand) * MAX_PER_FRAME_DRAW_CMDS,
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

delete_renderer :: proc(vgd: ^vkw.Graphics_Device, using r: ^RenderingState) {
    vkw.delete_sync_info(&gfx_sync_info)
    //hm.destroy(&positions_views)
}

create_mesh :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^RenderingState,
    positions: []hlsl.float4,
    indices: []u16
) -> Mesh_Handle {
    
    //positions_view_handle: hm.Handle
    position_start: u32
    {
        positions_len := u32(len(positions))
        assert(positions_offset + positions_len < MAX_GLOBAL_VERTICES)
    
        position_start := positions_offset
        positions_offset += positions_len
    
        vkw.sync_write_buffer(hlsl.float4, gd, positions_buffer, positions, position_start)
    
        // positions_view_handle = hm.insert(&positions_views, AttributeView {
        //     start = position_start,
        //     offset = positions_offset
        // })
    }

    //indices_view_handle: hm.Handle
    indices_start: u32
    {
        indices_len := u32(len(indices))
        assert(indices_offset + indices_len < MAX_GLOBAL_INDICES)

        indices_start := indices_offset
        indices_offset += indices_len

        vkw.sync_write_buffer(u16, gd, index_buffer, indices, indices_start)

        // indices_view_handle = hm.insert(&indices_views, AttributeView {
        //     start = start,
        //     offset = indices_offset
        // })
    }



    mesh := GPUMeshData {
        position_offset = position_start,
        uv_offset = 0
    }
    handle := Mesh_Handle(hm.insert(&cpu_meshes, mesh))

    dirty_flags += {.Mesh}

    return handle
}

// User code calls this to queue up draw calls
draw_instances :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^RenderingState,
    mesh_handle: Mesh_Handle,
    instances: []InstanceData
) {
    dirty_flags += {.Instance}
    for instance in instances {
        append(&cpu_instances, instance)
    }
}

// This is called once per frame to sync buffer with the GPU
// and record the relevant commands into the frame's command buffer
render :: proc(
    gd: ^vkw.Graphics_Device,
    gfx_cb_idx: vkw.CommandBuffer_Index,
    using r: ^RenderingState,
    framebuffer: ^vkw.Framebuffer
) {
    // Sync CPU and GPU buffers

    // Mesh buffer
    if .Mesh in dirty_flags {
        //vkw.sync_write_buffer(GPUMeshData, gd, mesh_buffer, cpu_m)
    }

    vkw.cmd_begin_render_pass(gd, gfx_cb_idx, framebuffer)
    
    vkw.cmd_bind_index_buffer(gd, gfx_cb_idx, index_buffer)

    
    vkw.cmd_bind_descriptor_set(gd, gfx_cb_idx)
    vkw.cmd_bind_pipeline(gd, gfx_cb_idx, .GRAPHICS, test_pipeline)

    res := framebuffer.resolution
    vkw.cmd_set_viewport(gd, gfx_cb_idx, 0, {vkw.Viewport {
        x = 0.0,
        y = 0.0,
        width = f32(res.x),
        height = f32(res.y),
        minDepth = 0.0,
        maxDepth = 1.0
    }})
    vkw.cmd_set_scissor(gd, gfx_cb_idx, 0, {
        {
            offset = vk.Offset2D {
                x = 0,
                y = 0
            },
            extent = vk.Extent2D {
                width = u32(res.x),
                height = u32(res.y),
            }
        }
    })

            
    t := f32(gd.frame_count) / 144.0
    uniform_buf, ok := vkw.get_buffer(gd, uniform_buffer)
    vkw.cmd_push_constants_gfx(PushConstants, gd, gfx_cb_idx, &PushConstants {
        time = t,
        uniform_buffer_ptr = uniform_buf.address
    })

    // There will be one vkCmdDrawIndexedIndirect() per distinct "ubershader" pipeline
    vkw.cmd_draw_indexed_indirect(gd, gfx_cb_idx, draw_buffer, 0, 1)
}