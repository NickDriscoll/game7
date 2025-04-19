package main

import "core:log"
import "core:math"
import "core:math/linalg/hlsl"
import "core:mem"

import "vendor:cgltf"

Sphere :: struct {
    position: hlsl.float3,
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
    local_positions: []f32,
    triangles: [dynamic]Triangle,
}

delete_static_triangles :: proc(using s: ^StaticTriangleCollision) {
    delete(triangles)
}

positions_to_triangle :: proc(positions: []f32, transform: hlsl.float4x4) -> Triangle {
    FLOATS_PER_TRIANGLE :: 9
    assert(len(positions) % FLOATS_PER_TRIANGLE == 0)

    // Triangle vertices
    a4 := hlsl.float4{positions[0], positions[1], positions[2], 1.0}
    b4 := hlsl.float4{positions[3], positions[4], positions[5], 1.0}
    c4 := hlsl.float4{positions[6], positions[7], positions[8], 1.0}

    // Transform with supplied model matrix
    a := hlsl.float3((transform * a4).xyz)
    b := hlsl.float3((transform * b4).xyz)
    c := hlsl.float3((transform * c4).xyz)

    // Compute normal from cross product of edges
    // Edges AB and AC
    // ab := b - a
    // ac := c - a

    // n := hlsl.normalize(hlsl.cross(ab, ac))

    return Triangle {
        a = a,
        b = b,
        c = c,
    }
}

new_static_triangle_mesh :: proc(positions: []f32, model_matrix: hlsl.float4x4, allocator := context.allocator) -> StaticTriangleCollision {
    FLOATS_PER_TRIANGLE :: 9

    assert(len(positions) % FLOATS_PER_TRIANGLE == 0)

    static_mesh: StaticTriangleCollision
    static_mesh.triangles = make([dynamic]Triangle, 0, len(positions) / FLOATS_PER_TRIANGLE, allocator)

    // For each implicit triangle
    for i := 0; i < len(positions); i += FLOATS_PER_TRIANGLE {
        start := i
        end := i + FLOATS_PER_TRIANGLE
        append(&static_mesh.triangles, positions_to_triangle(positions[start:end], model_matrix))
    }

    static_mesh.local_positions = positions
    return static_mesh
}

rebuild_static_triangle_mesh :: proc(collision: ^StaticTriangleCollision, model_matrix: hlsl.float4x4) {
    FLOATS_PER_TRIANGLE :: 9
    
    // For each implicit triangle
    tri_count := len(collision.local_positions) / FLOATS_PER_TRIANGLE
    for i := 0; i < tri_count; i += 1 {
        tri := &collision.triangles[i]
        start := FLOATS_PER_TRIANGLE * i
        end := start + FLOATS_PER_TRIANGLE
        tri^ = positions_to_triangle(collision.local_positions[start:end], model_matrix)
    }
}

copy_static_triangle_mesh :: proc(collision: StaticTriangleCollision, allocator := context.allocator) -> StaticTriangleCollision {
    new_positions := make([]f32, len(collision.local_positions), allocator)
    new_triangles := make([dynamic]Triangle, len(collision.triangles), allocator)
    copy(new_positions, collision.local_positions)
    copy(new_triangles[:], collision.triangles[:])
    
    return StaticTriangleCollision {
        local_positions = new_positions,
        triangles = new_triangles
    }
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
closest_pt_triangle_with_normal :: proc(point: hlsl.float3, using triangle: ^Triangle) -> (hlsl.float3, hlsl.float3) {
    dot :: hlsl.dot

    // Check if point is in vertex region outside A
    ab := b - a
    ac := c - a
    ap := point - a
    d1 := dot(ab, ap)
    d2 := dot(ac, ap)
    if d1 <= 0 && d2 <= 0 {
        n := hlsl.normalize(hlsl.cross(ab, ac))
        return a, n
    }

    // Check if the point is in vertex region outside B
    bp := point - b
    d3 := dot(ab, bp)
    d4 := dot(ac, bp)
    if d3 >= 0 && d4 <= d3 {
        n := hlsl.normalize(hlsl.cross(ab, ac))
        return b, n
    }

    // Check if P in edge region of AB
    vc := d1*d4 - d3*d2
    if vc <= 0 && d1 >= 0 && d3 <= 0 {
        n := hlsl.normalize(hlsl.cross(ab, ac))
        w := d1 / (d1 - d3)
        candidate_point := a + w * ab
        return candidate_point, n
    }

    // Check if P in vertex region outside C
    cp := point - c
    d5 := dot(ab, cp)
    d6 := dot(ac, cp)
    if d6 >= 0 && d5 <= d6 {
        n := hlsl.normalize(hlsl.cross(ab, ac))
        return c, n
    }

    // Check if P in edge region AC
    vb := d5*d2 - d1*d6
    if vb <= 0 && d2 >= 0 && d6 <= 0 {
        n := hlsl.normalize(hlsl.cross(ab, ac))
        w := d2 / (d2 - d6)
        candidate_point := a + w * ac
        return candidate_point, n
    }

    // Check if P is in edge region of BC
    va := d3*d6 - d5*d4
    if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
        n := hlsl.normalize(hlsl.cross(ab, ac))
        w := (d4 - d3) / ((d4 - d3) + (d5 - d6))
        candidate_point := b + w * (c - b)
        return candidate_point, n
    }

    n := hlsl.normalize(hlsl.cross(ab, ac))
    // P inside face region. Compute Q through its barycentric coordinates (u,v,w)
    denom := 1.0 / (va + vb + vc)
    v := vb * denom
    w := vc * denom
    candidate := a + ab * v + ac * w
    return candidate, n
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
closest_pt_triangles_with_normal :: proc(point: hlsl.float3, using tris: ^StaticTriangleCollision) -> (hlsl.float3, hlsl.float3) {

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
    cn: hlsl.float3
    shortest_distance := math.INF_F32
    for &triangle in triangles {
        candidate, n := closest_pt_triangle_with_normal(point, &triangle)
        dist := hlsl.distance(point, candidate)
        if dist < shortest_distance {
            closest_point = candidate
            shortest_distance = dist
            cn = n
        }
    }

    return closest_point, cn
}

closest_pt_terrain :: proc(point: hlsl.float3, terrain: []TerrainPiece) -> hlsl.float3 {
    candidate: hlsl.float3
    closest_dist := math.INF_F32
    for &piece in terrain {
        p := closest_pt_triangles(point, &piece.collision)
        d := hlsl.distance(point, p)
        if d < closest_dist {
            candidate = p
            closest_dist = d
        }
    }
    return candidate
}
closest_pt_terrain_with_normal :: proc(point: hlsl.float3, terrain: []TerrainPiece) -> (hlsl.float3, hlsl.float3) {
    candidate: hlsl.float3
    cn: hlsl.float3
    closest_dist := math.INF_F32
    for &piece in terrain {
        p, n := closest_pt_triangles_with_normal(point, &piece.collision)
        d := hlsl.distance(point, p)
        if d < closest_dist {
            candidate = p
            closest_dist = d
            cn = n
        }
    }
    return candidate, cn
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
intersect_segment_triplane_t_with_normal :: proc(segment: ^Segment, using tri: ^Triangle) -> (f32, hlsl.float3, bool) {
    ab := b - a
    ac := c - a
    qp := segment.start - segment.end

    // Compute normal
    n := hlsl.cross(ab, ac)

    // Compute denominator
    // If <= 0.0, ray is parallel or points away
    denom := hlsl.dot(qp, n)
    if denom <= 0.0 do return {}, {}, false

    ap := segment.start - a
    t := hlsl.dot(ap, n) / denom
    return t, hlsl.normalize(n), t >= 0.0 && t <= 1.0
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
intersect_segment_triangle_t_with_normal :: proc (segment: ^Segment, tri: ^Triangle) -> (f32, hlsl.float3, bool) {
    t, n, ok := intersect_segment_triplane_t_with_normal(segment, tri)
    if ok {
        candidate_pt := segment.start + t * (segment.end - segment.start)
        ok = pt_in_triangle(candidate_pt, tri)
    }

    return t, n, ok
}
intersect_segment_triangle :: proc(segment: ^Segment, using tri: ^Triangle) -> (hlsl.float3, bool) {
    t, ok := intersect_segment_triangle_t(segment, tri)
    world_space_collision := t * (segment.end - segment.start)
    return world_space_collision, ok
}

// Implementation adapted from section 5.3.2 of Real-Time Collision Detection
intersect_ray_sphere_t :: proc(r: ^Ray, s: ^Sphere) -> (f32, bool) {
    m := r.start - s.position
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

intersect_segment_triangles_t_with_normal :: proc(segment: ^Segment, tris: ^StaticTriangleCollision) -> (f32, hlsl.float3, bool) {
    candidate_t := math.INF_F32
    normal: hlsl.float3
    for &tri in tris.triangles {
        t, n, ok := intersect_segment_triangle_t_with_normal(segment, &tri)
        if ok {
            if t < candidate_t {
                candidate_t = t
                normal = n
            }
        }
    }

    return candidate_t, normal, candidate_t < math.INF_F32
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

intersect_segment_terrain_with_normal :: proc(segment: ^Segment, terrain: []TerrainPiece) -> (f32, hlsl.float3, bool) {
    cand_t := math.INF_F32
    normal: hlsl.float3
    for &piece in terrain {
        t, n, ok := intersect_segment_triangles_t_with_normal(segment, &piece.collision)
        if ok {
            if t < cand_t {
                cand_t = t
                normal = n
            }
        }
    }

    return cand_t, normal, cand_t < math.INF_F32
}

// Returns the point on the sphere that is closest to the triangle
// assuming the sphere is in front of the triangle
closest_pt_sphere_triplane :: proc(s: ^Sphere, tri: ^Triangle) -> hlsl.float3 {
    return s.position + s.radius * -hlsl.normalize(hlsl.cross(tri.b - tri.a, tri.c - tri.a))
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
    return q_t, ok2 && q_t <= t
}
dynamic_sphere_vs_triangle_t_with_normal :: proc(s: ^Sphere, tri: ^Triangle, motion_interval: ^Segment) -> (f32, hlsl.float3, bool) {

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
    if !ok do return {}, {}, false
    p := d + t * (motion_interval.end - motion_interval.start)

    // If p is in the triangle, it's our point of interest
    if pt_in_triangle(p, tri) {
        n := hlsl.normalize(hlsl.cross(tri.b - tri.a, tri.c - tri.a))
        return t, n, true
    }

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
    n := hlsl.normalize(hlsl.cross(tri.b - tri.a, tri.c - tri.a))
    return q_t, n, ok2 && q_t <= t
}
dynamic_sphere_vs_triangles_t :: proc(s: ^Sphere, tris: ^StaticTriangleCollision, motion_interval: ^Segment) -> (f32, bool) {
    candidate_t := math.INF_F32
    for &tri in tris.triangles {
        t, ok := dynamic_sphere_vs_triangle_t(s, &tri, motion_interval)
        if ok {
            if t < candidate_t do candidate_t = t
        }
    }
    return candidate_t, candidate_t < math.INF_F32
}
dynamic_sphere_vs_triangles_t_with_normal :: proc(
    s: ^Sphere,
    tris: ^StaticTriangleCollision,
    motion_interval: ^Segment
) -> (f32, hlsl.float3, bool) {
    candidate_t := math.INF_F32
    current_n := hlsl.float3 {}
    for &tri in tris.triangles {
        t, n, ok := dynamic_sphere_vs_triangle_t_with_normal(s, &tri, motion_interval)
        if ok {
            if t < candidate_t {
                candidate_t = t
                current_n = n
            }
        }
    }
    return candidate_t, current_n, candidate_t < math.INF_F32
}

dynamic_sphere_vs_terrain_t :: proc(s: ^Sphere, terrain: []TerrainPiece, motion_interval: ^Segment) -> (f32, bool) {
    closest_t := math.INF_F32
    for &piece in terrain {
        t, ok3 := dynamic_sphere_vs_triangles_t(s, &piece.collision, motion_interval)
        if ok3 {
            if t < closest_t do closest_t = t
        }
    }
    return closest_t, closest_t < math.INF_F32
}

dynamic_sphere_vs_terrain_t_with_normal :: proc(s: ^Sphere, terrain: []TerrainPiece, motion_interval: ^Segment) -> (f32, hlsl.float3, bool) {
    closest_t := math.INF_F32
    current_n := hlsl.float3 {}
    for &piece in terrain {
        t, n, ok3 := dynamic_sphere_vs_triangles_t_with_normal(s, &piece.collision, motion_interval)
        if ok3 {
            if t < closest_t {
                closest_t = t
                current_n = n
            }
        }
    }
    return closest_t, current_n, closest_t < math.INF_F32
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
            d = s.position + s.radius * -hlsl.normalize(hlsl.cross(tri.b - tri.a, tri.c - tri.a))
            found = true
        }
    }
    return d + t * (motion_interval.end - motion_interval.start), found
}


do_mouse_raycast :: proc(
    viewport_camera: Camera,
    terrain_pieces: []TerrainPiece,
    mouse_location: [2]i32,
    viewport_dimensions: [4]f32
) -> (hlsl.float3, bool) {
    viewport_coords := hlsl.uint2 {
        u32(mouse_location.x) - u32(viewport_dimensions[0]),
        u32(mouse_location.y) - u32(viewport_dimensions[1]),
    }
    ray := get_view_ray(
        viewport_camera,
        viewport_coords,
        {u32(viewport_dimensions[2]), u32(viewport_dimensions[3])}
    )

    collision_pt: hlsl.float3
    closest_dist := math.INF_F32
    for &piece in terrain_pieces {
        candidate, ok := intersect_ray_triangles(&ray, &piece.collision)
        if ok {
            candidate_dist := hlsl.distance(candidate, viewport_camera.position)
            if candidate_dist < closest_dist {
                collision_pt = candidate
                closest_dist = candidate_dist
            }
        }
    }

    return collision_pt, closest_dist < math.INF_F32
}