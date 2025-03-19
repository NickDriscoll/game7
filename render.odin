package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/linalg/hlsl"
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

// @TODO: Just make this zero somehow
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
    joint_id_ptr: vk.DeviceAddress,
    joint_weight_ptr: vk.DeviceAddress,
    joint_mats_ptr: vk.DeviceAddress,
    time: f32,
    distortion_strength: f32,
    triangle_vis: u32,
    _pad0: [3]f32,
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
}

GPUStaticMesh :: struct {
    position_offset: u32,
    uv_offset: u32,
    color_offset: u32,
    _pad0: u32,
}

AnimationInterpolation :: enum {
    Step,
    Linear,
    CubicSpline,
}
AnimationKeyFrame :: struct {
    time: f32,
    value: hlsl.float4,
}
AnimationAspect :: enum {
    Translation,
    Rotation,
    Scale
}
AnimationChannel :: struct {
    keyframes: [dynamic]AnimationKeyFrame,
    interpolation_type: AnimationInterpolation,
    aspect: AnimationAspect,
    local_joint_id: u32,
}
Animation :: struct {
    channels: [dynamic]AnimationChannel,
    name: string,
}
get_animation_endtime :: proc(anim: ^Animation) -> f32 {
    idx := len(anim.channels[0].keyframes) - 1
    return anim.channels[0].keyframes[idx].time
}

Material :: struct {
    color_texture: u32,
    normal_texture: u32,
    arm_texture: u32,           // "arm" as in ambient-roughness-metalness, packed in RGB in that order    
    sampler_idx: u32,
    base_color: hlsl.float4,
}

StaticDraw :: struct {
    world_from_model: hlsl.float4x4,
}

CPUStaticInstance :: struct {
    world_from_model: hlsl.float4x4,
    mesh_handle: Static_Mesh_Handle,
    material_handle: Material_Handle,
}

GPUStaticInstance :: struct {
    world_from_model: hlsl.float4x4,
    normal_matrix: hlsl.float4x4, // cofactor matrix of above
    mesh_idx: u32,
    material_idx: u32,
    _pad0: hlsl.uint2,
    _pad3: hlsl.float4x3,
}

SkinnedDraw :: struct {
    world_from_model: hlsl.float4x4,
    anim_idx: u32,
    anim_t: f32
}

CPUSkinnedInstance :: struct {
    world_from_model: hlsl.float4x4,
    mesh_handle: Skinned_Mesh_Handle,
    material_handle: Material_Handle,
    animation_time: f32,
    animation_idx: u32,
}

GPUSkinnedMesh :: struct {
    joint_ids_offset: u32,
    joint_weights_offset: u32,
    in_positions_offset: u32,
    out_positions_offset: u32,
}

CPUSkinnedMesh :: struct {
    vertices_len: u32,
    joint_count: u32,
    first_joint: u32,
    gpu_data: GPUSkinnedMesh,
    static_mesh_handle: Static_Mesh_Handle,
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
    index_buffer: vkw.Buffer_Handle,            // Global GPU buffer of draw indices
    indices_head: u32,
    
    // Global buffers for vertex attributes
    positions_buffer: vkw.Buffer_Handle,        // Global GPU buffer of vertex positions
    positions_head: u32,
    uvs_buffer: vkw.Buffer_Handle,              // Global GPU buffer of vertex uvs
    uvs_head: u32,
    colors_buffer: vkw.Buffer_Handle,              // Global GPU buffer of vertex colors
    colors_head: u32,
    joint_ids_buffer: vkw.Buffer_Handle,
    joint_ids_head: u32,
    joint_weights_buffer: vkw.Buffer_Handle,
    joint_weights_head: u32,

    // Global GPU buffer of mesh metadata
    // i.e. offsets into the vertex attribute buffers
    static_mesh_buffer: vkw.Buffer_Handle,
    cpu_static_meshes: hm.Handle_Map(CPUStaticMeshData),
    gpu_static_meshes: [dynamic]GPUStaticMesh,

    // Separate global mesh buffer for skinned meshes
    cpu_skinned_meshes: hm.Handle_Map(CPUSkinnedMesh),

    // Animation data
    joint_matrices_buffer: vkw.Buffer_Handle,       // Contains joints for each _instance_ of a skin
    joint_matrices_head: u32,
    joint_parents: [dynamic]u32,
    inverse_bind_matrices: [dynamic]hlsl.float4x4,  // 
    animations: [dynamic]Animation,
    skinning_pipeline: vkw.Pipeline_Handle,         // Skinning-in-compute pipeline

    material_buffer: vkw.Buffer_Handle,             // Global GPU buffer of materials
    cpu_materials: hm.Handle_Map(Material),
    
    cpu_static_instances: [dynamic]CPUStaticInstance,
    gpu_static_instances: [dynamic]GPUStaticInstance,
    cpu_skinned_instances: [dynamic]CPUSkinnedInstance,
    instance_buffer: vkw.Buffer_Handle,             // Global GPU buffer of instances

    // Per-frame shader uniforms
    cpu_uniforms: UniformBufferData,
    uniform_buffer: vkw.Buffer_Handle,

    dirty_flags: GPUBufferDirtyFlags,               // Represents which CPU/GPU buffers need synced this cycle

    // Pipeline buckets
    ps1_pipeline: vkw.Pipeline_Handle,
    postfx_pipeline: vkw.Pipeline_Handle,

    draw_buffer: vkw.Buffer_Handle,             // Global GPU buffer of indirect draw args

    // Maps of string filenames to ModelData types
    loaded_static_models: map[string]StaticModelData,
    loaded_skinned_models: map[string]SkinnedModelData,

    // Sync primitives
    gfx_timeline: vkw.Semaphore_Handle,
    compute_timeline: vkw.Semaphore_Handle,
    gfx_sync: vkw.Sync_Info,
    compute_sync: vkw.Sync_Info,

    // Main render target
    main_framebuffer: vkw.Framebuffer,

    // Main viewport dimensions
    // Updated every frame with respect to the ImGUI dockspace's central node
    // @TODO: Replace [4]f32 with vk.Rect2D
    viewport_dimensions: [4]f32,
}

init_renderer :: proc(gd: ^vkw.Graphics_Device, screen_size: hlsl.uint2) -> Renderer {
    renderer: Renderer

    // Allocator dynamic arrays and handlemaps
    hm.init(&renderer.cpu_static_meshes)
    hm.init(&renderer.cpu_skinned_meshes)
    hm.init(&renderer.cpu_materials)
    renderer.gpu_static_meshes = make([dynamic]GPUStaticMesh)
    renderer.joint_parents = make([dynamic]u32)
    renderer.inverse_bind_matrices = make([dynamic]hlsl.float4x4)
    renderer.animations = make([dynamic]Animation)

    vkw.sync_init(&renderer.gfx_sync)
    vkw.sync_init(&renderer.compute_sync)

    renderer.loaded_static_models = make(map[string]StaticModelData)
    renderer.loaded_skinned_models = make(map[string]SkinnedModelData)

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
        renderer.gfx_timeline = vkw.create_semaphore(gd, &info)
    }

    // Create compute timeline semaphore
    {
        info := vkw.Semaphore_Info {
            type = .TIMELINE,
            init_value = 0,
            name = "Compute Timeline",
        }
        renderer.compute_timeline = vkw.create_semaphore(gd, &info)
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
        renderer.index_buffer = vkw.create_buffer(gd, &info)
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
        renderer.positions_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.positions_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global vertex UVs buffer"
        info.size = size_of(hlsl.float2) * MAX_GLOBAL_VERTICES
        renderer.uvs_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.uvs_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global vertex colors buffer"
        info.size = size_of(hlsl.float4) * MAX_GLOBAL_VERTICES
        renderer.colors_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.colors_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global joint ids buffer"
        info.size = size_of(hlsl.float4) * MAX_GLOBAL_VERTICES
        renderer.joint_ids_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.joint_ids_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global joint weights buffer"
        info.size = size_of(hlsl.float4) * MAX_GLOBAL_VERTICES
        renderer.joint_weights_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.joint_weights_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global static mesh data buffer"
        info.size = size_of(GPUStaticMesh) * MAX_GLOBAL_MESHES
        renderer.static_mesh_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.static_mesh_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global joint matrices buffer"
        info.size = size_of(hlsl.float4x4) * MAX_GLOBAL_JOINTS
        renderer.joint_matrices_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.joint_matrices_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global material buffer"
        info.size = size_of(Material) * MAX_GLOBAL_MATERIALS
        renderer.material_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.material_buffer", f32(info.size) / 1024 / 1024)

        info.name = "Global instance buffer"
        info.size = size_of(GPUStaticInstance) * MAX_GLOBAL_INSTANCES
        renderer.instance_buffer = vkw.create_buffer(gd, &info)
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
        renderer.draw_buffer = vkw.create_buffer(gd, &info)
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
        renderer.uniform_buffer = vkw.create_buffer(gd, &info)
        log.debugf("Allocated %v MB of memory for render_state.uniform", f32(info.size) / 1024 / 1024)
    }

    // Initialize the buffer pointers in the uniforms struct
    {
        mesh_buffer, _ := vkw.get_buffer(gd, renderer.static_mesh_buffer)
        material_buffer, _ := vkw.get_buffer(gd, renderer.material_buffer)
        instance_buffer, _ := vkw.get_buffer(gd, renderer.instance_buffer)
        position_buffer, _ := vkw.get_buffer(gd, renderer.positions_buffer)
        uv_buffer, _ := vkw.get_buffer(gd, renderer.uvs_buffer)
        color_buffer, _ := vkw.get_buffer(gd, renderer.colors_buffer)
        joint_ids_buffer, _ := vkw.get_buffer(gd, renderer.joint_ids_buffer)
        joint_weights_buffer, _ := vkw.get_buffer(gd, renderer.joint_weights_buffer)
        joint_matrices_buffer, _ := vkw.get_buffer(gd, renderer.joint_matrices_buffer)
    
        renderer.cpu_uniforms.mesh_ptr = mesh_buffer.address
        renderer.cpu_uniforms.material_ptr = material_buffer.address
        renderer.cpu_uniforms.instance_ptr = instance_buffer.address
        renderer.cpu_uniforms.position_ptr = position_buffer.address
        renderer.cpu_uniforms.uv_ptr = uv_buffer.address
        renderer.cpu_uniforms.color_ptr = color_buffer.address
        renderer.cpu_uniforms.joint_id_ptr = joint_ids_buffer.address
        renderer.cpu_uniforms.joint_weight_ptr = joint_weights_buffer.address
        renderer.cpu_uniforms.joint_mats_ptr = joint_matrices_buffer.address
    }
    renderer.cpu_uniforms.triangle_vis = 0

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
        renderer.main_framebuffer = {
            color_images = color_images,
            depth_image = depth_handle,
            resolution = screen_size,
            clear_color = {1.0, 0.0, 1.0, 1.0},
            color_load_op = .CLEAR,
            depth_load_op = .CLEAR,
        }
    }

    // Graphics pipeline creation
    {
        // Load shader bytecode
        // This will be embedded into the executable at compile-time
        ps1_vert_spv := #load("data/shaders/ps1.vert.spv", []u32)
        ps1_frag_spv := #load("data/shaders/ps1.frag.spv", []u32)

        raster_state := vkw.default_rasterization_state()

        pipeline_infos := make([dynamic]vkw.GraphicsPipelineInfo, context.temp_allocator)

        // PS1 pipeline
        append(&pipeline_infos, vkw.GraphicsPipelineInfo {
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

        append(&pipeline_infos, vkw.GraphicsPipelineInfo {
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

        renderer.ps1_pipeline = handles[0]
        renderer.postfx_pipeline = handles[1]
    }

    // Compute pipeline creation
    {
        infos := make([dynamic]vkw.ComputePipelineInfo, 0, 4, allocator = context.temp_allocator)

        skinning_spv := #load("data/shaders/compute_skinning.comp.spv", []u32)
        append(&infos, vkw.ComputePipelineInfo {
            compute_shader_bytecode = skinning_spv
        })

        handles := vkw.create_compute_pipelines(gd, infos[:])

        renderer.skinning_pipeline = handles[0]
    }

    return renderer
}

delete_renderer :: proc(gd: ^vkw.Graphics_Device, using r: ^Renderer) {
    vkw.delete_buffer(gd, positions_buffer)
    vkw.delete_buffer(gd, index_buffer)
    vkw.delete_buffer(gd, uvs_buffer)
    vkw.delete_buffer(gd, colors_buffer)
    vkw.delete_buffer(gd, static_mesh_buffer)
    vkw.delete_buffer(gd, material_buffer)
    vkw.delete_buffer(gd, instance_buffer)
    vkw.delete_buffer(gd, uniform_buffer)
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
    renderer: ^Renderer,
    positions: []hlsl.float4,
    indices: []u16
) -> Static_Mesh_Handle {
    
    position_start: u32
    {
        positions_len := u32(len(positions))
        assert(renderer.positions_head + positions_len < MAX_GLOBAL_VERTICES)
        assert(positions_len > 0)
    
        position_start = renderer.positions_head
        renderer.positions_head += positions_len
    
        vkw.sync_write_buffer(gd, renderer.positions_buffer, positions, position_start)
    }

    indices_start: u32
    indices_len: u32
    {
        indices_len = u32(len(indices))
        assert(renderer.indices_head + indices_len < MAX_GLOBAL_INDICES)
        assert(indices_len > 0)

        indices_start = renderer.indices_head
        renderer.indices_head += indices_len

        vkw.sync_write_buffer(gd, renderer.index_buffer, indices, indices_start)
    }

    mesh := CPUStaticMeshData {
        indices_start = indices_start,
        indices_len = indices_len,
    }
    handle := Static_Mesh_Handle(hm.insert(&renderer.cpu_static_meshes, mesh))
    gpu_mesh := GPUStaticMesh {
        position_offset = position_start,
        uv_offset = NULL_OFFSET,
        color_offset = NULL_OFFSET
    }
    append(&renderer.gpu_static_meshes, gpu_mesh)

    renderer.dirty_flags += {.Mesh}

    return handle
}

create_skinned_mesh :: proc(
    gd: ^vkw.Graphics_Device,
    renderer: ^Renderer,
    positions: []hlsl.float4,
    indices: []u16,
    joint_ids: []hlsl.uint4,
    joint_weights: []hlsl.float4,
    joint_count: u32,
    first_joint: u32,
) -> Skinned_Mesh_Handle {
    
    position_start: u32
    positions_len := u32(len(positions))
    {
        assert(renderer.positions_head + positions_len < MAX_GLOBAL_VERTICES)
        assert(positions_len > 0)
    
        position_start = renderer.positions_head
        renderer.positions_head += positions_len
    
        vkw.sync_write_buffer(gd, renderer.positions_buffer, positions, position_start)
    }

    indices_start: u32
    indices_len: u32
    {
        indices_len = u32(len(indices))
        assert(renderer.indices_head + indices_len < MAX_GLOBAL_INDICES)
        assert(indices_len > 0)

        indices_start = renderer.indices_head
        renderer.indices_head += indices_len

        vkw.sync_write_buffer(gd, renderer.index_buffer, indices, indices_start)
    }

    joint_ids_start: u32
    {
        joint_ids_len := u32(len(joint_ids))

        joint_ids_start = renderer.joint_ids_head
        renderer.joint_ids_head += joint_ids_len

        vkw.sync_write_buffer(gd, renderer.joint_ids_buffer, joint_ids, joint_ids_start)
    }

    joint_weights_start: u32
    {
        joint_weights_len := u32(len(joint_weights))

        joint_weights_start = renderer.joint_weights_head
        renderer.joint_weights_head += joint_weights_len

        vkw.sync_write_buffer(gd, renderer.joint_weights_buffer, joint_weights, joint_weights_start)
    }

    // Create equivalent static mesh for this skinned mesh
    new_cpu_static_mesh := CPUStaticMeshData {
        indices_start = indices_start,
        indices_len = indices_len,
    }
    static_handle := Static_Mesh_Handle(hm.insert(&renderer.cpu_static_meshes, new_cpu_static_mesh))
    gpu_static_mesh := GPUStaticMesh {
        position_offset = renderer.positions_head,
        uv_offset = NULL_OFFSET,
        color_offset = NULL_OFFSET
    }
    append(&renderer.gpu_static_meshes, gpu_static_mesh)

    assert(renderer.positions_head + positions_len < MAX_GLOBAL_VERTICES)
    gpu_mesh := GPUSkinnedMesh {
        joint_ids_offset = joint_ids_start,
        joint_weights_offset = joint_weights_start,
        in_positions_offset = position_start,
        out_positions_offset = renderer.positions_head,
    }
    renderer.positions_head += positions_len

    mesh := CPUSkinnedMesh {
        vertices_len = u32(len(positions)),
        joint_count = joint_count,
        first_joint = first_joint,
        gpu_data = gpu_mesh,
        static_mesh_handle = static_handle
    }
    handle := Skinned_Mesh_Handle(hm.insert(&renderer.cpu_skinned_meshes, mesh))

    renderer.dirty_flags += {.Mesh}

    return handle
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
        assert(false)
        // gpu_mesh := &gpu_skinned_meshes[handle.index]
        // gpu_mesh.static_data.color_offset = color_start
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
    assert(uvs_head + uvs_len <= MAX_GLOBAL_VERTICES)

    uvs_head += uvs_len

    when HandleType == Static_Mesh_Handle {
        gpu_mesh := &gpu_static_meshes[handle.index]
        gpu_mesh.uv_offset = uv_start
    } else when HandleType == Skinned_Mesh_Handle {
        mesh := hm.get(&cpu_skinned_meshes, hm.Handle(handle)) or_return
        gpu_mesh := &gpu_static_meshes[mesh.static_mesh_handle.index]
        gpu_mesh.uv_offset = uv_start
    } else {
        panic("Invalid arg type")
    }

    return vkw.sync_write_buffer(gd, uvs_buffer, uvs, uv_start)
}

add_material :: proc(using r: ^Renderer, new_mat: ^Material) -> Material_Handle {
    dirty_flags += {.Material}
    return Material_Handle(hm.insert(&cpu_materials, new_mat^))
}


// Per-frame work that needs to happen at the beginning of the frame
new_frame :: proc(renderer: ^Renderer) {
    renderer.cpu_static_instances = make([dynamic]CPUStaticInstance, allocator = context.temp_allocator)
    renderer.gpu_static_instances = make([dynamic]GPUStaticInstance, allocator = context.temp_allocator)
    renderer.cpu_skinned_instances = make([dynamic]CPUSkinnedInstance, allocator = context.temp_allocator)
}

draw_ps1_static_mesh :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^Renderer,
    data: ^StaticModelData,
    draw_data: ^StaticDraw,
) {
    for prim in data.primitives {
        draw_ps1_static_primitive(gd, r, prim.mesh, prim.material, draw_data)
    }
}

draw_ps1_skinned_mesh :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^Renderer,
    data: ^SkinnedModelData,
    draw_data: ^SkinnedDraw,
) {
    for prim in data.primitives {
        draw_ps1_skinned_primitive(gd, r, prim.mesh, prim.material, draw_data)
    }
}

// User code calls this to queue up draw calls
draw_ps1_static_primitive :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^Renderer,
    mesh_handle: Static_Mesh_Handle,
    material_handle: Material_Handle,
    draw_data: ^StaticDraw,
) -> bool {
    dirty_flags += {.Instance,.Draw}

    // Append instance representing this primitive
    new_inst := CPUStaticInstance {
        world_from_model = draw_data.world_from_model,
        mesh_handle = mesh_handle,
        material_handle = material_handle
    }
    append(&cpu_static_instances, new_inst)

    return true
}

draw_ps1_skinned_primitive :: proc(
    gd: ^vkw.Graphics_Device,
    using r: ^Renderer,
    mesh_handle: Skinned_Mesh_Handle,
    material_handle: Material_Handle,
    draw_data: ^SkinnedDraw,
) -> bool {
    dirty_flags += {.Instance,.Draw}

    new_inst := CPUSkinnedInstance {
        world_from_model = draw_data.world_from_model,
        mesh_handle = mesh_handle,
        material_handle = material_handle,
        animation_idx = draw_data.anim_idx,
        animation_time = draw_data.anim_t
    }
    append(&cpu_skinned_instances, new_inst)

    return true
}

ComputeSkinningPushConstants :: struct {
    in_positions: vk.DeviceAddress,
    out_positions: vk.DeviceAddress,
    joint_ids: vk.DeviceAddress,
    joint_weights: vk.DeviceAddress,
    joint_transforms: vk.DeviceAddress,
    max_vtx_id: u32,
}
process_animations :: proc(gd: ^vkw.Graphics_Device, renderer: ^Renderer) {
    push_constant_batches := make([dynamic]ComputeSkinningPushConstants, 0, len(renderer.cpu_skinned_instances), allocator = context.temp_allocator)
    instance_joints_so_far : u32 = 0
    skinned_verts_so_far : u32 = 0
    for skinned_instance in renderer.cpu_skinned_instances {
        anim := renderer.animations[skinned_instance.animation_idx]
        anim_t := skinned_instance.animation_time

        mesh, _ := hm.get(&renderer.cpu_skinned_meshes, hm.Handle(skinned_instance.mesh_handle))
        
        // Get interpolated keyframe state for translation, rotation, and scale
        {
            // Initialize joint matrices with identity matrix
            instance_joints := make([dynamic]hlsl.float4x4, mesh.joint_count, allocator = context.temp_allocator)
            for i in 0..<mesh.joint_count do instance_joints[i] = IDENTITY_MATRIX4x4
            
            // @static no_animation := false
            // @static no_inv_bind := false
            // @static no_parenting := false
            // imgui.Checkbox("no animation step", &no_animation)
            // imgui.Checkbox("no inverse bind step", &no_inv_bind)
            // imgui.Checkbox("no parenting step", &no_parenting)

            // Compute joint transforms from animation channels
            // @TODO: Actually fully finish this
            //if !no_animation {
            {
                for channel in anim.channels {
                    keyframe_count := len(channel.keyframes)
                    assert(keyframe_count > 0)
                    tr := &instance_joints[channel.local_joint_id]

                    // Check if anim_t is before first keyframe or after last
                    if anim_t <= channel.keyframes[0].time {
                        // Clamp to first keyframe
                        now := &channel.keyframes[0]
                        switch channel.aspect {
                            case .Translation: {
                                transform := translation_matrix(now.value.xyz)
                                tr^ = transform * tr^       // Transform is premultiplied
                            }
                            case .Rotation: {
                                now_quat := quaternion(x = now.value[0], y = now.value[1], z = now.value[2], w = now.value[3])
                                transform := linalg.to_matrix4(now_quat)

                                tr^ *= transform            // Rotation is postmultiplied
                            }
                            case .Scale: {
                                transform := scaling_matrix(now.value.xyz)
                                tr^ *= transform            // Scale is postmultiplied
                            }
                        }
                        continue
                    } else if anim_t >= channel.keyframes[keyframe_count - 1].time {
                        // Clamp to last keyframe
                        next := &channel.keyframes[keyframe_count - 1]
                        switch channel.aspect {
                            case .Translation: {
                                transform := translation_matrix(next.value.xyz)
                                tr^ = transform * tr^       // Transform is premultiplied
                            }
                            case .Rotation: {
                                next_quat := quaternion(x = next.value[0], y = next.value[1], z = next.value[2], w = next.value[3])
                                transform := linalg.to_matrix4(next_quat)

                                tr^ *= transform            // Rotation is postmultiplied
                            }
                            case .Scale: {
                                transform := scaling_matrix(next.value.xyz)
                                tr^ *= transform            // Scale is postmultiplied
                            }
                        }
                        continue
                    }

                    // Return the interpolated value of the keyframes
                    for i in 0..<len(channel.keyframes)-1 {
                        now := channel.keyframes[i]
                        next := channel.keyframes[i + 1]
                        if now.time <= anim_t && anim_t < next.time {
                            // Get interpolation value between two times
                            // anim_t == (1 - t)a + bt
                            // anim_t == a + -at + bt
                            // anim_t == a + t(b - a)
                            // anim_t - a == t(b - a)
                            // (anim_t - a) / (b - a) == t
                            // Obviously this is assuming a linear interpolation, which may not be what we have
                            interpolation_amount := (anim_t - now.time) / (next.time - now.time)

                            switch channel.aspect {
                                case .Translation: {
                                    displacement := linalg.lerp(now.value, next.value, interpolation_amount)
                                    transform := translation_matrix(displacement.xyz)
                                    tr^ = transform * tr^       // Transform is premultiplied
                                }
                                case .Rotation: {
                                    now_quat := quaternion(x = now.value[0], y = now.value[1], z = now.value[2], w = now.value[3])
                                    next_quat := quaternion(x = next.value[0], y = next.value[1], z = next.value[2], w = next.value[3])
                                    rotation_quat := linalg.quaternion_slerp_f32(now_quat, next_quat, interpolation_amount)
                                    transform := linalg.to_matrix4(rotation_quat)
    
                                    tr^ *= transform            // Rotation is postmultiplied
                                }
                                case .Scale: {
                                    scale := linalg.lerp(now.value, next.value, interpolation_amount)
                                    transform := scaling_matrix(scale.xyz)
                                    tr^ *= transform            // Scale is postmultiplied
                                }
                            }
                            break
                        }
                    }
                }
            }

            // Postmultiply with parent transform
            //if !no_parenting {
            {
                for i in 1..<len(instance_joints) {
                    joint_transform := &instance_joints[i]
                    joint_transform^ = instance_joints[renderer.joint_parents[u32(i) + mesh.first_joint]] * joint_transform^
                }
            }
            // Premultiply instance joints with inverse bind matrices
            //if !no_inv_bind {
            {
                for i in 0..<len(instance_joints) {
                    joint_transform := &instance_joints[i]
                    joint_transform^ *= renderer.inverse_bind_matrices[u32(i) + mesh.first_joint]
                }
            }

            // Insert another compute shader dispatch
            in_pos_ptr := renderer.cpu_uniforms.position_ptr + vk.DeviceAddress(size_of(hlsl.float4) * mesh.gpu_data.in_positions_offset)

            // @TODO: use a different buffer for vertex stream-out
            out_pos_ptr := renderer.cpu_uniforms.position_ptr + vk.DeviceAddress(size_of(hlsl.float4) * mesh.gpu_data.out_positions_offset)
            
            joint_ids_ptr := renderer.cpu_uniforms.joint_id_ptr + vk.DeviceAddress(size_of(hlsl.uint4) * mesh.gpu_data.joint_ids_offset)
            joint_weights_ptr := renderer.cpu_uniforms.joint_weight_ptr + vk.DeviceAddress(size_of(hlsl.float4) * mesh.gpu_data.joint_weights_offset)
            joint_mats_ptr := renderer.cpu_uniforms.joint_mats_ptr + vk.DeviceAddress(size_of(hlsl.float4x4) * instance_joints_so_far)
            pcs := ComputeSkinningPushConstants {
                in_positions = in_pos_ptr,
                out_positions = out_pos_ptr,
                joint_ids = joint_ids_ptr,
                joint_weights = joint_weights_ptr,
                joint_transforms = joint_mats_ptr,
                max_vtx_id = mesh.vertices_len - 1
            }
            append(&push_constant_batches, pcs)

            // Also add CPUStaticInstance for the skinned output of the compute shader
            new_cpu_static_instance := CPUStaticInstance {
                world_from_model = skinned_instance.world_from_model,
                mesh_handle = mesh.static_mesh_handle,
                material_handle = skinned_instance.material_handle
            }
            append(&renderer.cpu_static_instances, new_cpu_static_instance)

            // Upload to GPU
            vkw.sync_write_buffer(gd, renderer.joint_matrices_buffer, instance_joints[:], instance_joints_so_far)
            instance_joints_so_far += mesh.joint_count
            skinned_verts_so_far += mesh.vertices_len
        }
    }

    // Record commands related to dispatching compute shader
    comp_cb_idx := vkw.begin_compute_command_buffer(gd, renderer.compute_timeline)

    // Bind compute skinning pipeline
    vkw.cmd_bind_compute_pipeline(gd, comp_cb_idx, renderer.skinning_pipeline)

    for i in 0..<len(push_constant_batches) {
        batch := &push_constant_batches[i]
        vkw.cmd_push_constants_compute(gd, comp_cb_idx, batch)

        GROUP_THREADCOUNT :: 64
        q, r := math.divmod(batch.max_vtx_id + 1, GROUP_THREADCOUNT)
        groups : u32 = q
        if r != 0 do groups += 1
        vkw.cmd_dispatch(gd, comp_cb_idx, groups, 1, 1)
    }

    // Barrier to sync streamout buffer writes with vertex shader reads
    pos_buf, _ := vkw.get_buffer(gd, renderer.positions_buffer)
    vkw.cmd_compute_pipeline_barriers(gd, comp_cb_idx, {
        vkw.Buffer_Barrier {
            src_stage_mask = {.COMPUTE_SHADER},
            src_access_mask = {.SHADER_WRITE},
            dst_stage_mask = {.ALL_COMMANDS},
            dst_access_mask = {.SHADER_READ},
            buffer = pos_buf.buffer,
            offset = 0,
            size = pos_buf.alloc_info.size
        }
    }, {})

    // Increment compute timeline semaphore when compute skinning is finished
    vkw.add_signal_op(gd, &renderer.compute_sync, renderer.compute_timeline, gd.frame_count + 1)

    // Have graphics queue wait on compute skinning timeline semaphore
    vkw.add_wait_op(gd, &renderer.gfx_sync, renderer.compute_timeline, gd.frame_count + 1)
    
    vkw.submit_compute_command_buffer(gd, comp_cb_idx, &renderer.compute_sync)
    
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
        gpu_draws := make([dynamic]vk.DrawIndexedIndirectCommand, 0, len(cpu_static_instances), context.temp_allocator)
        
        // Sort instances by mesh handle
        slice.sort_by(cpu_static_instances[:], proc(i, j: CPUStaticInstance) -> bool {
            return i.mesh_handle.index < j.mesh_handle.index
        })

        // With the understanding that these instances are already sorted by
        // mesh_idx, construct the draw stream with appropriate instancing
        current_inst_count := 0
        inst_offset := 0
        current_mesh_handle: Static_Mesh_Handle
        for inst in cpu_static_instances {
            g_inst := GPUStaticInstance {
                world_from_model = inst.world_from_model,
                normal_matrix = hlsl.cofactor(inst.world_from_model),
                mesh_idx = inst.mesh_handle.index,
                material_idx = inst.material_handle.index
            }
            append(&gpu_static_instances, g_inst)

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

        vkw.sync_write_buffer(gd, instance_buffer, gpu_static_instances[:])
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
    vkw.cmd_bind_gfx_descriptor_set(gd, gfx_cb_idx)

    // PS1 simple unlit pipeline
    vkw.cmd_bind_gfx_pipeline(gd, gfx_cb_idx, ps1_pipeline)

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
    vkw.cmd_push_constants_gfx(gd, gfx_cb_idx, &Ps1PushConstants {
        uniform_buffer_ptr = uniform_buf.address,
        sampler_idx = u32(vkw.Immutable_Sampler_Index.Point)
    })

    // There will be one vkCmdDrawIndexedIndirect() per distinct "ubershader" pipeline
    vkw.cmd_draw_indexed_indirect(gd, gfx_cb_idx, draw_buffer, 0, ps1_draw_count)

    vkw.cmd_end_render_pass(gd, gfx_cb_idx)

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
    vkw.cmd_bind_gfx_pipeline(gd, gfx_cb_idx, postfx_pipeline)

    vkw.cmd_push_constants_gfx(gd, gfx_cb_idx, &PostFxPushConstants{
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
    primitives: [dynamic]StaticDrawPrimitive,
    name: string,
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

gltf_static_delete :: proc(using d: ^StaticModelData)  {
    delete(primitives)
}

gltf_skinned_delete :: proc(d: ^SkinnedModelData)  {
    delete(d.primitives)
}

gltf_node_idx :: proc(nodes: []^cgltf.node, n: ^cgltf.node) -> u32 {
    idx : u32 = 0
    for uintptr(nodes[idx]) != uintptr(n) do idx += 1
    return idx
}

load_gltf_textures :: proc(gd: ^vkw.Graphics_Device, gltf_data: ^cgltf.data) -> [dynamic]vkw.Image_Handle {
    loaded_glb_images := make([dynamic]vkw.Image_Handle, len(gltf_data.textures), context.temp_allocator)
    for glb_texture, i in gltf_data.textures {
        glb_image := glb_texture.image_
        data_ptr := get_bufferview_ptr(glb_image.buffer_view, byte)
        log.debugf("Image mime type: %v", glb_image.mime_type)

        channels : i32 = 4
        width, height: i32
        raw_image_ptr := stbi.load_from_memory(data_ptr, i32(glb_image.buffer_view.size), &width, &height, nil, channels)
        defer stbi.image_free(raw_image_ptr)

        // Get texture name
        tex_name := glb_image.name
        if len(tex_name) == 0 {
            tex_name = "Unnamed glTF image"
        }

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
            name = tex_name
        }
        image_slice := slice.from_ptr(raw_image_ptr, int(width * height * channels))
        handle, ok := vkw.sync_create_image_with_data(gd, &image_create_info, image_slice)
        if !ok {
            log.error("Error loading image from glb")
        }
        loaded_glb_images[i] = handle
    }
    return loaded_glb_images
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
    
    loaded_glb_images := load_gltf_textures(gd, gltf_data)

    // @TODO: Don't just load the first mesh you see
    mesh := gltf_data.meshes[0]

    draw_primitives := make([dynamic]StaticDrawPrimitive, len(mesh.primitives), allocator)

    for &primitive, i in mesh.primitives {
        // Get indices
        index_data := load_gltf_indices_u16(&primitive)
    
        // Get vertex data
        position_data: [dynamic]hlsl.float4
        color_data: [dynamic]hlsl.float4
        uv_data: [dynamic]hlsl.float2

        for &attrib in primitive.attributes {
            #partial switch (attrib.type) {
                case .position: position_data = load_gltf_float3_to_float4(&attrib)
                case .color: color_data = load_gltf_float3_to_float4(&attrib)
                case .texcoord: uv_data = load_gltf_float2(&attrib)
            }
        }
    
        // Now that we have the mesh data in CPU-side buffers,
        // it's time to upload them
        mesh_handle := create_static_mesh(gd, render_data, position_data[:], index_data[:])
        if len(color_data) > 0 do add_vertex_colors(gd, render_data, mesh_handle, color_data[:])
        if len(uv_data) > 0 do add_vertex_uvs(gd, render_data, mesh_handle, uv_data[:])


        // Now get material data
        loaded_glb_materials := make([dynamic]Material_Handle, len(gltf_data.materials), context.temp_allocator)
        defer delete(loaded_glb_materials)
        glb_material := primitive.material
        has_material := glb_material != nil

        bindless_image_idx := vkw.Image_Handle {
            index = NULL_OFFSET
        }
        if has_material && glb_material.pbr_metallic_roughness.base_color_texture.texture != nil {
            tex := glb_material.pbr_metallic_roughness.base_color_texture.texture
            color_tex_idx := u32(uintptr(tex) - uintptr(&gltf_data.textures[0])) / size_of(cgltf.texture)
            log.debugf("Texture index is %v", color_tex_idx)
            bindless_image_idx = loaded_glb_images[color_tex_idx]
        }
        
        base_color := hlsl.float4 {1.0, 1.0, 1.0, 1.0}
        if has_material do base_color = hlsl.float4(glb_material.pbr_metallic_roughness.base_color_factor)
        material := Material {
            color_texture = bindless_image_idx.index,
            sampler_idx = u32(vkw.Immutable_Sampler_Index.Aniso16),
            base_color = base_color
        }
        material_handle := add_material(render_data, &material)

        draw_primitives[i] = StaticDrawPrimitive {
            mesh = mesh_handle,
            material = material_handle
        }
    }

    return StaticModelData {
        primitives = draw_primitives,
        name = string(mesh.name)
    }
}

SkinnedDrawPrimitive :: struct {
    mesh: Skinned_Mesh_Handle,
    material: Material_Handle
}

SkinnedModelData :: struct {
    primitives: [dynamic]SkinnedDrawPrimitive,
    first_animation_idx: u32,
    first_joint_idx: u32,
    name: string,
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
    
    loaded_glb_images := load_gltf_textures(gd, gltf_data)

    // @TODO: Don't just load the first mesh you see
    assert(len(gltf_data.meshes) == 1)
    mesh := &gltf_data.meshes[0]

    // Load inverse bind matrices
    joint_count: u32
    first_anim_idx: u32
    first_joint_idx := render_data.joint_matrices_head
    {
        assert(len(gltf_data.skins) == 1)

        glb_skin := gltf_data.skins[0]

        // Get the index that will point to this model's first animation
        // in the global animations list after the animations are pushed
        first_anim_idx = u32(len(render_data.animations))
        
        // Load inverse bind matrices
        inv_bind_count := glb_skin.inverse_bind_matrices.count
        resize(&render_data.inverse_bind_matrices, uint(first_joint_idx) + inv_bind_count)
        inv_bind_ptr := get_accessor_ptr(glb_skin.inverse_bind_matrices, hlsl.float4x4)
        inv_bind_bytes := size_of(hlsl.float4x4) * inv_bind_count
        mem.copy(&render_data.inverse_bind_matrices[first_joint_idx], inv_bind_ptr, int(inv_bind_bytes))

        // Determine joint parentage
        joint_count = u32(len(glb_skin.joints))
        render_data.joint_matrices_head += joint_count
        old_cpu_joint_count := len(render_data.joint_parents)
        resize(&render_data.joint_parents, old_cpu_joint_count + int(joint_count))
        for i in 1..<joint_count {
            jp := &render_data.joint_parents[old_cpu_joint_count + int(i)]

            joint := glb_skin.joints[i]
            parent := joint.parent

            jp^ = gltf_node_idx(glb_skin.joints, parent)
        }

        // Load animation data
        for animation in gltf_data.animations {
            new_anim: Animation

            new_anim.name = string(animation.name)

            // Load animation channels
            for channel in animation.channels {
                out_channel: AnimationChannel
                #partial switch channel.target_path {
                    case .translation: out_channel.aspect = .Translation
                    case .rotation: out_channel.aspect = .Rotation
                    case .scale: out_channel.aspect = .Scale
                    case: log.errorf("Unsupported animation target: %v", channel.target_path)
                }

                if channel.sampler.interpolation == .cubic_spline {
                    log.errorf("Unsupported animation interpolation: %v", channel.sampler.interpolation)
                }
                switch channel.sampler.interpolation {
                    case .step: out_channel.interpolation_type = .Step
                    case .linear: out_channel.interpolation_type = .Linear
                    case .cubic_spline: out_channel.interpolation_type = .CubicSpline
                }

                // Get local idx of animated joint
                out_channel.local_joint_id = gltf_node_idx(glb_skin.joints, channel.target_node)

                keyframe_count := channel.sampler.input.count
                reserve(&out_channel.keyframes, keyframe_count)
                keyframe_times := get_accessor_ptr(channel.sampler.input, f32)
                keyframe_values := make([dynamic]hlsl.float4, keyframe_count, context.temp_allocator)
                #partial switch channel.sampler.output.type {
                    case .vec3: {
                        ptr := get_accessor_ptr(channel.sampler.output, hlsl.float3)
                        for i in 0..<keyframe_count {
                            val := &ptr[i]
                            keyframe_values[i] = {val.x, val.y, val.z, 1.0}
                        }
                    }
                    case .vec4: {
                        ptr := get_accessor_ptr(channel.sampler.output, hlsl.float4)
                        mem.copy(&keyframe_values[0], ptr, int(size_of(hlsl.float4) * keyframe_count))
                    }
                    case: {
                        log.error("Invalid animation sampler output type.")
                    }
                }

                for i in 0..<keyframe_count {
                    append(&out_channel.keyframes, AnimationKeyFrame {
                        time = keyframe_times[i],
                        value = keyframe_values[i],
                    })
                }
                append(&new_anim.channels, out_channel)
            }

            append(&render_data.animations, new_anim)
        }
    }

    draw_primitives := make([dynamic]SkinnedDrawPrimitive, len(mesh.primitives), allocator)

    for &primitive, i in mesh.primitives {
        // Get indices
        index_data := load_gltf_indices_u16(&primitive)
    
        // Get vertex data
        position_data: [dynamic]hlsl.float4
        color_data: [dynamic]hlsl.float4
        uv_data: [dynamic]hlsl.float2
        joint_ids: [dynamic]hlsl.uint4
        joint_weights: [dynamic]hlsl.float4
    
        // @TODO: Use joint ids directly as u16 instead of converting to u32
        for &attrib in primitive.attributes {
            #partial switch (attrib.type) {
                case .position: position_data = load_gltf_float3_to_float4(&attrib)
                case .color: color_data = load_gltf_float3_to_float4(&attrib)
                case .texcoord: uv_data = load_gltf_float2(&attrib)
                case .joints: joint_ids = load_gltf_joint_ids(&attrib)
                case .weights: joint_weights = load_gltf_float4(&attrib)
            }
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
            joint_count,
            first_joint_idx
        )
        if len(color_data) > 0 do add_vertex_colors(gd, render_data, mesh_handle, color_data[:])
        if len(uv_data) > 0 do add_vertex_uvs(gd, render_data, mesh_handle, uv_data[:])


        // Now get material data
        loaded_glb_materials := make([dynamic]Material_Handle, len(gltf_data.materials), context.temp_allocator)
        defer delete(loaded_glb_materials)
        glb_material := primitive.material
        has_material := glb_material != nil

        bindless_image_idx := vkw.Image_Handle {
            index = NULL_OFFSET
        }
        if has_material && glb_material.pbr_metallic_roughness.base_color_texture.texture != nil {
            tex := glb_material.pbr_metallic_roughness.base_color_texture.texture
            color_tex_idx := u32(uintptr(tex) - uintptr(&gltf_data.textures[0])) / size_of(cgltf.texture)
            log.debugf("Texture index is %v", color_tex_idx)
            bindless_image_idx = loaded_glb_images[color_tex_idx]
        }
        
        base_color := hlsl.float4 {1.0, 1.0, 1.0, 1.0}
        if has_material do base_color = hlsl.float4(glb_material.pbr_metallic_roughness.base_color_factor)
        material := Material {
            color_texture = bindless_image_idx.index,
            sampler_idx = u32(vkw.Immutable_Sampler_Index.Aniso16),
            base_color = base_color
        }
        material_handle := add_material(render_data, &material)

        draw_primitives[i] = SkinnedDrawPrimitive {
            mesh = mesh_handle,
            material = material_handle
        }
    }

    return SkinnedModelData {
        primitives = draw_primitives,
        first_animation_idx = first_anim_idx,
        first_joint_idx = first_joint_idx,
        name = strings.clone(string(mesh.name), context.allocator)
    }
}