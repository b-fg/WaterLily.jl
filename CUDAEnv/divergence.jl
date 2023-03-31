using KernelAbstractions,CUDA,CUDA.CUDAKernels,Adapt,OffsetArrays
using OffsetArrays: Origin
CUDA.allowscalar(false)
struct Flow{Scal,Vect}
    backend :: Backend
    u :: Vect
    σ :: Scal
    function Flow(N::NTuple{D}; backend = CPU(), T = Float32) where D
        ArrayT = (backend == CUDABackend()) ? CuArray : Array
        Nd = (N...,D); Od = (zeros(Int,D)...,1)
        vect() = adapt(ArrayT,Origin(Od)(rand(T,Nd)))
        scal() = adapt(ArrayT,Origin(0)(zeros(T,N)))

        u = vect()
        σ = scal()
        new{typeof(σ),typeof(u)}(backend,u,σ)
    end
end
Base.size(a::Flow) = size(a.σ).-2

@inline δ(i,I::CartesianIndex{m}) where{m} = CartesianIndex(ntuple(j -> j==i ? 1 : 0, m))
@inline ∂(a,I::CartesianIndex{m},u::AbstractArray{T,n}) where {T,n,m} = @inbounds u[I+δ(a,I),a]-u[I,a]
@fastmath @inline function div_operator(I::CartesianIndex{m},u) where {m} 
    init=zero(eltype(u))
    for i in 1:m
     init += @inbounds ∂(i,I,u)
    end
    return init
end
@kernel function div_kernel(div, u)
    I = @index(Global, Cartesian)
    div[I] = div_operator(I,u)
end
divergence!(a::Flow) = div_kernel(a.backend,64)(a.σ,a.u,ndrange=size(a))
div_serial!(a::Flow) = @inbounds @simd for I in CartesianIndices(size(a))
    a.σ[I] = div_operator(I,a.u)
end

begin # Test the correctness of the kernels
    N = (4+2,3+2) 
    flowGPU = Flow(N; backend=CUDABackend());
    flowCPU = Flow(N); flowCPU.u .= adapt(Array,flowGPU.u);

    div_serial!(flowCPU)
    σ = copy(flowCPU.σ); 
    fill!(flowCPU.σ,0);

    divergence!(flowCPU)
    @assert flowCPU.σ ≈ σ

    divergence!(flowGPU)
    @assert adapt(Array,flowGPU.σ) ≈ σ
end

using BenchmarkTools
begin
    N = (2^10+2, 2^10+2)
    flowGPU = Flow(N; backend=CUDABackend());
    flowCPU = Flow(N; backend=CPU());

    @btime div_serial!($flowCPU) # 200.900 μs (0 allocations: 0 bytes)
    @btime divergence!($flowCPU) # 104.000 μs (206 allocations: 17.94 KiB)
    @btime divergence!($flowGPU) #   2.600 μs (61 allocations: 3.06 KiB)
end