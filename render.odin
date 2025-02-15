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

MAX_GLOBAL_DRAW_CMDS :: 4 * 1024
MAX_GLOBAL_VERTICES :: 4*1024*1024
MAX_GLOBAL_INDICES :: 1024*1024
MAX_GLOBAL_MESHES :: 64 * 1024
MAX_GLOBAL_JOINTS :: 64 * 1024
MAX_GLOBAL_ANIMATIONS :: 64 * 1024
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
    face_normal_ptr: vk.DeviceAddress,
    uv_ptr: vk.DeviceAddress,
    color_ptr: vk.DeviceAddress,
    joint_id_ptr: vk.DeviceAddress,
    joint_weight_ptr: vk.DeviceAddress,
    inv_bind_ptr: vk.DeviceAddress,
    time: f32,
    distortion_strength: f32,
    _pad0: hlsl.float2,
}

Ps1PushConstants :: struct {
    uniform_buffer_ptr: vk.DeviceAddress,
    sampler_idx: u32,
}

PostFxPushConstants :: struct {
    color_target: u32,
    sampler_idx: u32,
    uniforms_address: vk.DeviceAddress,
}

CPUStaticMeshData :: struct {
    indices_start: u32,
    indices_len: u32,
    gpu_data: GPUStaticMeshData,
}

CPUSkinnedMeshData :: struct {
    indices_start: u32,
    indices_len: u32,
    animations: [dynamic]Animation,
    gpu_data: GPUSkinnedMeshData,
}

GPUStaticMeshData :: struct {
    position_offset: u32,
    face_normals_offset: u32,
    uv_offset: u32,
    color_offset: u32,
}

GPUSkinnedMeshData :: struct {
    static_data: GPUStaticMeshData,
    joint_ids_offset: u32,
    joint_weights_offset: u32,
    inv_bind_matrices_offset: u32,
    //_pad0: hlsl.uint2,
}

AnimationInterpolation :: enum {
    Step,
    Linear,
    CubicSpline,
}
AnimationKeyFrame :: struct {
    time: f32,
    value: hlsl.float3,
}
AnimationChannel :: struct {
    keyframes: [dynamic]AnimationKeyFrame,
    type: AnimationInterpolation,
}
Animation :: struct {
    translation_channel: AnimationChannel,
    rotation_channel: AnimationChannel,
    scale_channel: AnimationChannel,
    name: string,
}

MaterialData :: struct {
    color_texture: u32,
    normal_texture: u32,
    arm_texture: u32,           // "arm" as in ambient roughness metalness, packed in RGB in that order    
    sampler_idx: u32,
    base_color: hlsl.float4,
}

DrawData :: struct {
    world_from_model: hlsl.float4x4,
}

StaticInstanceData :: struct {
    world_from_model: hlsl.float4x4,
    mesh_handle: Static_Mesh_Handle,
    material_handle: Material_Handle,
}

GPUInstanceData :: struct {
    world_from_model: hlsl.float4x4,
    normal_matrix: hlsl.float4x4, // cofactor matrix of above
    mesh_idx: u32,
    material_idx: u32,
    _pad0: hlsl.uint2,
    _pad3: hlsl.float4x3,
}

GPUBufferDirtyFlags :: bit_set[enum{
    Mesh,
    Material,
    Instance,
    Draw,
}]

Static_Mesh_Handle :: distinct hm.Handle
Skinned_Mesh_Handle :: distinct hm.Handle
Material_Handle :: distinct hm.Handle

Renderer :: struct {
    positions_buffer: vkw.Buffer_Handle,        // Global GPU buffer of vertex positions
    positions_head: u32,

    index_buffer: vkw.Buffer_Handle,            // Global GPU buffer of draw indices
    indices_head: u32,
    
    
    uvs_buffer: vkw.Buffer_Handle,              // Global GPU buffer of vertex uvs
    uvs_head: u32,

    colors_buffer: vkw.Buffer_Handle,              // Global GPU buffer of vertex colors
    colors_head: u32,

    joint_ids_buffer: vkw.Buffer_Handle,
    joint_ids_head: u32,

    joint_weights_buffer: vkw.Buffer_Handle,
    joint_weights_head: u32,

    triangle_normals_buffer: vkw.Buffer_Handle,
    triangle_normals_head: u32,

    // Global GPU buffer of mesh metadata
    // i.e. offsets into the vertex attribute buffers
    static_mesh_buffer: vkw.Buffer_Handle,
    cpu_static_meshes: hm.Handle_Map(CPUStaticMeshData),
    gpu_static_meshes: [dynamic]GPUStaticMeshData,

    // Separate global mesh buffer for skinned meshes
    skinned_mesh_buffer: vkw.Buffer_Handle,
    cpu_skinned_meshes: hm.Handle_Map(CPUSkinnedMeshData),
    gpu_skinned_meshes: [dynamic]GPUSkinnedMeshData,

    // Animation data
    inverse_bind_matrices_buffer: vkw.Buffer_Handle,
    inverse_bind_matrices_head: u32,


    material_buffer: vkw.Buffer_Handle,             // Global GPU buffer of materials
    cpu_materials: hm.Handle_Map(MaterialData),
    
    cpu_instances: [dynamic]StaticInstanceData,
    gpu_instances: [dynamic]GPUInstanceData,
    instance_buffer: vkw.Buffer_Handle,             // Global GPU buffer of instances

    cpu_uniforms: UniformBufferData,
    uniform_buffer: vkw.Buffer_Handle,              // Global uniform buffer

    dirty_flags: GPUBufferDirtyFlags,               // Represents which CPU/GPU buffers need synced this cycle

    // Pipeline buckets
    ps1_pipeline: vkw.Pipeline_Handle,

    postfx_pipeline: vkw.Pipeline_Handle,

    draw_buffer: vkw.Buffer_Handle,             // Global GPU buffer of indirect draw args

    // Sync primitives
    gfx_timeline: vkw.Semaphore_Handle,
    gfx_sync_info: vkw.Sync_Info,

    // Main render target
    main_framebuffer: vkw.Framebuffer,

    // Main viewport dimensions
    // Updated every frame with respect to the ImGUI dockspace's central node
    viewport_dimensions: [4]f32,
}

init_renderer :: proc(gd: ^vkw.Graphics_Device, screen_size: hlsl.uint2) -> Renderer {
    render_state: Renderer

    main_color_attachment_formats : []vk.Format = {vk.Format.R8G8B8A8_UNORM}
    main_depth_attachment_format := vk.Format.D32_SFLOAT

    swapchain_format := vk.Format.B8G8R8A8_SRGB

    // Create main timeline semaphore
    {
        info := vkw.Semaphore_Info {
            type = .TIMELINE,
            init_value = 0,
            name = "GFX Timeline",
        }
        render_state.gfx_timeline = vkw.create_semaphore(gd, &info)
    }

    // Create index buffer
    {
        info := vkw.Buffer_Info {
            size = size_of(u16) * MAX_GLOBAL_INDICES,
            usage = {.INDEX_BUFFER, .TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL},
            name = "Global index buffer",
        }
        render_state.index_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.index_buffer", f32(info.size) / 1024 / 1024)
    }

    // Create device-local storage buffers
    {
        info := vkw.Buffer_Info {
            usage = {.STORAGE_BUFFER,.TRANSFER_DST},
            alloc_flags = nil,
            required_flags = {.DEVICE_LOCAL},
        }

        info.name = "Global vertex positions buffer"
        info.size = size_of(hlsl.float4) * MAX_GLOBAL_VERTICES
        render_state.positions_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.positions_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global vertex UVs buffer"
        info.size = size_of(hlsl.float2) * MAX_GLOBAL_VERTICES
        render_state.uvs_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.uvs_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global vertex colors buffer"
        info.size = size_of(hlsl.float4) * MAX_GLOBAL_VERTICES
        render_state.colors_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.colors_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global joint ids buffer"
        info.size = size_of(hlsl.float4) * MAX_GLOBAL_VERTICES
        render_state.colors_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.joint_ids_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global joint weights buffer"
        info.size = size_of(hlsl.float4) * MAX_GLOBAL_VERTICES
        render_state.colors_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.joint_weights_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global triangle normals buffer"
        info.size = size_of(hlsl.float4) * MAX_GLOBAL_INDICES
        render_state.triangle_normals_buffer = vkw.create_buffer(gd, &info)

        info.name = "Global static mesh data buffer"
        info.size = size_of(GPUStaticMeshData) * MAX_GLOBAL_MESHES
        render_state.static_mesh_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.static_mesh_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global skinned mesh data buffer"
        info.size = size_of(GPUSkinnedMeshData) * MAX_GLOBAL_MESHES
        render_state.skinned_mesh_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.skinned_mesh_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global skinned mesh data buffer"
        info.size = size_of(hlsl.float4x4) * MAX_GLOBAL_JOINTS
        render_state.inverse_bind_matrices_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.inverse_bind_matrices_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global material buffer"
        info.size = size_of(MaterialData) * MAX_GLOBAL_MATERIALS
        render_state.material_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.material_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global instance buffer"
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
            required_flags = {.DEVICE_LOCAL,.HOST_VISIBLE,.HOST_COHERENT},
            name = "Indirect draw buffer"
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
            required_flags = {.DEVICE_LOCAL,.HOST_VISIBLE,.HOST_COHERENT},
            name = "Global uniforms buffer"
        }
        render_state.uniform_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.uniform", f32(info.size) / 1024 / 1024)
    }

    // Initialize the buffer pointers in the uniforms struct
    {
        mesh_buffer, _ := vkw.get_buffer(gd, render_state.static_mesh_buffer)
        material_buffer, _ := vkw.get_buffer(gd, render_state.material_buffer)
        instance_buffer, _ := vkw.get_buffer(gd, render_state.instance_buffer)
        position_buffer, _ := vkw.get_buffer(gd, render_state.positions_buffer)
        face_normals_buffer, _ := vkw.get_buffer(gd, render_state.triangle_normals_buffer)
        uv_buffer, _ := vkw.get_buffer(gd, render_state.uvs_buffer)
        color_buffer, _ := vkw.get_buffer(gd, render_state.colors_buffer)
        joint_ids_buffer, _ := vkw.get_buffer(gd, render_state.joint_ids_buffer)
        joint_weights_buffer, _ := vkw.get_buffer(gd, render_state.joint_weights_buffer)
        inv_bind_buffer, _ := vkw.get_buffer(gd, render_state.inverse_bind_matrices_buffer)
    
        render_state.cpu_uniforms.mesh_ptr = mesh_buffer.address
        render_state.cpu_uniforms.material_ptr = material_buffer.address
        render_state.cpu_uniforms.instance_ptr = instance_buffer.address
        render_state.cpu_uniforms.position_ptr = position_buffer.address
        render_state.cpu_uniforms.face_normal_ptr = face_normals_buffer.address
        render_state.cpu_uniforms.uv_ptr = uv_buffer.address
        render_state.cpu_uniforms.color_ptr = color_buffer.address
        render_state.cpu_uniforms.joint_id_ptr = joint_ids_buffer.address
        render_state.cpu_uniforms.joint_weight_ptr = joint_weights_buffer.address
        render_state.cpu_uniforms.inv_bind_ptr = inv_bind_buffer.address
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
                depth = 1,
            },
            supports_mipmaps = false,
            array_layers = 1,
            samples = {._1},
            tiling = .OPTIMAL,
            usage = {.SAMPLED,.COLOR_ATTACHMENT},
            alloc_flags = nil,
            name = "Main color target",
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
            name = "Main depth target",
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
            depth_load_op = .CLEAR,
        }
    }

    // Pipeline creation
    {
        // Load shader bytecode
        // This will be embedded into the executable at compile-time
        ps1_vert_spv := #load("data/shaders/ps1.vert.spv", []u32)
        ps1_frag_spv := #load("data/shaders/ps1.frag.spv", []u32)

        raster_state := vkw.default_rasterization_state()

        pipeline_infos := make([dynamic]vkw.Graphics_Pipeline_Info, context.temp_allocator)

        // PS1 pipeline
        append(&pipeline_infos, vkw.Graphics_Pipeline_Info {
            vertex_shader_bytecode = ps1_vert_spv,
            fragment_shader_bytecode = ps1_frag_spv,
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
                do_depth_test = true,
                do_depth_write = true,
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
                color_attachment_formats = main_color_attachment_formats,
                depth_attachment_format = main_depth_attachment_format,
            },
        })

        // Postprocessing pass info

        postfx_vert_spv := #load("data/shaders/postprocessing.vert.spv", []u32)
        postfx_frag_spv := #load("data/shaders/postprocessing.frag.spv", []u32)

        append(&pipeline_infos, vkw.Graphics_Pipeline_Info {
            vertex_shader_bytecode = postfx_vert_spv,
            fragment_shader_bytecode = postfx_frag_spv,
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
                color_attachment_formats = {swapchain_format},
                depth_attachment_format = nil,
            }
        })

        handles := vkw.create_graphics_pipelines(gd, pipeline_infos[:])
        defer delete(handles)

        render_state.ps1_pipeline = handles[0]
        render_state.postfx_pipeline = handles[1]
    }

    return render_state
}

delete_renderer :: proc(gd: ^vkw.Graphics_Device, using r: ^Renderer) {
    vkw.delete_sync_info(&gfx_sync_info)
    vkw.delete_buffer(gd, positions_buffer)
    vkw.delete_buffer(gd, index_buffer)
    vkw.delete_buffer(gd, uvs_buffer)
    vkw.delete_buffer(gd, colors_buffer)
    vkw.delete_buffer(gd, static_mesh_buffer)
    vkw.delete_buffer(gd, material_buffer)
    vkw.delete_buffer(gd, instance_buffer)
    vkw.delete_buffer(gd, uniform_buffer)

    delete(cpu_instances)
    delete(gpu_instances)

    hm.destroy(&cpu_materials)
    hm.destroy(&cpu_static_meshes)
    delete(gpu_static_meshes)    
}

resize_framebuffers :: proc(gd: ^vkw.Graphics_Device, using r: ^Renderer, screen_size: hlsl.uint2) {
    vkw.delete_image(gd, main_framebuffer.color_images[0])
    vkw.delete_image(gd, main_framebuffer.depth_image)
    
    old_clearcolor := main_framebuffer.clear_color

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
            clear_color = old_clearcolor,
            color_load_op = .CLEAR,
            depth_load_op = .CLEAR
        }
    }
}

swapchain_framebuffer :: proc(gd: ^vkw.Graphics_Device, swapchain_idx: u32, resolution: [2]u32) -> vkw.Framebuffer {
    fb: vkw.Framebuffer
    fb.color_images[0] = gd.swapchain_images[swapchain_idx]
    fb.depth_image = {generation = NULL_OFFSET, index = NULL_OFFSET}
    fb.resolution.x = resolution.x
    fb.resolution.y = resolution.y
    fb.color_load_op = .CLEAR

    return fb
}

create_static_mesh :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^Renderer,
    positions: []hlsl.float4,
    indices: []u16
) -> Static_Mesh_Handle {
    
    position_start: u32
    {
        positions_len := u32(len(positions))
        assert(positions_head + positions_len < MAX_GLOBAL_VERTICES)
        assert(positions_len > 0)
    
        position_start = positions_head
        positions_head += positions_len
    
        vkw.sync_write_buffer(gd, positions_buffer, positions, position_start)
    }

    indices_start: u32
    indices_len: u32
    {
        indices_len = u32(len(indices))
        assert(indices_head + indices_len < MAX_GLOBAL_INDICES)
        assert(indices_len > 0)

        indices_start = indices_head
        indices_head += indices_len

        vkw.sync_write_buffer(gd, index_buffer, indices, indices_start)
    }

    mesh := CPUStaticMeshData {
        indices_start = indices_start,
        indices_len = indices_len,
    }
    handle := Static_Mesh_Handle(hm.insert(&cpu_static_meshes, mesh))

    gpu_mesh := GPUStaticMeshData {
        position_offset = position_start,
        uv_offset = NULL_OFFSET,
        color_offset = NULL_OFFSET
    }
    append(&gpu_static_meshes, gpu_mesh)

    dirty_flags += {.Mesh}

    return handle
}

create_skinned_mesh :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^Renderer,
    positions: []hlsl.float4,
    indices: []u16,
    joint_ids: []hlsl.uint4,
    joint_weights: []hlsl.float4,
    inv_bind_matrices: []hlsl.float4x4,
) -> Skinned_Mesh_Handle {
    
    position_start: u32
    {
        positions_len := u32(len(positions))
        assert(positions_head + positions_len < MAX_GLOBAL_VERTICES)
        assert(positions_len > 0)
    
        position_start = positions_head
        positions_head += positions_len
    
        vkw.sync_write_buffer(gd, positions_buffer, positions, position_start)
    }

    indices_start: u32
    indices_len: u32
    {
        indices_len = u32(len(indices))
        assert(indices_head + indices_len < MAX_GLOBAL_INDICES)
        assert(indices_len > 0)

        indices_start = indices_head
        indices_head += indices_len

        vkw.sync_write_buffer(gd, index_buffer, indices, indices_start)
    }

    inv_bind_start: u32
    {
        inv_bind_len := u32(len(inv_bind_matrices))

        inv_bind_start = inverse_bind_matrices_head
        inverse_bind_matrices_head += inv_bind_len

        vkw.sync_write_buffer(gd, inverse_bind_matrices_buffer, inv_bind_matrices, inv_bind_start)
    }

    joint_ids_start: u32
    {
        joint_ids_len := u32(len(joint_ids))

        joint_ids_start = joint_ids_head
        joint_ids_head += joint_ids_len

        vkw.sync_write_buffer(gd, joint_ids_buffer, joint_ids, joint_ids_start)
    }

    joint_weights_start: u32
    {
        joint_weights_len := u32(len(joint_weights))

        joint_weights_start = joint_weights_head
        joint_weights_head += joint_weights_len

        vkw.sync_write_buffer(gd, joint_weights_buffer, joint_weights, joint_weights_start)
    }

    mesh := CPUSkinnedMeshData {
        indices_start = indices_start,
        indices_len = indices_len,
    }
    handle := Skinned_Mesh_Handle(hm.insert(&cpu_skinned_meshes, mesh))

    gpu_mesh := GPUSkinnedMeshData {
        static_data = {
            position_offset = position_start,
            uv_offset = NULL_OFFSET,
            color_offset = NULL_OFFSET
        }
    }
    append(&gpu_skinned_meshes, gpu_mesh)

    dirty_flags += {.Mesh}

    return handle
}

add_face_normals :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^Renderer,
    handle: $HandleType,
    normals: []hlsl.float4
) -> bool {
    normals_start := triangle_normals_head
    normals_len := u32(len(normals))

    triangle_normals_head += normals_len

    when HandleType == Static_Mesh_Handle {
        gpu_mesh := &gpu_static_meshes[handle.index]
        gpu_mesh.face_normals_offset = normals_start
    } else when HandleType == Skinned_Mesh_Handle {
        gpu_mesh := &gpu_skinned_meshes[handle.index]
        gpu_mesh.static_data.face_normals_offset = normals_start
    } else {
        panic("Invalid arg type")
    }

    return vkw.sync_write_buffer(gd, triangle_normals_buffer, normals, normals_start)
}

add_vertex_colors :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^Renderer,
    handle: $HandleType,
    colors: []hlsl.float4
) -> bool {
    color_start := colors_head
    colors_len := u32(len(colors))
    assert(colors_len > 0)
    assert(colors_head + colors_len < MAX_GLOBAL_VERTICES)

    colors_head += colors_len

    when HandleType == Static_Mesh_Handle {
        gpu_mesh := &gpu_static_meshes[handle.index]
        gpu_mesh.color_offset = color_start
    } else when HandleType == Skinned_Mesh_Handle {
        gpu_mesh := &gpu_skinned_meshes[handle.index]
        gpu_mesh.static_data.color_offset = color_start
    } else {
        panic("Invalid arg type")
    }

    return vkw.sync_write_buffer(gd, colors_buffer, colors, color_start)
}

add_vertex_uvs :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^Renderer,
    handle: $HandleType,
    uvs: []hlsl.float2
) -> bool {
    uv_start := uvs_head
    uvs_len := u32(len(uvs))
    assert(uvs_len > 0)
    assert(uvs_head + uvs_len < MAX_GLOBAL_VERTICES)

    uvs_head += uvs_len

    when HandleType == Static_Mesh_Handle {
        gpu_mesh := &gpu_static_meshes[handle.index]
        gpu_mesh.uv_offset = uv_start
    } else when HandleType == Skinned_Mesh_Handle {
        gpu_mesh := &gpu_skinned_meshes[handle.index]
        gpu_mesh.static_data.uv_offset = uv_start
    } else {
        panic("Invalid arg type")
    }

    return vkw.sync_write_buffer(gd, uvs_buffer, uvs, uv_start)
}

add_material :: proc(using r: ^Renderer, new_mat: ^MaterialData) -> Material_Handle {
    dirty_flags += {.Material}
    return Material_Handle(hm.insert(&cpu_materials, new_mat^))
}

draw_ps1_mesh :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^Renderer,
    data: ^StaticModelData,
    draw_data: ^DrawData
) {
    for prim in data.primitives {
        draw_ps1_primitive(gd, r, prim.mesh, prim.material, draw_data)
    }
}

// User code calls this to queue up draw calls
draw_ps1_primitive :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^Renderer,
    mesh_handle: Static_Mesh_Handle,
    material_handle: Material_Handle,
    draw_data: ^DrawData
) -> bool {
    dirty_flags += {.Instance,.Draw}

    // Append instance representing this primitive
    new_inst := StaticInstanceData {
        world_from_model = draw_data.world_from_model,
        mesh_handle = mesh_handle,
        material_handle = material_handle
    }
    append(&cpu_instances, new_inst)

    return true
}

// This is called once per frame to sync buffers with the GPU
// and record the relevant commands into the frame's command buffer
render :: proc(
    gd: ^vkw.Graphics_Device,
    gfx_cb_idx: vkw.CommandBuffer_Index,
    using r: ^Renderer,
    viewport_camera: ^Camera,
    framebuffer: ^vkw.Framebuffer,
) {
    // Sync CPU and GPU buffers

    // Mesh buffer
    if .Mesh in dirty_flags {
        vkw.sync_write_buffer(gd, static_mesh_buffer, gpu_static_meshes[:])
    }

    // Material buffer
    if .Material in dirty_flags {
        vkw.sync_write_buffer(gd, material_buffer, cpu_materials.values[:])
    }

    // Draw and Instance buffers
    ps1_draw_count : u32 = 0
    if .Draw in dirty_flags || .Instance in dirty_flags {
        gpu_draws := make([dynamic]vk.DrawIndexedIndirectCommand, 0, len(cpu_instances), context.temp_allocator)
        defer delete(gpu_draws)

        
        // Sort instances by mesh handle
        slice.sort_by(cpu_instances[:], proc(i, j: StaticInstanceData) -> bool {
            return i.mesh_handle.index < j.mesh_handle.index
        })

        // With the understanding that these instances are already sorted by
        // mesh_idx, construct the draw stream with appropriate instancing
        current_inst_count := 0
        inst_offset := 0
        current_mesh_handle: Static_Mesh_Handle
        for inst in cpu_instances {
            g_inst := GPUInstanceData {
                world_from_model = inst.world_from_model,
                normal_matrix = hlsl.cofactor(inst.world_from_model),
                mesh_idx = inst.mesh_handle.index,
                material_idx = inst.material_handle.index
            }
            append(&gpu_instances, g_inst)

            if current_inst_count == 0 {
                // First iteration case

                current_mesh_handle = inst.mesh_handle
                current_inst_count += 1
            } else {
                if current_mesh_handle != inst.mesh_handle {
                    // First instance of next mesh handle case

                    mesh_data, ok := hm.get(&cpu_static_meshes, hm.Handle(current_mesh_handle))
                    if !ok {
                        log.error("Couldn't get CPU mesh during draw command building")
                    }

                    draw_call := vk.DrawIndexedIndirectCommand {
                        indexCount = mesh_data.indices_len,
                        instanceCount = u32(current_inst_count),
                        firstIndex = mesh_data.indices_start,
                        vertexOffset = 0,
                        firstInstance = u32(inst_offset)
                    }
                    append(&gpu_draws, draw_call)
                    inst_offset += current_inst_count
                    ps1_draw_count += 1

                    current_inst_count = 1
                    current_mesh_handle = inst.mesh_handle
                } else {
                    // Another instance of current mesh case
                    current_inst_count += 1
                }
            }
        }

        // Final draw call
        mesh_data, ok := hm.get(&cpu_static_meshes, hm.Handle(current_mesh_handle))
        if !ok {
            log.error("Couldn't get CPU mesh during draw command building")
        }

        draw_call := vk.DrawIndexedIndirectCommand {
            indexCount = mesh_data.indices_len,
            instanceCount = u32(current_inst_count),
            firstIndex = mesh_data.indices_start,
            vertexOffset = 0,
            firstInstance = u32(inst_offset)
        }
        append(&gpu_draws, draw_call)
        inst_offset += current_inst_count
        ps1_draw_count += 1

        vkw.sync_write_buffer(gd, instance_buffer, gpu_instances[:])
        vkw.sync_write_buffer(gd, draw_buffer, gpu_draws[:])
    }

    // Update uniforms buffer
    {
        in_slice := slice.from_ptr(&cpu_uniforms, 1)
        if !vkw.sync_write_buffer(gd, uniform_buffer, in_slice) {
            log.error("Failed to write uniform buffer data")
        }
    }

    // Clear dirty flags after checking them
    dirty_flags = {}
    
    // Bind global index buffer and descriptor set
    vkw.cmd_bind_index_buffer(gd, gfx_cb_idx, index_buffer)
    vkw.cmd_bind_descriptor_set(gd, gfx_cb_idx)

    // PS1 simple unlit pipeline
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

    // Begin renderpass into main internal rendertarget
    vkw.cmd_begin_render_pass(gd, gfx_cb_idx, &main_framebuffer)

    res := main_framebuffer.resolution
    vkw.cmd_set_viewport(gd, gfx_cb_idx, 0, {vkw.Viewport {
        x = viewport_dimensions[0],
        y = viewport_dimensions[1],
        width = viewport_dimensions[2],
        height = viewport_dimensions[3],
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
    vkw.cmd_push_constants_gfx(Ps1PushConstants, gd, gfx_cb_idx, &Ps1PushConstants {
        uniform_buffer_ptr = uniform_buf.address,
        sampler_idx = u32(vkw.Immutable_Sampler_Index.Point)
    })

    // There will be one vkCmdDrawIndexedIndirect() per distinct "ubershader" pipeline
    vkw.cmd_draw_indexed_indirect(gd, gfx_cb_idx, draw_buffer, 0, ps1_draw_count)

    vkw.cmd_end_render_pass(gd, gfx_cb_idx)
    
    // Reset per-frame state vars
    clear(&cpu_instances)
    clear(&gpu_instances)

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

    vkw.cmd_set_viewport(gd, gfx_cb_idx, 0, {vkw.Viewport {
        x = 0.0,
        y = 0.0,
        width = f32(res.x),
        height = f32(res.y),
        minDepth = 0.0,
        maxDepth = 1.0
    }})
    
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




StaticDrawPrimitive :: struct {
    mesh: Static_Mesh_Handle,
    material: Material_Handle,
}

StaticModelData :: struct {
    primitives: [dynamic]StaticDrawPrimitive
}

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

gltf_delete :: proc(using d: ^StaticModelData)  {
    delete(primitives)
}

load_gltf_static_model :: proc(
    gd: ^vkw.Graphics_Device,
    render_data: ^Renderer,
    path: cstring,
    allocator := context.allocator
) -> StaticModelData {
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
        raw_image_ptr := stbi.load_from_memory(data_ptr, i32(glb_image.buffer_view.size), &width, &height, nil, channels)

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
        loaded_glb_images[i] = handle
    }

    // @TODO: Don't just load the first mesh you see
    mesh := gltf_data.meshes[0]

    draw_primitives := make([dynamic]StaticDrawPrimitive, len(mesh.primitives), allocator)

    for primitive, i in mesh.primitives {
        // Get indices
        index_data: [dynamic]u16
        defer delete(index_data)
        indices_count := primitive.indices.count
        indices_bytes := indices_count * size_of(u16)
        resize(&index_data, indices_count)
        index_ptr := get_accessor_ptr(primitive.indices, u16)
        mem.copy(raw_data(index_data), index_ptr, int(indices_bytes))
    
        // Get vertex data
        position_data: [dynamic]hlsl.float4
        defer delete(position_data)
        color_data: [dynamic]hlsl.float4
        defer delete(color_data)
        uv_data: [dynamic]hlsl.float2
        defer delete(uv_data)
        joint_ids: [dynamic]hlsl.uint4
        defer delete(joint_ids)
        joint_weights: [dynamic]hlsl.float4
        defer delete(joint_weights)
    
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

        // Compute triangle face normals
        face_normals := make([dynamic]hlsl.float4, indices_count / 3, context.temp_allocator)
        defer delete(face_normals)
        for j := 0; j < len(index_data); j += 3 {
            i0 := index_data[j]
            i1 := index_data[j + 1]
            i2 := index_data[j + 2]

            a : hlsl.float3 = position_data[i0].xyz
            b : hlsl.float3 = position_data[i1].xyz
            c : hlsl.float3 = position_data[i2].xyz
            n := hlsl.normalize(hlsl.cross(b - a, c - a))

            out_idx := j / 3
            face_normals[out_idx] = {n.x, n.y, n.z, 0.0}
        }
    
        // Now that we have the mesh data in CPU-side buffers,
        // it's time to upload them
        mesh_handle := create_static_mesh(gd, render_data, position_data[:], index_data[:])
        add_face_normals(gd, render_data, mesh_handle, face_normals[:])
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
            color_tex_idx := u32(uintptr(tex) - uintptr(&gltf_data.textures[0])) / size_of(cgltf.texture)
            log.debugf("Texture index is %v", color_tex_idx)
            bindless_image_idx = loaded_glb_images[color_tex_idx]
        }
        
        material := MaterialData {
            color_texture = bindless_image_idx.index,
            sampler_idx = u32(vkw.Immutable_Sampler_Index.Aniso16),
            base_color = hlsl.float4(glb_material.pbr_metallic_roughness.base_color_factor)
        }
        material_handle := add_material(render_data, &material)

        draw_primitives[i] = StaticDrawPrimitive {
            mesh = mesh_handle,
            material = material_handle
        }
    }

    return StaticModelData {
        primitives = draw_primitives
    }
}

SkinnedDrawPrimitive :: struct {
    mesh: Skinned_Mesh_Handle,
    material: Material_Handle
}

SkinnedModelData :: struct {
    primitives: [dynamic]SkinnedDrawPrimitive,
    animations: [dynamic]Animation,
}

load_gltf_skinned_model :: proc(
    gd: ^vkw.Graphics_Device,
    render_data: ^Renderer,
    path: cstring,
    allocator := context.allocator
) -> SkinnedModelData {
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
        raw_image_ptr := stbi.load_from_memory(data_ptr, i32(glb_image.buffer_view.size), &width, &height, nil, channels)

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
        loaded_glb_images[i] = handle
    }

    // @TODO: Don't just load the first mesh you see
    mesh := gltf_data.meshes[0]

    // Load inverse bind matrices
    inv_bind_matrices: [dynamic]hlsl.float4x4
    defer delete(inv_bind_matrices)
    animations: [dynamic]Animation
    {
        assert(len(gltf_data.skins) == 1)

        glb_skin := gltf_data.skins[0]
        
        // Load inverse bind matrices
        inv_bind_count := glb_skin.inverse_bind_matrices.count
        resize(&inv_bind_matrices, inv_bind_count)
        inv_bind_ptr := get_accessor_ptr(glb_skin.inverse_bind_matrices, hlsl.float4x4)
        mem.copy(&inv_bind_matrices[0], inv_bind_ptr, int(inv_bind_count))

        // Load joint data
        for joint in glb_skin.joints {
            log.infof("%v", joint.children)
        }

        // Load animation data
        animations = make([dynamic]Animation, len(mesh.primitives), allocator)
        for animation in gltf_data.animations {
            new_anim: Animation

            log.infof("Loading animation \"%v\"", animation.name)

            // Load animation channels
            for channel in animation.channels {
                out_channel: ^AnimationChannel
                #partial switch channel.target_path {
                    case .translation: out_channel = &new_anim.translation_channel
                    case .rotation: out_channel = &new_anim.rotation_channel
                    case .scale: out_channel = &new_anim.scale_channel
                    case: log.errorf("Unsupported animation target: %v", channel.target_path)
                }

                if channel.sampler.interpolation == .cubic_spline {
                    log.errorf("Unsupported animation interpolation: %v", channel.sampler.interpolation)
                }
                switch channel.sampler.interpolation {
                    case .step: out_channel.type = .Step
                    case .linear: out_channel.type = .Linear
                    case .cubic_spline: out_channel.type = .CubicSpline
                }

                keyframe_count := channel.sampler.input.count
                reserve(&out_channel.keyframes, keyframe_count)
                keyframe_times := get_accessor_ptr(channel.sampler.input, f32)
                keyframe_values := get_accessor_ptr(channel.sampler.output, hlsl.float3)
                for i in 0..<keyframe_count {
                    append(&out_channel.keyframes, AnimationKeyFrame {
                        time = keyframe_times[i],
                        value = keyframe_values[i],
                    })
                }
                
            }

            append(&animations, new_anim)
        }
    }

    draw_primitives := make([dynamic]SkinnedDrawPrimitive, len(mesh.primitives), allocator)

    for primitive, i in mesh.primitives {
        // Get indices
        index_data: [dynamic]u16
        defer delete(index_data)
        indices_count := primitive.indices.count
        indices_bytes := indices_count * size_of(u16)
        resize(&index_data, indices_count)
        index_ptr := get_accessor_ptr(primitive.indices, u16)
        mem.copy(raw_data(index_data), index_ptr, int(indices_bytes))
    
        // Get vertex data
        position_data: [dynamic]hlsl.float4
        defer delete(position_data)
        color_data: [dynamic]hlsl.float4
        defer delete(color_data)
        uv_data: [dynamic]hlsl.float2
        defer delete(uv_data)
        joint_ids: [dynamic]hlsl.uint4
        defer delete(joint_ids)
        joint_weights: [dynamic]hlsl.float4
        defer delete(joint_weights)
    
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
                }
                case .texcoord: {
                    resize(&uv_data, attrib.data.count)
                    log.debugf("UV data type: %v", attrib.data.type)
                    log.debugf("UV count: %v", attrib.data.count)
                    uv_ptr := get_accessor_ptr(attrib.data, hlsl.float2)
                    uv_bytes := attrib.data.count * size_of(hlsl.float2)
    
                    mem.copy(&uv_data[0], uv_ptr, int(uv_bytes))
                }
                case .joints: {
                    resize(&joint_ids, attrib.data.count)
                    joints_ptr := get_accessor_ptr(attrib.data, hlsl.uint4)
                    joints_bytes := attrib.data.count * size_of(hlsl.uint4)

                    mem.copy(&joint_ids[0], joints_ptr, int(joints_bytes))
                }
                case .weights: {
                    resize(&joint_weights, attrib.data.count)
                    weights_ptr := get_accessor_ptr(attrib.data, hlsl.float4)
                    weights_bytes := attrib.data.count * size_of(hlsl.float4)

                    mem.copy(&joint_weights[0], weights_ptr, int(weights_bytes))
                }
            }
        }

        // Compute triangle face normals
        face_normals := make([dynamic]hlsl.float4, indices_count / 3, context.temp_allocator)
        defer delete(face_normals)
        for j := 0; j < len(index_data); j += 3 {
            i0 := index_data[j]
            i1 := index_data[j + 1]
            i2 := index_data[j + 2]

            a : hlsl.float3 = position_data[i0].xyz
            b : hlsl.float3 = position_data[i1].xyz
            c : hlsl.float3 = position_data[i2].xyz
            n := hlsl.normalize(hlsl.cross(b - a, c - a))

            out_idx := j / 3
            face_normals[out_idx] = {n.x, n.y, n.z, 0.0}
        }
    
        // Now that we have the mesh data in CPU-side buffers,
        // it's time to upload them
        mesh_handle := create_skinned_mesh(
            gd,
            render_data,
            position_data[:],
            index_data[:],
            joint_ids[:],
            joint_weights[:],
            inv_bind_matrices[:]
        )
        add_face_normals(gd, render_data, mesh_handle, face_normals[:])
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
            color_tex_idx := u32(uintptr(tex) - uintptr(&gltf_data.textures[0])) / size_of(cgltf.texture)
            log.debugf("Texture index is %v", color_tex_idx)
            bindless_image_idx = loaded_glb_images[color_tex_idx]
        }
        
        material := MaterialData {
            color_texture = bindless_image_idx.index,
            sampler_idx = u32(vkw.Immutable_Sampler_Index.Aniso16),
            base_color = hlsl.float4(glb_material.pbr_metallic_roughness.base_color_factor)
        }
        material_handle := add_material(render_data, &material)

        draw_primitives[i] = SkinnedDrawPrimitive {
            mesh = mesh_handle,
            material = material_handle
        }
    }

    return SkinnedModelData {
        primitives = draw_primitives,
        animations = animations
    }
}