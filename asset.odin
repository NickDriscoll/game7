package main

import "core:log"
import "core:mem"
import "vendor:cgltf"


// Get the positions buffer of the first meshes first primitive
// GLBs used with this should really only have one big triangle mesh
get_glb_positions :: proc(path: cstring, allocator := context.allocator) -> [dynamic]f32 {
    
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
    
    out_positions := make([dynamic]f32, allocator)

    // For now just loading the first mesh we see
    mesh := gltf_data.meshes[0]
    if len(gltf_data.meshes) > 1 do log.warnf("Only loading first mesh from \"%v\" which contains multiple", path)

    idx_offset : uint = 0
    total_position_floats : uint = 0
    for primitive in mesh.primitives {
        // Get index data
        index_data := make([dynamic]u16, allocator)
        defer delete(index_data)
        indices_count := primitive.indices.count
        indices_bytes := indices_count * size_of(u16)
        resize(&index_data, indices_count)
        index_ptr := get_accessor_ptr(primitive.indices, u16)
        mem.copy(raw_data(index_data), index_ptr, int(indices_bytes))

        total_position_floats += indices_count * 3
    
        for attrib in primitive.attributes {
            if attrib.type == .position {
                position_float_count := attrib.data.count * 3
                position_byte_count := position_float_count * size_of(f32)
                resize(&out_positions, total_position_floats)
    
                positions_ptr := get_accessor_ptr(attrib.data, f32)
                for idx, i in index_data {
                    out_idx := idx_offset + uint(i)
                    out_positions[3 * out_idx] = positions_ptr[3 * idx]
                    out_positions[3 * out_idx + 1] = positions_ptr[3 * idx + 1]
                    out_positions[3 * out_idx + 2] = positions_ptr[3 * idx + 2]
                }
            }
        }
        idx_offset += indices_count
    }

    assert(len(out_positions) > 0)

    return out_positions
}