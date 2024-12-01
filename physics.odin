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
    assert(len(positions) % 3 == 0)

    static_mesh: StaticTriangleCollision
    static_mesh.triangles = make([dynamic]Triangle, 0, len(positions), allocator)

    // For each implicit triangle
    for i := 0; i < len(positions); i += 3 {
        // Triangle vertices
        a := positions[i]
        b := positions[i + 1]
        c := positions[i + 2]

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
    
    out_positions := make([dynamic]f32, allocator)

    // For now just loading the first mesh we see
    mesh := gltf_data.meshes[0]
    primitive := mesh.primitives[0]

    for attrib in primitive.attributes {
        if attrib.type == .position {
            position_float_count := attrib.data.count * 3
            resize(&out_positions, position_float_count)

            positions_ptr := get_accessor_ptr(attrib.data, f32)
            mem.copy(&out_positions[0], positions_ptr, int(position_float_count))
        }
    }

    return out_positions
}