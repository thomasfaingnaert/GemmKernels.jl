export Layout
module Layout

using CUDA
using GPUifyLoops: @unroll
using GemmKernels.Tiling
using StaticArrays

# ----------------------
# Explicit vectorisation
# ----------------------

struct Vec{N, T} end

@inline @generated function vloada(::Type{Vec{N, T}}, ptr::Core.LLVMPtr{T, AS}, i::Integer = 1) where {N, T, AS}
    alignment = sizeof(T) * N
    vec_len = (sizeof(T) * N) ÷ sizeof(Float32)

    return quote
        vec_ptr = Base.bitcast(Core.LLVMPtr{NTuple{$vec_len, VecElement{Float32}}, AS}, ptr)
        return unsafe_load(vec_ptr, (i-1) ÷ N + 1, Val($alignment))
    end
end

@inline @generated function vstorea!(::Type{Vec{N, T}}, ptr::Core.LLVMPtr{T, AS}, x, i::Integer = 1) where {N, T, AS}
    alignment = sizeof(T) * N
    vec_len = (sizeof(T) * N) ÷ sizeof(Float32)

    return quote
        vec_ptr = Base.bitcast(Core.LLVMPtr{NTuple{$vec_len, VecElement{Float32}}, AS}, ptr)
        return unsafe_store!(vec_ptr, x, (i-1) ÷ N + 1, Val($alignment))
    end
end

@inline predicated_vectorised_load(ptr::Core.LLVMPtr{Int32, CUDA.AS.Global}, predicate::Bool) = Base.llvmcall(
        """
        %asmval = call {i32, i32, i32, i32} asm "{
            .reg .pred p;

            setp.ne.u32 p, \$5, 0;

            mov.u32 \$0, \$6;
            mov.u32 \$1, \$7;
            mov.u32 \$2, \$8;
            mov.u32 \$3, \$9;

            @p ld.global.v4.u32 {\$0, \$1, \$2, \$3}, [\$4];
        }", "=r,=r,=r,=r,l,r,r,r,r,r"(i64 %0, i32 %1, i32 %2, i32 %3, i32 %4, i32 %5)

        %asmval1 = extractvalue {i32, i32, i32, i32} %asmval, 0
        %asmval2 = extractvalue {i32, i32, i32, i32} %asmval, 1
        %asmval3 = extractvalue {i32, i32, i32, i32} %asmval, 2
        %asmval4 = extractvalue {i32, i32, i32, i32} %asmval, 3

        %ret1 = insertvalue [4 x i32] undef, i32 %asmval1, 0
        %ret2 = insertvalue [4 x i32] %ret1, i32 %asmval2, 1
        %ret3 = insertvalue [4 x i32] %ret2, i32 %asmval3, 2
        %ret4 = insertvalue [4 x i32] %ret3, i32 %asmval4, 3

        ret [4 x i32] %ret4""",
        Tuple{Int32, Int32, Int32, Int32},
        Tuple{Int64, Int32, Int32, Int32, Int32, Int32},
        Base.bitcast(Int64, ptr), convert(Int32, predicate), zero(Int32), zero(Int32), zero(Int32), zero(Int32)
       )


# -----------
# Layout base
# -----------

abstract type LayoutBase{T} end

@inline eltype(::Type{<:LayoutBase{T}}) where {T} = T
@inline physical_size(::Type{<:LayoutBase{T}}, logical_size::NamedTuple) where {T} = Tuple(logical_size)

# --------------
# Padded layouts
# --------------

struct Padded{L, P} end

@inline function pad_logical_coord(::Type{Padded{L, P}}, crd::NamedTuple) where {L, P}
    t = Tuple(crd)
    return typeof(crd)((Base.first(t) + P, Base.tail(t)...))
end

@inline eltype(::Type{Padded{L, P}}) where {L, P} = eltype(L)
@inline physical_size(::Type{Padded{L, P}}, logical_size::NamedTuple) where {L, P} = physical_size(L, pad_logical_coord(Padded{L, P}, logical_size))
@inline load(::Type{Padded{L, P}}, workspace, tile::Tile, logical_size::NamedTuple) where {L, P} = load(L, workspace, tile)
@inline store!(::Type{Padded{L, P}}, workspace, value, tile::Tile) where {L, P} = store!(L, workspace, value, tile::Tile)

# ---------------
# AlignedColMajor
# ---------------

struct AlignedColMajor{T} <: LayoutBase{T} end

@inline physical_size(::Type{Padded{AlignedColMajor{T}, P}}, logical_size::NamedTuple) where {T, P} = (logical_size[1] + P, logical_size[2])

# TODO: cleanup vectorisation
@inline function load(::Type{AlignedColMajor{T}}, workspace, tile::Tile{size}) where {T, size}
    vec_len = 16 ÷ sizeof(T)
    N = (sizeof(T) * vec_len) ÷ sizeof(Float32)
    res = MArray{Tuple{size[1] ÷ vec_len, size[2]}, NTuple{N, VecElement{Float32}}}(undef)

    @unroll for j = 1 : size[2]
        @unroll for i = 1 : vec_len : size[1]
            t = translate(tile, (i - 1, j - 1))

            linear_base = linearise(t.base, Base.size(workspace))
            linear_offset = linearise(t.offset, Base.size(workspace))

            @inbounds res[i, j] = vloada(Vec{vec_len, T}, pointer(workspace), linear_base + linear_offset - 1)
        end
    end

    return res
end

@inline function dummy_load(::Type{AlignedColMajor{T}}, workspace, tile::Tile{size}) where {T, size}
    vec_len = 16 ÷ sizeof(T)
    N = (sizeof(T) * vec_len) ÷ sizeof(Float32)
    res = MArray{Tuple{size[1] ÷ vec_len, size[2]}, NTuple{N, VecElement{Float32}}}(undef)

    @unroll for j = 1 : size[2]
        @unroll for i = 1 : vec_len : size[1]
            t = translate(tile, (i - 1, j - 1))

            linear_base = linearise(t.base, Base.size(workspace))
            linear_offset = linearise(t.offset, Base.size(workspace))

            is_on_diagonal = abs(t.index[1] - t.index[2]) < 8 # We load 8 elements at a time, and the diagonal may fall anywhere inside these 8 elements.
            #= is_on_diagonal = true =#

            #= real_value = vloada(Vec{vec_len, T}, pointer(workspace), linear_base + linear_offset - 1) =#
            #= dummy_value = ntuple(i -> VecElement{Float32}(0), Val(4)) =#
            #= @inbounds res[i, j] = is_on_diagonal ? real_value : dummy_value =#

            #= @inbounds res[i, j] = is_on_diagonal ? vloada(Vec{vec_len, T}, pointer(workspace), linear_base + linear_offset - 1) : ntuple(i -> VecElement{Float32}(0), Val(4)) =#
            #= @inbounds res[i, j] = is_on_diagonal ? vloada(Vec{vec_len, T}, pointer(workspace) + sizeof(Float16) * (linear_base + linear_offset - 2), 1) : ntuple(i -> VecElement{Float32}(0), Val(4)) =#
            #= pred_res = predicated_vectorised_load(pointer(workspace) + linear_base + linear_offset - 2, is_on_diagonal) =#

            pred_res = predicated_vectorised_load(reinterpret(Core.LLVMPtr{Int32, CUDA.AS.Global}, pointer(workspace) + sizeof(Float16) * (linear_base + linear_offset - 2)), is_on_diagonal)
            @inbounds res[i, j] = ntuple(i -> VecElement{Float32}(Base.bitcast(Float32, pred_res[i])), Val(4))
        end
    end

    return res
end

@inline function store!(::Type{AlignedColMajor{T}}, workspace, value, tile::Tile{size}) where {T, size}
    vec_len = 16 ÷ sizeof(T)

    @unroll for j = 1 : size[2]
        @unroll for i = 1 : vec_len : size[1]
            t = translate(tile, (i - 1, j - 1))

            linear_base = linearise(t.base, Base.size(workspace))
            linear_offset = linearise(t.offset, Base.size(workspace))

            @inbounds vstorea!(Vec{vec_len, T}, pointer(workspace), value[i, j], linear_base + linear_offset - 1)
        end
    end
end

# ---------------
# AlignedRowMajor
# ---------------

struct AlignedRowMajor{T} <: LayoutBase{T} end

@inline physical_size(::Type{Padded{AlignedRowMajor{T}, P}}, logical_size::NamedTuple) where {T, P} = (logical_size[2] + P, logical_size[1])

# TODO: cleanup vectorisation
@inline function load(::Type{AlignedRowMajor{T}}, workspace, tile::Tile{size}) where {T, size}
    vec_len = 16 ÷ sizeof(T)
    N = (sizeof(T) * vec_len) ÷ sizeof(Float32)
    res = MArray{Tuple{size[1], size[2] ÷ vec_len}, NTuple{N, VecElement{Float32}}}(undef)

    @unroll for i = 1 : size[1]
        @unroll for j = 1 : vec_len : size[2]
            t = translate(tile, (i - 1, j - 1))

            linear_base = linearise(reverse(Tuple(t.base)), Base.size(workspace))
            linear_offset = linearise(reverse(Tuple(t.offset)), Base.size(workspace))

            @inbounds res[i, j] = vloada(Vec{vec_len, T}, pointer(workspace), linear_base + linear_offset - 1)
        end
    end

    return res
end

@inline function store!(::Type{AlignedRowMajor{T}}, workspace, value, tile::Tile{size}) where {T, size}
    vec_len = 16 ÷ sizeof(T)

    @unroll for i = 1 : size[1]
        @unroll for j = 1 : vec_len : size[2]
            t = translate(tile, (i - 1, j - 1))

            linear_base = linearise(reverse(Tuple(t.base)), Base.size(workspace))
            linear_offset = linearise(reverse(Tuple(t.offset)), Base.size(workspace))

            @inbounds vstorea!(Vec{vec_len, T}, pointer(workspace), value[i, j], linear_base + linear_offset - 1)
        end
    end
end

# -------------------
# InterleavedColMajor
# -------------------

struct InterleavedColMajor{T} <: LayoutBase{T} end

@inline function load(::Type{InterleavedColMajor{T}}, workspace, tile::Tile{size}) where {T, size}
    res = MArray{Tuple{tile.size[1], tile.size[2]}, Complex{T}}(undef)

    @unroll for j = 1 : tile.size[2]
        @unroll for i = 1 : tile.size[1]
            t = translate(tile, (i - 1, j - 1))

            @inbounds res[i, j] = workspace[t.index[1] + 1, t.index[2] + 1]
        end
    end

    return res
end

@inline function store!(::Type{InterleavedColMajor{T}}, workspace, value, tile::Tile{size}) where {T, size}
    @unroll for j = 1 : size[2]
        @unroll for i = 1 : size[1]
            t = translate(tile, (i - 1, j - 1))

            @inbounds workspace[t.index[1] + 1, t.index[2] + 1] = value[i, j]
        end
    end
end

# -------------------
# InterleavedRowMajor
# -------------------

struct InterleavedRowMajor{T} <: LayoutBase{T} end

@inline function load(::Type{InterleavedRowMajor{T}}, workspace, tile::Tile{size}) where {T, size}
    res = MArray{Tuple{tile.size[1], tile.size[2]}, Complex{T}}(undef)

    @unroll for i = 1 : tile.size[1]
        @unroll for j = 1 : tile.size[2]
            t = translate(tile, (i - 1, j - 1))

            @inbounds res[i, j] = workspace[t.index[2] + 1, t.index[1] + 1]
        end
    end

    return res
end

@inline function store!(::Type{InterleavedRowMajor{T}}, workspace, value, tile::Tile{size}) where {T, size}
    @unroll for i = 1 : size[1]
        @unroll for j = 1 : size[2]
            t = translate(tile, (i - 1, j - 1))

            @inbounds workspace[t.index[2] + 1, t.index[1] + 1] = value[i, j]
        end
    end
end

# -------------
# SplitColMajor
# -------------

struct SplitColMajor{T} <: LayoutBase{T} end

@inline function physical_size(::Type{SplitColMajor{T}}, logical_size::NamedTuple) where {T}
    t = Tuple(logical_size)
    return (t..., 2)
end

@inline function load(::Type{SplitColMajor{T}}, workspace, tile::Tile{size}) where {T, size}
    res = MArray{Tuple{tile.size[1], tile.size[2]}, Complex{T}}(undef)

    @unroll for j = 1 : tile.size[2]
        @unroll for i = 1 : tile.size[1]
            t = translate(tile, (i - 1, j - 1))

            @inbounds res[i,j] = workspace[t.index[1] + 1, t.index[2] + 1, 1] + workspace[t.index[1] + 1, t.index[2] + 1, 2] * im
        end
    end

    return res
end

@inline function store!(::Type{SplitColMajor{T}}, workspace, value, tile::Tile{size}) where {T, size}
    @unroll for j = 1 : tile.size[2]
        @unroll for i = 1 : tile.size[1]
            t = translate(tile, (i - 1, j - 1))

            @inbounds workspace[t.index[1] + 1, t.index[2] + 1, 1] = value[i, j].re
            @inbounds workspace[t.index[1] + 1, t.index[2] + 1, 2] = value[i, j].im
        end
    end
end

# -------------
# SplitRowMajor
# -------------

struct SplitRowMajor{T} <: LayoutBase{T} end

@inline function physical_size(::Type{SplitRowMajor{T}}, logical_size::NamedTuple) where {T}
    t = reverse(Tuple(logical_size))
    return (t..., 2)
end

@inline function load(::Type{SplitRowMajor{T}}, workspace, tile::Tile{size}) where {T, size}
    res = MArray{Tuple{tile.size[1], tile.size[2]}, Complex{T}}(undef)

    @unroll for i = 1 : tile.size[1]
        @unroll for j = 1 : tile.size[2]
            t = translate(tile, (i - 1, j - 1))

            @inbounds res[i,j] = workspace[t.index[2] + 1, t.index[1] + 1, 1] + workspace[t.index[2] + 1, t.index[1] + 1, 2] * im
        end
    end

    return res
end

@inline function store!(::Type{SplitRowMajor{T}}, workspace, value, tile::Tile{size}) where {T, size}
    @unroll for i = 1 : tile.size[1]
        @unroll for j = 1 : tile.size[2]
            t = translate(tile, (i - 1, j - 1))

            @inbounds workspace[t.index[2] + 1, t.index[1] + 1, 1] = value[i, j].re
            @inbounds workspace[t.index[2] + 1, t.index[1] + 1, 2] = value[i, j].im
        end
    end
end

end
