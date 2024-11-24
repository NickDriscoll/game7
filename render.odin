package main

import "core:fmt"
import "core:log"
import "core:math/linalg/hlsl"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import "vendor:cgltf"
import stbi "vendor:stb/image"
import hm "desktop_vulkan_wrapper/handlemap"
import imgui "odin-imgui"
import vk "vendor:vulkan"
import vkw "desktop_vulkan_wrapper"

MAX_GLOBAL_DRAW_CMDS :: 64 * 1024
MAX_GLOBAL_VERTICES :: 4*1024*1024
MAX_GLOBAL_INDICES :: 1024*1024
MAX_GLOBAL_MESHES :: 64 * 1024
MAX_GLOBAL_MATERIALS :: 64 * 1024
MAX_GLOBAL_INSTANCES :: 1024 * 1024

NULL_OFFSET :: 0xFFFFFFFF

FRAMES_IN_FLIGHT :: 2

UniformBufferData :: struct {
    clip_from_world: hlsl.float4x4,
    clip_from_screen: hlsl.float4x4,
    mesh_ptr: vk.DeviceAddress,
    instance_ptr: vk.DeviceAddress,
    material_ptr: vk.DeviceAddress,
    position_ptr: vk.DeviceAddress,
    uv_ptr: vk.DeviceAddress,
    color_ptr: vk.DeviceAddress,
    time: f32,
    distortion_strength: f32
}

TestPushConstants :: struct {
    time: f32,
    image: u32,
    sampler: vkw.Immutable_Sampler_Index,
    uniform_buffer_address: vk.DeviceAddress
}

PushConstants :: struct {
    uniform_buffer_ptr: vk.DeviceAddress,
}

PostFxPushConstants :: struct {
    color_target: u32,
    sampler_idx: u32,
    uniforms_address: vk.DeviceAddress
}

CPUMeshData :: struct {
    indices_start: u32,
    indices_len: u32,
    gpu_data: GPUMeshData
}

GPUMeshData :: struct {
    position_offset: u32,
    uv_offset: u32,
    color_offset: u32
}

MaterialData :: struct {
    color_texture: u32,
    normal_texture: u32,
    arm_texture: u32,           // "arm" as in ambient roughness metalness, packed in RGB in that order    
    sampler_idx: u32,
    base_color: hlsl.float4
}

InstanceData :: struct {
    world_from_model: hlsl.float4x4,
}

GPUInstanceData :: struct {
    world_from_model: hlsl.float4x4,
    // normal_matrix: hlsl.float4x4, // cofactor matrix of above
    mesh_idx: u32,
    material_idx: u32,
    _pad0: hlsl.uint2,
    _pad3: hlsl.float4x3
}

GPUBufferDirtyFlags :: bit_set[enum{
    Mesh,
    Material,
    Instance,
    Draw
}]

DrawData :: struct {
    instance_count: u32,
    instance_offset: u32,
    index_count: u32,
    index_offset: u32
}

DrawPrimitive :: struct {
    mesh: Mesh_Handle,
    material: Material_Handle
}

RenderTarget :: struct {

}

Mesh_Handle :: distinct hm.Handle
Material_Handle :: distinct hm.Handle

RenderingState :: struct {
    positions_buffer: vkw.Buffer_Handle,        // Global GPU buffer of vertex positions
    positions_head: u32,

    index_buffer: vkw.Buffer_Handle,            // Global GPU buffer of draw indices
    indices_head: u32,
    
    
    uvs_buffer: vkw.Buffer_Handle,              // Global GPU buffer of vertex uvs
    uvs_head: u32,

    colors_buffer: vkw.Buffer_Handle,              // Global GPU buffer of vertex colors
    colors_head: u32,

    // Global GPU buffer of mesh metadata
    // i.e. offsets into the vertex attribute buffers
    mesh_buffer: vkw.Buffer_Handle,
    cpu_meshes: hm.Handle_Map(CPUMeshData),
    gpu_meshes: [dynamic]GPUMeshData,
    
    
    material_buffer: vkw.Buffer_Handle,             // Global GPU buffer of materials
    cpu_materials: hm.Handle_Map(MaterialData),
    
    cpu_instances: [dynamic]GPUInstanceData,
    instance_buffer: vkw.Buffer_Handle,             // Global GPU buffer of instances
    instance_head: u32,                             // Index of next instance. Reset per-frame

    cpu_uniforms: UniformBufferData,
    uniform_buffer: vkw.Buffer_Handle,              // Global uniform buffer

    dirty_flags: GPUBufferDirtyFlags,               // Represents which CPU/GPU buffers need synced this cycle

    // Pipeline buckets
    ps1_pipeline: vkw.Pipeline_Handle,
    ps1_draws: [dynamic]DrawData,

    postfx_pipeline: vkw.Pipeline_Handle,

    draw_buffer: vkw.Buffer_Handle,             // Global GPU buffer of indirect draw args

    // Sync primitives
    gfx_timeline: vkw.Semaphore_Handle,
    gfx_sync_info: vkw.Sync_Info,

    // Main render target
    main_framebuffer: vkw.Framebuffer
}

init_renderer :: proc(gd: ^vkw.Graphics_Device, screen_size: hlsl.uint2) -> RenderingState {
    render_state: RenderingState

    main_color_attachment_formats : []vk.Format = {vk.Format.R8G8B8A8_UNORM}
    //main_color_attachment_formats : []vk.Format = {vk.Format.B8G8R8A8_SRGB}
    main_depth_attachment_format := vk.Format.D32_SFLOAT

    swapchain_format := vk.Format.B8G8R8A8_SRGB

    // Create main timeline semaphore
    {
        info := vkw.Semaphore_Info {
            type = .TIMELINE,
            init_value = 0,
            name = "GFX Timeline"
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
        log.debugf("Allocated %v MB of memory for render_state.index_buffer", f32(info.size) / 1024 / 1024)
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
        log.debugf("Allocated %v MB of memory for render_state.positions_buffer", f32(info.size) / 1024 / 1024)

        info.size = size_of(hlsl.float2) * MAX_GLOBAL_VERTICES
        render_state.uvs_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.uvs_buffer", f32(info.size) / 1024 / 1024)

        info.size = size_of(hlsl.float4) * MAX_GLOBAL_VERTICES
        render_state.colors_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.colors_buffer", f32(info.size) / 1024 / 1024)

        info.size = size_of(GPUMeshData) * MAX_GLOBAL_MESHES
        render_state.mesh_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.mesh_buffer", f32(info.size) / 1024 / 1024)

        info.size = size_of(MaterialData) * MAX_GLOBAL_MATERIALS
        render_state.material_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.material_buffer", f32(info.size) / 1024 / 1024)

        info.size = size_of(GPUInstanceData) * MAX_GLOBAL_INSTANCES
        render_state.instance_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.instance_buffer", f32(info.size) / 1024 / 1024)
    }

    // Create indirect draw buffer
    {
        info := vkw.Buffer_Info {
            size = size_of(vk.DrawIndexedIndirectCommand) * MAX_GLOBAL_DRAW_CMDS,
            usage = {.INDIRECT_BUFFER,.TRANSFER_DST},
            alloc_flags = {.Mapped},
            required_flags = {.DEVICE_LOCAL,.HOST_VISIBLE,.HOST_COHERENT}
        }
        render_state.draw_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.draw_buffer", f32(info.size) / 1024 / 1024)
    }

    // Create uniform buffer
    {
        info := vkw.Buffer_Info {
            size = size_of(UniformBufferData),
            usage = {.UNIFORM_BUFFER,.TRANSFER_DST},
            alloc_flags = {.Mapped},
            required_flags = {.DEVICE_LOCAL,.HOST_VISIBLE,.HOST_COHERENT}
        }
        render_state.uniform_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.uniform", f32(info.size) / 1024 / 1024)
    }

    // Create main rendertarget
    {
        color_target := vkw.Image_Create {
            flags = nil,
            image_type = .D2,
            format = .R8G8B8A8_UNORM,
            extent = {
                width = screen_size.x,
                height = screen_size.y,
                depth = 1
            },
            supports_mipmaps = false,
            array_layers = 1,
            samples = {._1},
            tiling = .OPTIMAL,
            usage = {.SAMPLED,.COLOR_ATTACHMENT},
            alloc_flags = nil,
            name = "Main color target"
        }
        color_target_handle := vkw.new_bindless_image(gd, &color_target, .COLOR_ATTACHMENT_OPTIMAL)

        depth_target := vkw.Image_Create {
            flags = nil,
            image_type = .D2,
            format = .D32_SFLOAT,
            extent = {
                width = screen_size.x,
                height = screen_size.y,
                depth = 1
            },
            supports_mipmaps = false,
            array_layers = 1,
            samples = {._1},
            tiling = .OPTIMAL,
            usage = {.SAMPLED,.DEPTH_STENCIL_ATTACHMENT},
            alloc_flags = nil,
            name = "Main depth target"
        }
        depth_handle := vkw.new_bindless_image(gd, &depth_target, .DEPTH_ATTACHMENT_OPTIMAL)

        color_images: [8]vkw.Image_Handle
        color_images[0] = color_target_handle
        render_state.main_framebuffer = {
            color_images = color_images,
            depth_image = depth_handle,
            resolution = screen_size,
            clear_color = {1.0, 0.0, 1.0, 1.0},
            color_load_op = .CLEAR,
            depth_load_op = .CLEAR
        }
    }

    // Pipeline creation
    {
        // Load shader bytecode
        // This will be embedded into the executable at compile-time
        ps1_vert_spv := #load("data/shaders/ps1.vert.spv", []u32)
        ps1_frag_spv := #load("data/shaders/ps1.frag.spv", []u32)

        raster_state := vkw.default_rasterization_state()
        raster_state.cull_mode = nil

        pipeline_infos := make([dynamic]vkw.Graphics_Pipeline_Info, context.temp_allocator)

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
                do_depth_test = true,
                do_depth_write = true,
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
                color_attachment_formats = main_color_attachment_formats,
                depth_attachment_format = main_depth_attachment_format
            }
        })

        // Postprocessing pass info

        postfx_vert_spv := #load("data/shaders/postprocessing.vert.spv", []u32)
        postfx_frag_spv := #load("data/shaders/postprocessing.frag.spv", []u32)

        append(&pipeline_infos, vkw.Graphics_Pipeline_Info {
            vertex_shader_bytecode = postfx_vert_spv,
            fragment_shader_bytecode = postfx_frag_spv,
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
                color_attachment_formats = {swapchain_format},
                depth_attachment_format = nil
            }
        })

        handles := vkw.create_graphics_pipelines(gd, pipeline_infos[:])
        defer delete(handles)

        render_state.ps1_pipeline = handles[0]
        render_state.postfx_pipeline = handles[1]
    }

    return render_state
}

delete_renderer :: proc(vgd: ^vkw.Graphics_Device, using r: ^RenderingState) {
    vkw.delete_sync_info(&gfx_sync_info)
}

resize_framebuffers :: proc(gd: ^vkw.Graphics_Device, using r: ^RenderingState, screen_size: hlsl.uint2) {
    vkw.delete_image(gd, main_framebuffer.color_images[0])
    vkw.delete_image(gd, main_framebuffer.depth_image)
    

    // Create main rendertarget
    {
        color_target := vkw.Image_Create {
            flags = nil,
            image_type = .D2,
            format = .R8G8B8A8_UNORM,
            extent = {
                width = screen_size.x,
                height = screen_size.y,
                depth = 1
            },
            supports_mipmaps = false,
            array_layers = 1,
            samples = {._1},
            tiling = .OPTIMAL,
            usage = {.SAMPLED,.COLOR_ATTACHMENT},
            alloc_flags = nil,
            name = "Main color target"
        }
        color_target_handle := vkw.new_bindless_image(gd, &color_target, .COLOR_ATTACHMENT_OPTIMAL)

        depth_target := vkw.Image_Create {
            flags = nil,
            image_type = .D2,
            format = .D32_SFLOAT,
            extent = {
                width = screen_size.x,
                height = screen_size.y,
                depth = 1
            },
            supports_mipmaps = false,
            array_layers = 1,
            samples = {._1},
            tiling = .OPTIMAL,
            usage = {.DEPTH_STENCIL_ATTACHMENT},
            alloc_flags = nil,
            name = "Main depth target"
        }
        depth_handle := vkw.new_bindless_image(gd, &depth_target, .DEPTH_ATTACHMENT_OPTIMAL)

        color_images: [8]vkw.Image_Handle
        color_images[0] = color_target_handle
        main_framebuffer = {
            color_images = color_images,
            depth_image = depth_handle,
            resolution = screen_size,
            clear_color = {1.0, 0.0, 1.0, 1.0},
            color_load_op = .CLEAR,
            depth_load_op = .CLEAR
        }
    }
}

create_mesh :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^RenderingState,
    positions: []hlsl.float4,
    indices: []u16
) -> Mesh_Handle {
    
    position_start: u32
    {
        positions_len := u32(len(positions))
        assert(positions_head + positions_len < MAX_GLOBAL_VERTICES)
        assert(positions_len > 0)
    
        position_start = positions_head
        positions_head += positions_len
    
        vkw.sync_write_buffer(hlsl.float4, gd, positions_buffer, positions, position_start)
    }

    indices_start: u32
    indices_len: u32
    {
        indices_len = u32(len(indices))
        assert(indices_head + indices_len < MAX_GLOBAL_INDICES)
        assert(indices_len > 0)

        indices_start = indices_head
        indices_head += indices_len

        vkw.sync_write_buffer(u16, gd, index_buffer, indices, indices_start)
    }

    mesh := CPUMeshData {
        indices_start = indices_start,
        indices_len = indices_len,
    }
    handle := Mesh_Handle(hm.insert(&cpu_meshes, mesh))

    gpu_mesh := GPUMeshData {
        position_offset = position_start,
        uv_offset = NULL_OFFSET,
        color_offset = NULL_OFFSET
    }
    append(&gpu_meshes, gpu_mesh)

    dirty_flags += {.Mesh}

    return handle
}

add_vertex_colors :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^RenderingState,
    handle: Mesh_Handle,
    colors: []hlsl.float4
) -> bool {
    color_start := colors_head
    colors_len := u32(len(colors))
    assert(colors_head + colors_len < MAX_GLOBAL_VERTICES)
    assert(colors_len > 0)

    colors_head += colors_len

    gpu_mesh := &gpu_meshes[handle.index]
    gpu_mesh.color_offset = color_start

    return vkw.sync_write_buffer(hlsl.float4, gd, colors_buffer, colors, color_start)
}

add_vertex_uvs :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^RenderingState,
    handle: Mesh_Handle,
    uvs: []hlsl.float2
) -> bool {
    uv_start := uvs_head
    uvs_len := u32(len(uvs))
    assert(uvs_head + uvs_len < MAX_GLOBAL_VERTICES)
    assert(uvs_len > 0)

    uvs_head += uvs_len

    gpu_mesh := &gpu_meshes[handle.index]
    gpu_mesh.uv_offset = uv_start

    return vkw.sync_write_buffer(hlsl.float2, gd, uvs_buffer, uvs, uv_start)
}

add_material :: proc(using r: ^RenderingState, new_mat: ^MaterialData) -> Material_Handle {
    dirty_flags += {.Material}
    return Material_Handle(hm.insert(&cpu_materials, new_mat^))
}

// User code calls this to queue up draw calls
draw_ps1_primitives :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^RenderingState,
    mesh_handle: Mesh_Handle,
    material_handle: Material_Handle,
    instances: []InstanceData
) {
    dirty_flags += {.Instance,.Draw}

    cpu_mesh, ok := hm.get(&cpu_meshes, hm.Handle(mesh_handle))
    if !ok {
        log.error("Failed to fetch CPU mesh data")
    }

    for instance in instances {
        gi := GPUInstanceData {
            world_from_model = instance.world_from_model,
            mesh_idx = mesh_handle.index,
            material_idx = material_handle.index
        }
        append(&cpu_instances, gi)
    }

    instance_count := u32(len(instances))

    dd := DrawData {
        instance_count = instance_count,
        instance_offset = instance_head,
        index_count = cpu_mesh.indices_len,
        index_offset = cpu_mesh.indices_start
    }
    append(&ps1_draws, dd)

    instance_head += instance_count
}

// This is called once per frame to sync buffer with the GPU
// and record the relevant commands into the frame's command buffer
render :: proc(
    gd: ^vkw.Graphics_Device,
    gfx_cb_idx: vkw.CommandBuffer_Index,
    using r: ^RenderingState,
    viewport_camera: ^Camera,
    framebuffer: ^vkw.Framebuffer
) {
    // Sync CPU and GPU buffers

    // Mesh buffer
    if .Mesh in dirty_flags {
        vkw.sync_write_buffer(GPUMeshData, gd, mesh_buffer, gpu_meshes[:])
    }

    // Material buffer
    if .Material in dirty_flags {
        vkw.sync_write_buffer(MaterialData, gd, material_buffer, cpu_materials.values[:])
    }

    // Instance buffer
    if .Instance in dirty_flags {
        vkw.sync_write_buffer(GPUInstanceData, gd, instance_buffer, cpu_instances[:])
    }

    // Draw buffer
    if .Draw in dirty_flags {
        gpu_draws := make([dynamic]vk.DrawIndexedIndirectCommand, len(ps1_draws), context.temp_allocator)
        defer delete(gpu_draws)

        for draw_data, i in ps1_draws {
            gpu_draw := vk.DrawIndexedIndirectCommand {
                indexCount = draw_data.index_count,
                instanceCount = draw_data.instance_count,
                firstIndex = draw_data.index_offset,
                vertexOffset = 0,
                firstInstance = draw_data.instance_offset
            }
            gpu_draws[i] = gpu_draw
        }

        vkw.sync_write_buffer(vk.DrawIndexedIndirectCommand, gd, draw_buffer, gpu_draws[:])
    }

    // Update uniforms buffer
    {
                
        cpu_uniforms.clip_from_world =
            camera_projection_from_view(viewport_camera) *
            camera_view_from_world(viewport_camera)

        io := imgui.GetIO()
        cpu_uniforms.clip_from_screen = {
            2.0 / io.DisplaySize.x, 0.0, 0.0, -1.0,
            0.0, 2.0 / io.DisplaySize.y, 0.0, -1.0,
            0.0, 0.0, 1.0, 0.0,
            0.0, 0.0, 0.0, 1.0
        }
        cpu_uniforms.time = f32(gd.frame_count) / 144

        mesh_buffer, _ := vkw.get_buffer(gd, mesh_buffer)
        material_buffer, _ := vkw.get_buffer(gd, material_buffer)
        instance_buffer, _ := vkw.get_buffer(gd, instance_buffer)
        position_buffer, _ := vkw.get_buffer(gd, positions_buffer)
        uv_buffer, _ := vkw.get_buffer(gd, uvs_buffer)
        color_buffer, _ := vkw.get_buffer(gd, colors_buffer)

        cpu_uniforms.mesh_ptr = mesh_buffer.address
        cpu_uniforms.material_ptr = material_buffer.address
        cpu_uniforms.instance_ptr = instance_buffer.address
        cpu_uniforms.position_ptr = position_buffer.address
        cpu_uniforms.uv_ptr = uv_buffer.address
        cpu_uniforms.color_ptr = color_buffer.address

        in_slice := slice.from_ptr(&cpu_uniforms, 1)
        if !vkw.sync_write_buffer(UniformBufferData, gd, uniform_buffer, in_slice) {
            log.error("Failed to write uniform buffer data")
        }
    }

    // Clear dirty flags after checking them
    dirty_flags = {}
    
    vkw.cmd_bind_index_buffer(gd, gfx_cb_idx, index_buffer)
    vkw.cmd_bind_descriptor_set(gd, gfx_cb_idx)
    vkw.cmd_bind_pipeline(gd, gfx_cb_idx, .GRAPHICS, ps1_pipeline)

    // Transition internal color buffer to COLOR_ATTACHMENT_OPTIMAL
    color_target, ok3 := vkw.get_image(gd, main_framebuffer.color_images[0])
    vkw.cmd_gfx_pipeline_barriers(gd, gfx_cb_idx, {
        vkw.Image_Barrier {
            src_stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
            src_access_mask = {.MEMORY_WRITE},
            dst_stage_mask = {.ALL_COMMANDS},
            dst_access_mask = {.MEMORY_READ,.MEMORY_WRITE},
            old_layout = .UNDEFINED,
            new_layout = .COLOR_ATTACHMENT_OPTIMAL,
            src_queue_family = gd.gfx_queue_family,
            dst_queue_family = gd.gfx_queue_family,
            image = color_target.image,
            subresource_range = vk.ImageSubresourceRange {
                aspectMask = {.COLOR},
                baseMipLevel = 0,
                levelCount = 1,
                baseArrayLayer = 0,
                layerCount = 1
            }
        }
    })

    vkw.cmd_begin_render_pass(gd, gfx_cb_idx, &main_framebuffer)
    //vkw.cmd_begin_render_pass(gd, gfx_cb_idx, framebuffer)

    res := main_framebuffer.resolution
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
        uniform_buffer_ptr = uniform_buf.address
    })

    // There will be one vkCmdDrawIndexedIndirect() per distinct "ubershader" pipeline
    vkw.cmd_draw_indexed_indirect(gd, gfx_cb_idx, draw_buffer, 0, u32(len(ps1_draws)))

    vkw.cmd_end_render_pass(gd, gfx_cb_idx)
    
    // Reset per-frame state vars
    instance_head = 0
    clear(&ps1_draws)
    clear(&cpu_instances)

    // Postprocessing step to write final output
    framebuffer_color_target, ok4 := vkw.get_image(gd, framebuffer.color_images[0])

    // Transition internal framebuffer to be sampled from
    vkw.cmd_gfx_pipeline_barriers(gd, gfx_cb_idx,
        {
            {
                src_stage_mask = {.COLOR_ATTACHMENT_OUTPUT},
                src_access_mask = {.MEMORY_WRITE},
                dst_stage_mask = {.ALL_COMMANDS},
                dst_access_mask = {.MEMORY_READ},
                old_layout = .COLOR_ATTACHMENT_OPTIMAL,
                new_layout = .SHADER_READ_ONLY_OPTIMAL,
                src_queue_family = gd.gfx_queue_family,
                dst_queue_family = gd.gfx_queue_family,
                image = color_target.image,
                subresource_range = vk.ImageSubresourceRange {
                    aspectMask = {.COLOR},
                    baseMipLevel = 0,
                    levelCount = 1,
                    baseArrayLayer = 0,
                    layerCount = 1
                }
            }
        }
    )
    
    vkw.cmd_begin_render_pass(gd, gfx_cb_idx, framebuffer)
    vkw.cmd_bind_pipeline(gd, gfx_cb_idx, .GRAPHICS, postfx_pipeline)

    vkw.cmd_push_constants_gfx(PostFxPushConstants, gd, gfx_cb_idx, &PostFxPushConstants{
        color_target = main_framebuffer.color_images[0].index,
        sampler_idx = u32(vkw.Immutable_Sampler_Index.PostFX),
        uniforms_address = uniform_buf.address
    })

    // Draw screen-filling triangle
    vkw.cmd_draw(gd, gfx_cb_idx, 3, 1, 0, 0)

    vkw.cmd_end_render_pass(gd, gfx_cb_idx)
}




GltfData :: struct {
    primitives: [dynamic]DrawPrimitive
}

gltf_delete :: proc(using d: ^GltfData)  {
    delete(primitives)
}

load_gltf_mesh :: proc(
    gd: ^vkw.Graphics_Device,
    render_data: ^RenderingState,
    path: cstring,
    allocator := context.allocator
) -> GltfData {


    get_accessor_ptr :: proc(using a: ^cgltf.accessor, $T: typeid) -> [^]T {
        base_ptr := buffer_view.buffer.data
        offset_ptr := mem.ptr_offset(cast(^byte)base_ptr, a.offset + buffer_view.offset)
        return cast([^]T)offset_ptr
    }

    get_bufferview_ptr :: proc(using b: ^cgltf.buffer_view, $T: typeid) -> [^]T {
        base_ptr := buffer.data
        offset_ptr := mem.ptr_offset(cast(^byte)base_ptr, offset)
        return cast([^]T)offset_ptr
    }

    
    
    gltf_data, res := cgltf.parse_file({}, path)
    if res != .success {
        log.errorf("Failed to load glTF \"%v\"\nerror: %v", path, res)
    }
    defer cgltf.free(gltf_data)
    
    // Load buffers
    res = cgltf.load_buffers({}, gltf_data, path)
    if res != .success {
        log.errorf("Failed to load glTF buffers\nerror: %v", path, res)
    }
    
    loaded_glb_images := make([dynamic]vkw.Image_Handle, len(gltf_data.textures), context.temp_allocator)
    defer delete(loaded_glb_images)

    // Load all textures
    for glb_texture, i in gltf_data.textures {
        glb_image := glb_texture.image_
        data_ptr := get_bufferview_ptr(glb_image.buffer_view, byte)
        log.debugf("Image mime type: %v", glb_image.mime_type)

        channels : i32 = 4
        width, height: i32
        raw_image_ptr := stbi.load_from_memory(data_ptr, i32(glb_image.buffer_view.size), &width, &height, &channels, channels)

        image_create_info := vkw.Image_Create {
            flags = nil,
            image_type = .D2,
            format = .R8G8B8A8_SRGB,
            extent = {
                width = u32(width),
                height = u32(height),
                depth = 1
            },
            supports_mipmaps = false,
            array_layers = 1,
            samples = {._1},
            tiling = .OPTIMAL,
            usage = {.SAMPLED,.TRANSFER_DST},
            alloc_flags = nil,
            name = glb_image.name
        }
        image_slice := slice.from_ptr(raw_image_ptr, int(width * height * channels))
        handle, ok := vkw.sync_create_image_with_data(gd, &image_create_info, image_slice)
        if !ok {
            log.error("Error loading image from glb")
        }
        //append(&loaded_glb_images, handle)
        loaded_glb_images[i] = handle
    }
    
    // For now just loading the first mesh we see
    mesh := gltf_data.meshes[0]

    draw_primitives := make([dynamic]DrawPrimitive, len(mesh.primitives), allocator)

    for primitive, i in mesh.primitives {
        // Get indices
        index_data: [dynamic]u16
        defer delete(index_data)
        indices_count := primitive.indices.count
        indices_bytes := indices_count * size_of(u16)
        resize(&index_data, indices_count)
        index_ptr := get_accessor_ptr(primitive.indices, u16)
        mem.copy(raw_data(index_data), index_ptr, int(indices_bytes))
        //log.debugf("index data: %v", index_data)
    
        // Get vertex data
        position_data: [dynamic]hlsl.float4
        defer delete(position_data)
        color_data: [dynamic]hlsl.float4
        defer delete(color_data)
        uv_data: [dynamic]hlsl.float2
        defer delete(uv_data)
    
        for attrib in primitive.attributes {
            #partial switch (attrib.type) {
                case .position: {
                    resize(&position_data, attrib.data.count)
                    log.debugf("Position data type: %v", attrib.data.type)
                    log.debugf("Position count: %v", attrib.data.count)
                    position_ptr := get_accessor_ptr(attrib.data, hlsl.float3)
                    position_bytes := attrib.data.count * size_of(hlsl.float3)
    
                    // Build up positions buffer
                    // We have to append a 1.0 to all positions
                    // in line with homogenous coordinates
                    for i in 0..<attrib.data.count {
                        pos := position_ptr[i]
                        position_data[i] = {pos.x, pos.y, pos.z, 1.0}
                    }
    
                    //log.debugf("Position data: %v", position_data)
                }
                case .color: {
                    resize(&color_data, attrib.data.count)
                    log.debugf("Color data type: %v", attrib.data.type)
                    log.debugf("Color count: %v", attrib.data.count)
                    color_ptr := get_accessor_ptr(attrib.data, hlsl.float3)
                    color_bytes := attrib.data.count * size_of(hlsl.float3)
    
                    for i in 0..<attrib.data.count {
                        col := color_ptr[i]
                        color_data[i] = {col.x, col.y, col.z, 1.0}
                    }
                    
                    //log.debugf("Color data: %v", color_data)
                }
                case .texcoord: {
                    resize(&uv_data, attrib.data.count)
                    log.debugf("UV data type: %v", attrib.data.type)
                    log.debugf("UV count: %v", attrib.data.count)
                    uv_ptr := get_accessor_ptr(attrib.data, hlsl.float2)
                    uv_bytes := attrib.data.count * size_of(hlsl.float2)
    
                    mem.copy(&uv_data[0], uv_ptr, int(uv_bytes))
                }
            }
        }
    
        // Now that we have the mesh data in CPU-side buffers,
        // it's time to upload them
        mesh_handle := create_mesh(gd, render_data, position_data[:], index_data[:])
        if len(color_data) > 0 do add_vertex_colors(gd, render_data, mesh_handle, color_data[:])
        if len(uv_data) > 0 do add_vertex_uvs(gd, render_data, mesh_handle, uv_data[:])


        // Now get material data
        loaded_glb_materials := make([dynamic]Material_Handle, len(gltf_data.materials), context.temp_allocator)
        defer delete(loaded_glb_materials)
        glb_material := primitive.material

        bindless_image_idx := vkw.Image_Handle {
            index = NULL_OFFSET
        }
        if glb_material.pbr_metallic_roughness.base_color_texture.texture != nil {
            tex := glb_material.pbr_metallic_roughness.base_color_texture.texture
            color_tex_idx := u32(uintptr(tex) - uintptr(&gltf_data.textures[0]))
            log.debugf("Texture index is %v", color_tex_idx)
            bindless_image_idx = loaded_glb_images[color_tex_idx]
        }
        
        material := MaterialData {
            color_texture = bindless_image_idx.index,
            sampler_idx = u32(vkw.Immutable_Sampler_Index.Aniso16),
            base_color = hlsl.float4(glb_material.pbr_metallic_roughness.base_color_factor)
        }
        material_handle := add_material(render_data, &material)

        draw_primitives[i] = DrawPrimitive {
            mesh = mesh_handle,
            material = material_handle
        }
    }

    return GltfData {
        primitives = draw_primitives
    }
}