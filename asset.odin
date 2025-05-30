package main

import "core:log"
import "core:math/linalg/hlsl"
import "core:mem"
import "core:os/os2"
import "core:slice"

import "vendor:cgltf"
import vk "vendor:vulkan"
    
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


DDSHeader_DXT10 :: struct {
    dxgi_format: DXGI_FORMAT,
    resource_dimension: D3D10_RESOURCE_DIMENSION,
    misc_flag: u32,
    array_size: u32,
    misc_flags2: u32
}

D3D10_RESOURCE_DIMENSION :: enum u32 {
    UNKNOWN = 0,
    BUFFER = 1,
    TEXTURE1D = 2,
    TEXTURE2D = 3,
    TEXTURE3D = 4,

    _RESERVED = 0xFFFFFFFF
}

DXGI_FORMAT :: enum u32 {
    UNKNOWN = 0,
    R32G32B32A32_TYPELESS = 1,
    R32G32B32A32_FLOAT = 2,
    R32G32B32A32_UINT = 3,
    R32G32B32A32_SINT = 4,
    R32G32B32_TYPELESS = 5,
    R32G32B32_FLOAT = 6,
    R32G32B32_UINT = 7,
    R32G32B32_SINT = 8,
    R16G16B16A16_TYPELESS = 9,
    R16G16B16A16_FLOAT = 10,
    R16G16B16A16_UNORM = 11,
    R16G16B16A16_UINT = 12,
    R16G16B16A16_SNORM = 13,
    R16G16B16A16_SINT = 14,
    R32G32_TYPELESS = 15,
    R32G32_FLOAT = 16,
    R32G32_UINT = 17,
    R32G32_SINT = 18,
    R32G8X24_TYPELESS = 19,
    D32_FLOAT_S8X24_UINT = 20,
    R32_FLOAT_X8X24_TYPELESS = 21,
    X32_TYPELESS_G8X24_UINT = 22,
    R10G10B10A2_TYPELESS = 23,
    R10G10B10A2_UNORM = 24,
    R10G10B10A2_UINT = 25,
    R11G11B10_FLOAT = 26,
    R8G8B8A8_TYPELESS = 27,
    R8G8B8A8_UNORM = 28,
    R8G8B8A8_UNORM_SRGB = 29,
    R8G8B8A8_UINT = 30,
    R8G8B8A8_SNORM = 31,
    R8G8B8A8_SINT = 32,
    R16G16_TYPELESS = 33,
    R16G16_FLOAT = 34,
    R16G16_UNORM = 35,
    R16G16_UINT = 36,
    R16G16_SNORM = 37,
    R16G16_SINT = 38,
    R32_TYPELESS = 39,
    D32_FLOAT = 40,
    R32_FLOAT = 41,
    R32_UINT = 42,
    R32_SINT = 43,
    R24G8_TYPELESS = 44,
    D24_UNORM_S8_UINT = 45,
    R24_UNORM_X8_TYPELESS = 46,
    X24_TYPELESS_G8_UINT = 47,
    R8G8_TYPELESS = 48,
    R8G8_UNORM = 49,
    R8G8_UINT = 50,
    R8G8_SNORM = 51,
    R8G8_SINT = 52,
    R16_TYPELESS = 53,
    R16_FLOAT = 54,
    D16_UNORM = 55,
    R16_UNORM = 56,
    R16_UINT = 57,
    R16_SNORM = 58,
    R16_SINT = 59,
    R8_TYPELESS = 60,
    R8_UNORM = 61,
    R8_UINT = 62,
    R8_SNORM = 63,
    R8_SINT = 64,
    A8_UNORM = 65,
    R1_UNORM = 66,
    R9G9B9E5_SHAREDEXP = 67,
    R8G8_B8G8_UNORM = 68,
    G8R8_G8B8_UNORM = 69,
    BC1_TYPELESS = 70,
    BC1_UNORM = 71,
    BC1_UNORM_SRGB = 72,
    BC2_TYPELESS = 73,
    BC2_UNORM = 74,
    BC2_UNORM_SRGB = 75,
    BC3_TYPELESS = 76,
    BC3_UNORM = 77,
    BC3_UNORM_SRGB = 78,
    BC4_TYPELESS = 79,
    BC4_UNORM = 80,
    BC4_SNORM = 81,
    BC5_TYPELESS = 82,
    BC5_UNORM = 83,
    BC5_SNORM = 84,
    B5G6R5_UNORM = 85,
    B5G5R5A1_UNORM = 86,
    B8G8R8A8_UNORM = 87,
    B8G8R8X8_UNORM = 88,
    R10G10B10_XR_BIAS_A2_UNORM = 89,
    B8G8R8A8_TYPELESS = 90,
    B8G8R8A8_UNORM_SRGB = 91,
    B8G8R8X8_TYPELESS = 92,
    B8G8R8X8_UNORM_SRGB = 93,
    BC6H_TYPELESS = 94,
    BC6H_UF16 = 95,
    BC6H_SF16 = 96,
    BC7_TYPELESS = 97,
    BC7_UNORM = 98,
    BC7_UNORM_SRGB = 99,
    AYUV = 100,
    Y410 = 101,
    Y416 = 102,
    NV12 = 103,
    P010 = 104,
    P016 = 105,
    //420_OPAQUE = 106,
    YUY2 = 107,
    Y210 = 108,
    Y216 = 109,
    NV11 = 110,
    AI44 = 111,
    IA44 = 112,
    P8 = 113,
    A8P8 = 114,
    B4G4R4A4_UNORM = 115,
    P208 = 130,
    V208 = 131,
    V408 = 132,
    SAMPLER_FEEDBACK_MIN_MIP_OPAQUE,
    SAMPLER_FEEDBACK_MIP_REGION_USED_OPAQUE,
    FORCE_UINT = 0xffffffff
}

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

DDS_MAGIC_WORD :: 0x20534444
DDSHeader :: struct {
    magic_word: u32,            // Must be set to 0x20534444
    size: u32,
    flags: u32,                // @TODO: Should be enum with u32 backing
    height: u32,
    width: u32,
    pitch_or_linear_size: u32,
    depth: u32,
    mipmap_count: u32,
    reserved_1: [11]u32,
    spf: DDSPixelFormat,
    caps: u32,
    caps2: u32,
    caps3: u32,
    caps4: u32,
    reserved2: u32,
    using extra: DDSHeader_DXT10
}

TRUE_DDS_HEADER_SIZE :: 148        //This is DDSHeader + DDSHeader_DXT10 + magic word in bytes
dds_load_header :: proc(file_bytes: []byte) -> (DDSHeader, bool) {
    header: DDSHeader

    header_slice := file_bytes[0:TRUE_DDS_HEADER_SIZE]
    log.debugf("DDSHeader size == %v bytes", size_of(DDSHeader))
    header_ptr := slice.as_ptr(header_slice)
    mem.copy_non_overlapping(&header, header_ptr, TRUE_DDS_HEADER_SIZE)

    if header.magic_word != DDS_MAGIC_WORD {
        return {}, false
    }

    return header, true
}

dxgi_to_vulkan :: proc(format: DXGI_FORMAT) -> vk.Format {
    #partial switch format {
        case .BC7_UNORM: return .BC7_UNORM_BLOCK
        case .BC7_UNORM_SRGB: return .BC7_SRGB_BLOCK
        case: {
            log.errorf("Tried to convert unsupported format %v", format)
            return nil
        }
    }
}
