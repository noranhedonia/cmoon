module cynicmoon;

#if !defined(CMOON_GPU_TABLE_SET_BINDING)
#define CMOON_GPU_TABLE_SET_BINDING 0
#define CMOON_STORAGE_BUFFER_BINDING 0
#define CMOON_STORAGE_TEXTURE_BINDING 1
#define CMOON_SAMPLED_TEXTURE_BINDING 2
#define CMOON_SAMPLER_BINDING 3
#define CMOON_DEVICE_ADDRESS_BUFFER_BINDING 4
#define CMOON_ACCELERATION_STRUCTURE_BINDING 5
#endif

/* TODO d3d12, metal, webgpu bindings ? */
#define CMOON_DECL_PUSH_CONSTANT             [[vk::push_constant]]
#define CMOON_DECL_STORAGE_BUFFERS           [[vk::binding(CMOON_STORAGE_BUFFER_BINDING, 0)]]
#define CMOON_DECL_STORAGE_TEXTURES          [[vk::binding(CMOON_STORAGE_TEXTURE_BINDING, 0)]]
#define CMOON_DECL_SAMPLED_TEXTURES          [[vk::binding(CMOON_SAMPLED_TEXTURE_BINDING, 0)]]
#define CMOON_DECL_SAMPLERS                  [[vk::binding(CMOON_SAMPLER_BINDING, 0)]]
#define CMOON_DECL_ACCELERATION_STRUCTURES   [[vk::binding(CMOON_ACCELERATION_STRUCTURE_BINDING, 0)]]
#define CMOON_DECL_BUFFER_ADDRESSES          [[vk::binding(CMOON_DEVICE_ADDRESS_BUFFER_BINDING, 0)]]

#define CMOON_ID_INDEX_BITS 20
#define CMOON_ID_INDEX_MASK ((uint64_t(1) << CMOON_ID_INDEX_BITS) - uint64_t(1))
#define CMOON_ID_INDEX_OFFSET 0
#define CMOON_ID_VERSION_BITS 44
#define CMOON_ID_VERSION_MASK ((uint64_t(1) << CMOON_ID_VERSION_BITS) - uint64_t(1))
#define CMOON_ID_VERSION_OFFSET CMOON_ID_INDEX_BITS

#define _CMOON_DECL_VEC_TYPES(SLANG_TYPE, CMOON_TYPE)       \
    typedef SLANG_TYPE CMOON_TYPE;                          \
    typedef SLANG_TYPE ## 1 CMOON_TYPE ## vec1;             \
    typedef SLANG_TYPE ## 2 CMOON_TYPE ## vec2;             \
    typedef SLANG_TYPE ## 3 CMOON_TYPE ## vec3;             \
    typedef SLANG_TYPE ## 4 CMOON_TYPE ## vec4;

#define _CMOON_DECL_MAT_TYPES(SLANG_TYPE, CMOON_TYPE)       \
    typedef matrix<SLANG_TYPE, 1, 1> CMOON_TYPE ## mat1     \
    typedef matrix<SLANG_TYPE, 2, 1> CMOON_TYPE ## mat1x2   \
    typedef matrix<SLANG_TYPE, 3, 1> CMOON_TYPE ## mat1x3   \
    typedef matrix<SLANG_TYPE, 4, 1> CMOON_TYPE ## mat1x4   \
    typedef matrix<SLANG_TYPE, 1, 2> CMOON_TYPE ## mat2     \
    typedef matrix<SLANG_TYPE, 2, 2> CMOON_TYPE ## mat2x2   \
    typedef matrix<SLANG_TYPE, 3, 2> CMOON_TYPE ## mat2x3   \
    typedef matrix<SLANG_TYPE, 4, 2> CMOON_TYPE ## mat2x4   \
    typedef matrix<SLANG_TYPE, 1, 3> CMOON_TYPE ## mat3     \
    typedef matrix<SLANG_TYPE, 2, 3> CMOON_TYPE ## mat3x2   \
    typedef matrix<SLANG_TYPE, 3, 3> CMOON_TYPE ## mat3x3   \
    typedef matrix<SLANG_TYPE, 4, 3> CMOON_TYPE ## mat3x4   \
    typedef matrix<SLANG_TYPE, 1, 4> CMOON_TYPE ## mat4     \
    typedef matrix<SLANG_TYPE, 2, 4> CMOON_TYPE ## mat4x2   \
    typedef matrix<SLANG_TYPE, 3, 4> CMOON_TYPE ## mat4x3   \
    typedef matrix<SLANG_TYPE, 4, 4> CMOON_TYPE ## mat4x4

#define _CMOON_DECL_VEC_MAT_TYPES(SLANG_TYPE, CMOON_TYPE)       \
    _CMOON_DECL_VEC_TYPES(SLANG_TYPE ## 8_t,  CMOON_TYPE ## 8)  \
    _CMOON_DECL_VEC_TYPES(SLANG_TYPE ## 16_t, CMOON_TYPE ## 16) \
    _CMOON_DECL_VEC_TYPES(SLANG_TYPE ## 32_t, CMOON_TYPE ## 32) \
    _CMOON_DECL_VEC_TYPES(SLANG_TYPE ## 64_t, CMOON_TYPE ## 64) \
    _CMOON_DECL_MAT_TYPES(SLANG_TYPE ## 8_t,  CMOON_TYPE ## 8)  \
    _CMOON_DECL_MAT_TYPES(SLANG_TYPE ## 16_t, CMOON_TYPE ## 16) \
    _CMOON_DECL_MAT_TYPES(SLANG_TYPE ## 32_t, CMOON_TYPE ## 32) \
    _CMOON_DECL_MAT_TYPES(SLANG_TYPE ## 64_t, CMOON_TYPE ## 64)

namespace cmoon {
    _CMOON_DECL_VEC_MAT_TYPES(int, i)
    _CMOON_DECL_VEC_MAT_TYPES(uint, u)
    _CMOON_DECL_VEC_TYPES(half, f16)
    _CMOON_DECL_VEC_TYPES(float, f32)
    _CMOON_DECL_VEC_TYPES(double, f64)
    _CMOON_DECL_MAT_TYPES(half, f16)
    _CMOON_DECL_MAT_TYPES(float, f32)
    _CMOON_DECL_MAT_TYPES(double, f64)

    CMOON_DECL_STORAGE_BUFFERS          __DynamicResource               buffers[];
    CMOON_DECL_STORAGE_BUFFERS          coherent __DynamicResource      buffers_coherent[];
    CMOON_DECL_STORAGE_TEXTURES         __DynamicResource               storage_textures[];
    CMOON_DECL_STORAGE_TEXTURES         coherent __DynamicResource      storage_textures_coherent[];
    CMOON_DECL_SAMPLED_TEXTURES         __DynamicResource               sampled_textures[];
    CMOON_DECL_SAMPLED_TEXTURES         coherent __DynamicResource      sampled_textures_coherent[];
    CMOON_DECL_SAMPLERS                 SamplerState                    samplers[];
#if defined(CMOON_RAY_TRACING)
    CMOON_DECL_ACCELERATION_STRUCTURES  RaytracingAccelerationStructure acceleration_structures[];
#endif /* CMOON_RAY_TRACING */
    CMOON_DECL_BUFFER_ADDRESSES         StructuredBuffer<u64>           buffer_addresses;

    struct BufferId {
        u64 value;

        u32 index() { return u32(CMOON_ID_INDEX_MASK & value); }
        u64 version() { return (value >> CMOON_ID_VERSION_OFFSET); }
        bool is_empty() { return value == 0; }
        u64 device_address() { return buffer_addresses[index()]; }
    };

    struct TextureViewId {
        u64 value;

        u32 index() { return u32(CMOON_ID_INDEX_MASK & value); }
        u64 version() { return (value >> CMOON_ID_VERSION_OFFSET); }
        bool is_empty() { return value == 0; }
    };

    struct TextureViewIdx {
        u32 value;

        u32 index() { return u32(CMOON_ID_INDEX_MASK & value); }
        bool is_empty() { return value == 0; }
    };

    struct SamplerId {
        u64 value;

        u32 index() { return u32(CMOON_ID_INDEX_MASK & value); }
        u64 version() { return (value >> CMOON_ID_VERSION_OFFSET); }
        bool is_empty() { return value == 0; }
        SamplerState get() { return samplers[index()]; }
    };

#if defined(CMOON_RAY_TRACING)
    CMOON_DECL_ACCELERATION_STRUCTURES RaytracingAccelerationStructure ray_tracing_acceleration_structure_table[];
    extension RaytracingAccelerationStructure {
        static RaytracingAccelerationStructure get(TlasId i) { 
            return ray_tracing_acceleration_structure_table[i.index()]; 
        }
    };

    struct TlasId {
        u64 value;

        u32 index() { return u32(CMOON_ID_INDEX_MASK & value); }
        u64 version() { return (value >> CMOON_ID_VERSION_OFFSET); }
        bool is_empty() { return value == 0; }

        RaytracingAccelerationStructure get() { 
            return ray_tracing_acceleration_structure_table[index()]; 
        }
    };
#endif // CMOON_RAY_TRACING

    extension ByteAddressBuffer {
        static ByteAddressBuffer get(BufferId i) { return buffers[i.index()]; }
        static ByteAddressBuffer get_coherent(BufferId i) { return buffers_coherent[i.index()]; }
    };

    extension RWByteAddressBuffer {
        static RWByteAddressBuffer get(BufferId i) { return buffers[i.index()]; }
        static RWByteAddressBuffer get_coherent(BufferId i) { return buffers_coherent[i.index()]; }
    };

    extension SamplerState {
        static SamplerState get(SamplerId i) { return samplers[i.index()]; }
    };
} /* namespace cmoon */

#define _CMOON_DECL_TEX_EXTENSION(TYPE, TABLE)                          \
__generic<T : ITexelElement> extension TYPE<T> {                        \
    static TYPE<T> get(cmoon::TextureViewId i)                          \
    { return TABLE[i.index()]; }                                        \
                                                                        \
    static TYPE<T> get_coherent(cmoon::TextureViewId i)                 \
    { return TABLE ## _coherent[i.index()]; }                           \
                                                                        \
    static TYPE<T> get(cmoon::TextureViewIdx i)                         \
    { return TABLE[i.index()]; }                                        \
                                                                        \
    static TYPE<T> get_coherent(cmoon::TextureViewIdx i)                \
    { return TABLE ## _coherent[i.index()]; }                           \
}                                                                       \
namespace cmoon {                                                       \
    __generic<T : ITexelElement>                                        \
    struct TYPE ## Id                                                   \
    {                                                                   \
        TextureViewId id;                                               \
        TYPE<T> get() { return TYPE<T>::get(id); }                      \
        TYPE<T> get_coherent() { return TYPE<T>::get_coherent(id); }    \
    };                                                                  \
    __generic<T : ITexelElement>                                        \
    struct TYPE ## Idx                                                  \
    {                                                                   \
        TextureViewIdx idx;                                             \
        TYPE<T> get() { return TYPE<T>::get(idx); }                     \
        TYPE<T> get_coherent() { return TYPE<T>::get_coherent(idx); }   \
    };                                                                  \
} /* namespace cmoon */

_CMOON_DECL_TEX_EXTENSION(RWTexture1D, cmoon::storage_textures)
_CMOON_DECL_TEX_EXTENSION(RWTexture2D, cmoon::storage_textures)
_CMOON_DECL_TEX_EXTENSION(RWTexture3D, cmoon::storage_textures)
_CMOON_DECL_TEX_EXTENSION(RWTexture1DArray, cmoon::storage_textures)
_CMOON_DECL_TEX_EXTENSION(RWTexture2DArray, cmoon::storage_textures)

_CMOON_DECL_TEX_EXTENSION(Texture1D, cmoon::sampled_textures)
_CMOON_DECL_TEX_EXTENSION(Texture2D, cmoon::sampled_textures)
_CMOON_DECL_TEX_EXTENSION(Texture3D, cmoon::sampled_textures)
_CMOON_DECL_TEX_EXTENSION(Texture1DArray, cmoon::sampled_textures)
_CMOON_DECL_TEX_EXTENSION(Texture2DArray, cmoon::sampled_textures)
_CMOON_DECL_TEX_EXTENSION(TextureCube, cmoon::sampled_textures)
_CMOON_DECL_TEX_EXTENSION(TextureCubeArray, cmoon::sampled_textures)
_CMOON_DECL_TEX_EXTENSION(Texture2DMS, cmoon::sampled_textures)
