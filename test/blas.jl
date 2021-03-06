using CUDA
using GemmKernels
using LinearAlgebra

CUDA.CUBLAS.cublasSetMathMode(CUBLAS.handle(), CUBLAS.CUBLAS_TENSOR_OP_MATH)

@testset "BLAS API" begin
    @testset "WMMA GEMM" begin
    for transpose_a = [false, true], transpose_b = [false, true],
         M in [128, 256], N in [128, 256], K in [128, 256]
    @testcase "$( !transpose_a ? 'N' : 'T' )$( !transpose_b ? 'N' : 'T' ); M = $M, N = $N, K = $K" begin
            N in [128, 256],
            K in [128, 256]

            alpha = rand(Float32)
            beta  = rand(Float32)

            a_h = rand(Float16, (M, K)) / sqrt(Float16(K))
            b_h = rand(Float16, (K, N)) / sqrt(Float16(K))
            c_h = rand(Float32, (M, N))

            # Transpose input if necessary
            a_h = transpose_a ? transpose(a_h) : a_h
            b_h = transpose_b ? transpose(b_h) : b_h

            a   = CuArray(a_h)
            b   = CuArray(b_h)

            c_gemmkernels = CuArray(c_h)
            GemmKernels.BLAS.gemmEx!(!transpose_a ? 'N' : 'T', !transpose_b ? 'N' : 'T', alpha, a, b, beta, c_gemmkernels)

            c_cublas = CuArray(c_h)
            CUDA.CUBLAS.gemmEx!(!transpose_a ? 'N' : 'T', !transpose_b ? 'N' : 'T', alpha, a, b, beta, c_cublas)

            @test all(isapprox.(Array(c_gemmkernels), Array(c_cublas); rtol=sqrt(eps(Float16))));
        end
    end
    end

    @testset "WMMA GEMM diagonal" begin
    for transpose_b = [false, true],
        M in [128, 256], N in [128, 256], K in [M]
    @testcase "A = diagonal, B = $( !transpose_b ? 'N' : 'T' ); M = $M, N = $N, K = $K" begin
            transpose_a = false

            alpha = rand(Float32)
            beta = rand(Float32)

            a_h = rand(Float16, M);
            b_h = rand(Float16, (K, N)) / sqrt(Float16(K))
            c_h = rand(Float32, (M, N))

            # Transpose input if necessary
            a_h = transpose_a ? transpose(a_h) : a_h
            b_h = transpose_b ? transpose(b_h) : b_h

            a   = Diagonal(CuArray(a_h))
            b   = CuArray(b_h)

            c_gemmkernels = CuArray(c_h)
            GemmKernels.BLAS.gemmEx!(!transpose_a ? 'N' : 'T', !transpose_b ? 'N' : 'T', alpha, a, b, beta, c_gemmkernels)

            c_cublas = CuArray(c_h)
            CUDA.CUBLAS.gemmEx!(!transpose_a ? 'N' : 'T', !transpose_b ? 'N' : 'T', alpha, CuArray(Diagonal(a_h)), b, beta, c_cublas)

            @test all(isapprox.(Array(c_gemmkernels), Array(c_cublas); rtol=sqrt(eps(Float16))));
        end
    end
    end
end
