package main

import "core:log"
import "core:math/linalg/hlsl"
import "core:mem"
import "core:os"
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

// Old Rust code for getting data from DDS header

// const TRUE_BC7_HEADER_SIZE: usize = 148;        //This is DDSHeader + DDSHeader_DXT10 + magic word

// pub struct DDSHeader {
//     pub magic_word: u32,        // 0x20534444
//     pub size: u32,
//     pub flags: u32,
//     pub height: u32,
//     pub width: u32,
//     pub pitch_or_linear_size: u32,
//     pub depth: u32,
//     pub mipmap_count: u32,
//     pub reserved_1: [u32; 11],
//     pub spf: DDS_PixelFormat,
//     pub caps: u32,
//     pub caps2: u32,
//     pub caps3: u32,
//     pub caps4: u32,
//     pub reserved2: u32,
//     pub dx10_header: DDSHeader_DXT10
// }

// pub struct DDS_PixelFormat {
//     pub size: u32,
//     pub flags: u32,
//     pub four_cc: u32,
//     pub rgb_bitcount: u32,
//     pub r_bitmask: u32,
//     pub g_bitmask: u32,
//     pub b_bitmask: u32,
//     pub a_bitmask: u32,
// }

// pub fn from_file(dds_file: &mut File) -> Self {
//     let mut header_buffer = vec![0u8; Self::TRUE_BC7_HEADER_SIZE];

//     dds_file.read_exact(&mut header_buffer).unwrap();

//     let height = read_u32_from_le_bytes(&header_buffer, 12);
//     let width = read_u32_from_le_bytes(&header_buffer, 16);
//     let pitch_or_linear_size = read_u32_from_le_bytes(&header_buffer, 20);
//     let mipmap_count = read_u32_from_le_bytes(&header_buffer, 28);
//     let pixel_format = DDS_PixelFormat::from_header_bytes(&header_buffer);

//     let dx10_header = DDSHeader_DXT10::from_header_bytes(&header_buffer);

//     DDSHeader {
//         height,
//         width,
//         pitch_or_linear_size,
//         mipmap_count,
//         spf: pixel_format,
//         dx10_header,
//         ..Default::default()
//     }
// }

DDSPixelFormat :: struct {
    size: u32,
    flags: u32,             // @TODO: Should be enum with u32 backing
    four_cc: u32,
    rgb_bitcount: u32,
    r_bitmask: u32,
    g_bitmask: u32,
    b_bitmask: u32,
    a_bitmask: u32,
}

DDSHeader :: struct {
    //magic_word: u32,            // 0x20534444
    size: u32,
    flags: u32,                // @TODO: Should be enum with u32 backing
    height: u32,
    width: u32,
    pitch_or_linear_size: u32,
    depth: u32,
    mipmap_count: u32,
    reserved_1: [11]u32,
    spf: DDSPixelFormat,

}

TRUE_DDS_HEADER_SIZE :: 148        //This is DDSHeader + DDSHeader_DXT10 + magic word in bytes
dds_load_header :: proc(filename: string) -> DDSHeader {
    header: DDSHeader

    // @TODO: Implement

    return header
}
