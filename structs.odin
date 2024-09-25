package main

import vkw "desktop_vulkan_wrapper"

Camera :: struct {
    position: vkw.float3,
    yaw: f32,
    pitch: f32
}

UniformBufferData :: struct {
    clip_from_world: vkw.float4x4
}

PushConstants :: struct {
    time: f32,
    image: u32,
    sampler: vkw.Immutable_Samplers
}

RenderingState :: struct {
    index_buffer: vkw.Buffer_Handle,
    draw_buffer: vkw.Buffer_Handle,
    uniform_buffer: vkw.Buffer_Handle,
    gfx_pipeline: vkw.Pipeline_Handle,
    gfx_timeline: vkw.Semaphore_Handle,
    gfx_sync_info: vkw.Sync_Info,
}

delete_rendering_state :: proc(vgd: ^vkw.Graphics_Device, r: ^RenderingState) {
    vkw.delete_sync_info(&r.gfx_sync_info)
}