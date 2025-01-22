package main

import "core:log"
import "core:math"
import "core:math/linalg/hlsl"
import "core:mem"

import "vendor:cgltf"

Sphere :: struct {
    origin: hlsl.float3,
    radius: f32,
}

Ray :: struct {
    start: hlsl.float3,
    direction: hlsl.float3,
}

Segment :: struct {
    start: hlsl.float3,
    end: hlsl.float3,
}

// Point-normal form of plane
// Plane :: struct {
//     p: hlsl.float3,
//     normal: hlsl.float3
// }

Triangle :: struct {
    a, b, c: hlsl.float3,
}

StaticTriangleCollision :: struct {
    triangles: [dynamic]Triangle,
}

delete_static_triangles :: proc(using s: ^StaticTriangleCollision) {
    delete(triangles)
}

static_triangle_mesh :: proc(positions: []f32, model_matrix: hlsl.float4x4, allocator := context.allocator) -> StaticTriangleCollision {
    FLOATS_PER_TRIANGLE :: 9

    assert(len(positions) % FLOATS_PER_TRIANGLE == 0)

    static_mesh: StaticTriangleCollision
    static_mesh.triangles = make([dynamic]Triangle, 0, len(positions) / FLOATS_PER_TRIANGLE, allocator)

    // For each implicit triangle
    for i := 0; i < len(positions); i += FLOATS_PER_TRIANGLE {
        // Triangle vertices
        a4 := hlsl.float4{positions[i], positions[i + 1], positions[i + 2], 1.0}
        b4 := hlsl.float4{positions[i + 3], positions[i + 4], positions[i + 5], 1.0}
        c4 := hlsl.float4{positions[i + 6], positions[i + 7], positions[i + 8], 1.0}

        // Transform with supplied model matrix
        a := hlsl.float3((model_matrix * a4).xyz)
        b := hlsl.float3((model_matrix * b4).xyz)
        c := hlsl.float3((model_matrix * c4).xyz)

        // Edges AB and AC
        ab := b - a
        ac := c - a

        // Compute normal from cross product of edges
        //n := hlsl.normalize(hlsl.cross(ab, ac))

        // Add new triangle to list
        append(&static_mesh.triangles, Triangle {
            a = a,
            b = b,
            c = c,
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









// Implementation adapted from section 5.1.5 of Real-Time Collision Detection
closest_pt_triangle :: proc(point: hlsl.float3, using triangle: ^Triangle) -> hlsl.float3 {
    dot :: hlsl.dot

    // Check if point is in vertex region outside A
    ab := b - a
    ac := c - a
    ap := point - a
    d1 := dot(ab, ap)
    d2 := dot(ac, ap)
    if d1 <= 0 && d2 <= 0 {
        return a
    }

    // Check if the point is in vertex region outside B
    bp := point - b
    d3 := dot(ab, bp)
    d4 := dot(ac, bp)
    if d3 >= 0 && d4 <= d3 {
        return b
    }

    // Check if P in edge region of AB
    vc := d1*d4 - d3*d2
    if vc <= 0 && d1 >= 0 && d3 <= 0 {
        w := d1 / (d1 - d3)
        candidate_point := a + w * ab
        return candidate_point
    }

    // Check if P in vertex region outside C
    cp := point - c
    d5 := dot(ab, cp)
    d6 := dot(ac, cp)
    if d6 >= 0 && d5 <= d6 {
        return c
    }

    // Check if P in edge region AC
    vb := d5*d2 - d1*d6
    if vb <= 0 && d2 >= 0 && d6 <= 0 {
        w := d2 / (d2 - d6)
        candidate_point := a + w * ac
        return candidate_point
    }

    // Check if P is in edge region of BC
    va := d3*d6 - d5*d4
    if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
        w := (d4 - d3) / ((d4 - d3) + (d5 - d6))
        candidate_point := b + w * (c - b)
        return candidate_point
    }

    // P inside face region. Compute Q through its barycentric coordinates (u,v,w)
    denom := 1.0 / (va + vb + vc)
    v := vb * denom
    w := vc * denom
    candidate := a + ab * v + ac * w
    return candidate
}

// This proc returns the first collision detected
closest_pt_triangles :: proc(point: hlsl.float3, using tris: ^StaticTriangleCollision) -> hlsl.float3 {

    // Helper proc to check if a closest point is
    // the closest one we've found so far
    check_closest_candidate :: proc(
        test_point: hlsl.float3,
        candidate: hlsl.float3,
        current_closest: ^hlsl.float3,
        shortest_dist: ^f32,
    ) {
        dist := hlsl.distance(test_point, candidate)
        if dist < shortest_dist^ {
            current_closest^ = candidate
            shortest_dist^ = dist
        }
    }

    // Test each triangle until the closest point
    closest_point: hlsl.float3
    shortest_distance := math.INF_F32
    for &triangle in triangles {
        candidate := closest_pt_triangle(point, &triangle)
        check_closest_candidate(point, candidate, &closest_point, &shortest_distance)
    }

    return closest_point
}

// Implementation adapted from section 3.4 of Real-Time Collision Detection
// Returns v and w of point's barycentril coords with regards to tri.
// Implictly, u = 1.0 - v - w
pt_barycentric :: proc(point: hlsl.float3, tri: ^Triangle) -> (f32, f32) {
    v0 := tri.b - tri.a
    v1 := tri.c - tri.a
    v2 := point - tri.a

    d00 := hlsl.dot(v0, v0)
    d01 := hlsl.dot(v0, v1)
    d11 := hlsl.dot(v1, v1)
    d20 := hlsl.dot(v2, v0)
    d21 := hlsl.dot(v2, v1)

    denom := d00 * d11 - d01 * d01
    v := (d11 * d20 - d01 * d21) / denom
    w := (d00 * d21 - d01 * d20) / denom
    return v, w
}

// Returns true if p is in tri
pt_in_triangle :: proc(p: hlsl.float3, tri: ^Triangle) -> bool {
    v, w := pt_barycentric(p, tri)
    return 0.0 <= v && v <= 1.0 && 0.0 <= w && w <= 1.0 && v + w <= 1.0
}

// Implementation adapted from section 5.3.6 of Real-Time Collision Detection
intersect_ray_triangle :: proc(ray: ^Ray, using tri: ^Triangle) -> (hlsl.float3, bool) {
    ab := b - a
    ac := c - a
    //qp := p - q
    qp := -ray.direction

    // Compute normal
    n := hlsl.cross(ab, ac)

    // Compute denominator
    // If <= 0.0, ray is parallel or points away
    denom := hlsl.dot(qp, n)
    if denom <= 0.0 do return {}, false

    ap := ray.start - a
    t := hlsl.dot(ap, n)
    if t < 0.0 do return {}, false

    // Compute barycentric coordinates
    e := hlsl.cross(qp, ap)
    v := hlsl.dot(ac, e)
    if v < 0.0 || v > denom do return {}, false
    w := -hlsl.dot(ab, e)
    if w < 0.0 || v + w > denom do return {}, false

    // Ray does intersect
    ood := 1.0 / denom
    t *= ood
    v *= ood
    w *= ood
    u := 1.0 - v - w

    world_space_collision := a*u + b*v + c*w
    return world_space_collision, true
}

intersect_segment_triplane_t :: proc(segment: ^Segment, using tri: ^Triangle) -> (f32, bool) {
    ab := b - a
    ac := c - a
    qp := segment.start - segment.end

    // Compute normal
    n := hlsl.cross(ab, ac)

    // Compute denominator
    // If <= 0.0, ray is parallel or points away
    denom := hlsl.dot(qp, n)
    if denom <= 0.0 do return {}, false

    ap := segment.start - a
    t := hlsl.dot(ap, n) / denom
    return t, t >= 0.0 && t <= 1.0
}

// Implementation adapted from section 5.3.6 of Real-Time Collision Detection
intersect_segment_triangle_t :: proc(segment: ^Segment, using tri: ^Triangle) -> (f32, bool) {

    // @TODO: Figure out why this method is broken

    // ab := b - a
    // ac := c - a
    // qp := segment.start - segment.end

    // // Compute normal
    // n := hlsl.cross(ab, ac)
    // n = hlsl.normalize(n)

    // // Compute denominator
    // // If <= 0.0, ray is parallel or points away
    // denom := hlsl.dot(qp, n)
    // if denom <= 0.0 do return {}, false

    // ap := hlsl.normalize(segment.start - a)
    // t := hlsl.dot(ap, n)
    // if t < 0.0 || t > 1.0 do return {}, false

    // // Compute barycentric coordinates
    // e := hlsl.cross(qp, ap)
    // v := hlsl.dot(ac, e)
    // if v < 0.0 || v > denom do return {}, false
    // w := -hlsl.dot(ab, e)
    // if w < 0.0 || v + w > denom do return {}, false

    // // Ray does intersect
    // ood := 1.0 / denom
    // t *= ood
    // v *= ood
    // w *= ood
    // u := 1.0 - v - w

    t, ok := intersect_segment_triplane_t(segment, tri)
    if ok {
        candidate_pt := segment.start + t * (segment.end - segment.start)
        ok = pt_in_triangle(candidate_pt, tri)
    }

    return t, ok
}
intersect_segment_triangle :: proc(segment: ^Segment, using tri: ^Triangle) -> (hlsl.float3, bool) {
    t, ok := intersect_segment_triangle_t(segment, tri)
    world_space_collision := t * (segment.end - segment.start)
    return world_space_collision, ok
}

// Implementation adapted from section 5.3.2 of Real-Time Collision Detection
intersect_ray_sphere_t :: proc(r: ^Ray, s: ^Sphere) -> (f32, bool) {
    m := r.start - s.origin
    b := hlsl.dot(m, r.direction)
    c := hlsl.dot(m, m) - s.radius * s.radius // Signed distance of the ray origin from the sphere origin
    
    // Exit if r's origin is outside s (c > 0) and r is pointing away from s (b > 0.0)
    if c > 0.0 && b > 0.0 do return {}, false

    // discr < 0.0 means the ray missed
    discr := b * b - c
    if discr < 0.0 do return {}, false

    // Compute smallest t-value of intersection
    sqrt_discr := math.sqrt(discr)
    t := -b - sqrt_discr

    // THIS BEHAVIOR DIVERGES FROM THE BOOK
    // The book implements a test with a solid sphere,
    // and as such clamps t to 0.0 when t < 0.0
    // This, however, is a hollow sphere, so we try the 
    // second t-value and try again
    if t < 0.0 do t = -b + sqrt_discr
    if t < 0.0 do return {}, false

    return t, true
}
intersect_segment_sphere_t :: proc(seg: ^Segment, s: ^Sphere) -> (f32, bool) {
    seg_vec := seg.end - seg.start
    seg_len := hlsl.length(seg_vec)
    r := Ray {
        start = seg.start,
        direction = seg_vec / seg_len
    }
    t, ok := intersect_ray_sphere_t(&r, s)
    return t / seg_len, ok
}
intersect_ray_sphere :: proc(r: ^Ray, s: ^Sphere) -> (hlsl.float3, bool) {
    t, ok := intersect_ray_sphere_t(r, s)
    return r.start + t * r.direction, ok
}

// Returns closest intersection
intersect_ray_triangles :: proc(ray: ^Ray, tris: ^StaticTriangleCollision) -> (hlsl.float3, bool) {
    candidate_point: hlsl.float3
    candidate_distance := math.INF_F32
    found := false
    for &tri in tris.triangles {
        point: hlsl.float3
        ok: bool
        point, ok = intersect_ray_triangle(ray, &tri)
        if ok {
            d := hlsl.distance(ray.start, point)
            if d < candidate_distance {
                candidate_point = point
                candidate_distance = d
                found = true
            }
        }
    }

    return candidate_point, found
}

intersect_segment_triangles_t :: proc(segment: ^Segment, tris: ^StaticTriangleCollision) -> (f32, bool) {
    candidate_t := math.INF_F32
    for &tri in tris.triangles {
        t, ok := intersect_segment_triangle_t(segment, &tri)
        if ok {
            if t < candidate_t {
                candidate_t = t
            }
        }
    }

    return candidate_t, candidate_t < math.INF_F32
}

intersect_segment_triangles :: proc(segment: ^Segment, tris: ^StaticTriangleCollision) -> (hlsl.float3, bool) {
    t, found := intersect_segment_triangles_t(segment, tris)

    return (segment.start + t * (segment.end - segment.start)), found
}

intersect_segment_terrain :: proc(segment: ^Segment, terrain: []TerrainPiece) -> (hlsl.float3, bool) {
    cand_t := math.INF_F32
    for &piece in terrain {
        t, ok := intersect_segment_triangles_t(segment, &piece.collision)
        if ok {
            if t < cand_t {
                cand_t = t
            }
        }
    }

    return segment.start + cand_t * (segment.end - segment.start), cand_t < math.INF_F32
}

intersect_segment_terrain_normal :: proc() {
    
}

// Returns the point on the sphere that is closest to the triangle
// assuming the sphere is in front of the triangle
closest_pt_sphere_triplane :: proc(s: ^Sphere, tri: ^Triangle) -> hlsl.float3 {
    return s.origin + s.radius * -hlsl.normalize(hlsl.cross(tri.b - tri.a, tri.c - tri.a))
}

// Implementation adapted from section 5.5.6 of Real-Time Collision Detection
dynamic_sphere_vs_triangle_t :: proc(s: ^Sphere, tri: ^Triangle, motion_interval: ^Segment) -> (f32, bool) {

    // The point on the sphere that will first intersect
    // the triangle's plane is D
    d := closest_pt_sphere_triplane(s, tri)

    // Compute P, the point where D will touch tri's supporting plane
    //t, ok := intersect_segment_triangle_t(motion_interval, tri)
    d_segment := Segment {
        start = d,
        end = d + (motion_interval.end - motion_interval.start)
    }
    t, ok := intersect_segment_triplane_t(&d_segment, tri)
    // If motion interval wasn't long enough
    if !ok do return {}, false
    p := d + t * (motion_interval.end - motion_interval.start)

    // If p is in the triangle, it's our point of interest
    if pt_in_triangle(p, tri) do return t, true

    // Otherwise, get point Q: the closest point to P on the triangle
    q := closest_pt_triangle(p, tri)


    // @TODO: The following raycast will cause the sphere to unnaturally
    // snap down to the triangle when q_t > t
    
    // Cast a ray from Q to the sphere to determine possible intersection
    q_segment := Segment {
        start = q,
        end = q + (motion_interval.start - motion_interval.end)
    }
    q_t, ok2 := intersect_segment_sphere_t(&q_segment, s)
    return q_t, ok2
}
dynamic_sphere_vs_triangles_t :: proc(s: ^Sphere, tris: ^StaticTriangleCollision, motion_interval: ^Segment) -> (f32, bool) {
    candidate_t := math.INF_F32
    found := false
    for &tri in tris.triangles {
        t, ok := dynamic_sphere_vs_triangle_t(s, &tri, motion_interval)
        if ok {
            if t < candidate_t do candidate_t = t
            found = true
        }
    }
    return candidate_t, found
}

dynamic_sphere_vs_triangles :: proc(s: ^Sphere, tris: ^StaticTriangleCollision, motion_interval: ^Segment) -> (hlsl.float3, bool) {
    candidate_t := math.INF_F32
    d: hlsl.float3
    t: f32
    found := false
    for &tri in tris.triangles {
        ok: bool
        t, ok = dynamic_sphere_vs_triangle_t(s, &tri, motion_interval)
        if ok {
            if t < candidate_t do candidate_t = t
            // The point on the sphere that will first intersect
            // the triangle's plane is D
            d = s.origin + s.radius * -hlsl.normalize(hlsl.cross(tri.b - tri.a, tri.c - tri.a))
            found = true
        }
    }
    return d + t * (motion_interval.end - motion_interval.start), found
}
