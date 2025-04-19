package main

import "core:log"
import "core:math/linalg/hlsl"
import "core:mem"
import "vendor:cgltf"
    
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

// Get the positions buffer of the first meshes first primitive
// GLBs used with this should really only have one big triangle mesh
// @TODO: Fix this awful, broken proc
get_glb_positions :: proc(path: cstring, allocator := context.allocator) -> [dynamic]f32 {
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

    total_indices : uint = 0
    for mesh in gltf_data.meshes {
        for prim in mesh.primitives {
            total_indices += prim.indices.count
        }
    }
    out_positions := make([dynamic]f32, 3 * total_indices, allocator)
    
    head_index : uint = 0
    for mesh in gltf_data.meshes {
        for &prim in mesh.primitives {
            indices := load_gltf_indices_u16(&prim)

            pos_attr: ^cgltf.attribute
            for &att in prim.attributes do if att.type == .position do pos_attr = &att
            positions_ptr := get_accessor_ptr(pos_attr.data, f32)

            for idx, i in indices {
                out_idx := head_index + uint(i)
                out_positions[3 * out_idx] = positions_ptr[3 * idx]
                out_positions[3 * out_idx + 1] = positions_ptr[3 * idx + 1]
                out_positions[3 * out_idx + 2] = positions_ptr[3 * idx + 2]
            }
            head_index += prim.indices.count
        }
    }

    assert(len(out_positions) > 0)

    return out_positions
}

load_gltf_indices_u16 :: proc(primitive: ^cgltf.primitive) -> [dynamic]u16 {
    indices_count := primitive.indices.count
    index_data := make([dynamic]u16, indices_count, context.temp_allocator)
    indices_bytes := indices_count * size_of(u16)
    index_ptr := get_accessor_ptr(primitive.indices, u16)
    mem.copy(raw_data(index_data), index_ptr, int(indices_bytes))

    return index_data
}

load_gltf_float3_to_float4 :: proc(attrib: ^cgltf.attribute) -> [dynamic]hlsl.float4 {
    data := make([dynamic]hlsl.float4, attrib.data.count, context.temp_allocator)
    ptr := get_accessor_ptr(attrib.data, hlsl.float3)

    // Build up buffer, appending a 1.0 to turn each float3 into a float4
    for i in 0..<attrib.data.count {
        pos := ptr[i]
        data[i] = {pos.x, pos.y, pos.z, 1.0}
    }

    return data
}

load_gltf_float2 :: proc(attrib: ^cgltf.attribute) -> [dynamic]hlsl.float2 {
    data := make([dynamic]hlsl.float2, attrib.data.count, context.temp_allocator)
    ptr := get_accessor_ptr(attrib.data, hlsl.float2)
    bytes := attrib.data.count * size_of(hlsl.float2)

    mem.copy(&data[0], ptr, int(bytes))

    return data
}

load_gltf_float4 :: proc(attrib: ^cgltf.attribute) -> [dynamic]hlsl.float4 {
    data := make([dynamic]hlsl.float4, attrib.data.count, context.temp_allocator)
    ptr := get_accessor_ptr(attrib.data, hlsl.float4)
    bytes := attrib.data.count * size_of(hlsl.float4)

    mem.copy(&data[0], ptr, int(bytes))

    return data
}

load_gltf_joint_ids :: proc(attrib: ^cgltf.attribute) -> [dynamic]hlsl.uint4 {
    data := make([dynamic]hlsl.uint4, attrib.data.count, context.temp_allocator)
    ptr := get_accessor_ptr(attrib.data, [4]u16)
    bytes := attrib.data.count * size_of(hlsl.uint4)
    
    // Loop to convert from u16 to u32
    for i in 0..<attrib.data.count {
        id := ptr[i]
        data[i] = hlsl.uint4 {u32(id[0]), u32(id[1]), u32(id[2]), u32(id[3])}
    }

    return data
}

