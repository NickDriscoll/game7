package main

import "core:log"
import "core:math/linalg/hlsl"
import "core:mem"

import "vendor:cgltf"

Ray :: struct {
    start: hlsl.float3,
    direction: hlsl.float3
}

Triangle :: struct {
    a, b, c: hlsl.float3,
    normal: hlsl.float3
}

StaticTriangleCollision :: struct {
    triangles: [dynamic]Triangle
}

delete_static_triangles :: proc(using s: ^StaticTriangleCollision) {
    delete(triangles)
}

static_triangle_mesh :: proc(positions: []f32, allocator := context.allocator) -> StaticTriangleCollision {
    assert(len(positions) % 9 == 0)

    static_mesh: StaticTriangleCollision
    static_mesh.triangles = make([dynamic]Triangle, 0, len(positions) / 9, allocator)

    // For each implicit triangle
    for i := 0; i < len(positions); i += 9 {
        // Triangle vertices
        a := hlsl.float3{positions[i], positions[i + 1], positions[i + 2]}
        b := hlsl.float3{positions[i + 3], positions[i + 4], positions[i + 5]}
        c := hlsl.float3{positions[i + 5], positions[i + 6], positions[i + 7]}

        // Edges AB and AC
        ab := b - a
        ac := c - a

        // Compute normal from cross product of edges
        n := hlsl.normalize(hlsl.cross(ab, ac))

        // Add new triangle to list
        append(&static_mesh.triangles, Triangle {
            a = a,
            b = b,
            c = c,
            normal = n
        })
    }

    return static_mesh
}

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

    // For now just loading the first mesh we see
    mesh := gltf_data.meshes[0]
    primitive := mesh.primitives[0]

    // Get index data
    index_data := make([dynamic]u16, allocator)
    defer delete(index_data)
    indices_count := primitive.indices.count
    indices_bytes := indices_count * size_of(u16)
    resize(&index_data, indices_count)
    index_ptr := get_accessor_ptr(primitive.indices, u16)
    mem.copy(raw_data(index_data), index_ptr, int(indices_bytes))
    
    out_positions := make([dynamic]f32, allocator)

    for attrib in primitive.attributes {
        if attrib.type == .position {
            position_float_count := attrib.data.count * 3
            position_byte_count := position_float_count * size_of(f32)
            out_position_count := indices_count * 3
            resize(&out_positions, out_position_count)

            positions_ptr := get_accessor_ptr(attrib.data, f32)
            for idx, i in index_data {
                f := positions_ptr[idx]
                out_positions[i] = f
            }
            
            //mem.copy(&out_positions[0], positions_ptr, int(position_byte_count))
        }
    }
    assert(len(out_positions) > 0)

    return out_positions
}