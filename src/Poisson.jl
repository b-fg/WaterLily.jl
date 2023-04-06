"""
    Poisson{N,M}

Composite type for conservative variable coefficient Poisson equations:

    ∮ds β ∂x/∂n = σ

The resulting linear system is

    Ax = [L+D+L']x = b

where A is symmetric, block-tridiagonal and extremely sparse. Implemented on a
structured grid of dimension N, then L has dimension M=N+1 and size(L,M)=N.
Moreover, D[I]=-∑ᵢ(L[I,i]+L'[I,i]). This means matrix storage, multiplication,
ect can be easily implemented and optimized without external libraries.

To help iteratively solve the system above, the Poisson structure holds
helper arrays for inv(D), the error ϵ, and residual r=b-Ax. An iterative
solution method then estimates the error ϵ=̃A⁻¹r and increments x+=ϵ, r-=Aϵ.
"""
abstract type AbstractPoisson{T,S,V} end
struct Poisson{T,S<:AbstractArray{T},V<:AbstractArray{T}} <: AbstractPoisson{T,S,V}
    L :: V # Lower diagonal coefficients
    D :: S # Diagonal coefficients
    iD :: S # 1/Diagonal
    x :: S # approximate solution
    ϵ :: S # increment/error
    r :: S # residual
    n :: Vector{Int16}    # pressure solver iterations
    function Poisson(x::AbstractArray{T},L::AbstractArray{T}) where T
        @assert axes(x) == axes(L)[1:end-1] 
        @assert axes(L)[end] == Base.OneTo(length(axes(x)))
        r = similar(x); fill!(r,0)
        ϵ,D,iD = copy(r),copy(r),copy(r)
        set_diag!(D,iD,L)
        new{T,typeof(x),typeof(L)}(L,D,iD,x,ϵ,r,[])
    end
end

function set_diag!(D,iD,L)
    @inside D[I] = diag(I,L)
    @inside iD[I] = abs2(D[I])<1e-8 ? 0. : inv(D[I])
end
set_diag!(p::Poisson) = set_diag!(p.D,p.iD,p.L)
update!(p::Poisson,L) = (p.L .= L; set_diag!(p))

@fastmath @inline function diag(I::CartesianIndex{d},L) where {d}
    s = zero(eltype(L))
    for i in 1:d
        s -= @inbounds(L[I,i]+L[I+δ(i,I),i])
    end
    return s
end
@fastmath @inline function multL(I::CartesianIndex{d},L,x) where {d}
    s = zero(eltype(L))
    for i in 1:d
        s += @inbounds(x[I-δ(i,I)]*L[I,i])
    end
    return s
end
@fastmath @inline function multU(I::CartesianIndex{d},L,x) where {d}
    s = zero(eltype(L))
    for i in 1:d
        s += @inbounds(x[I+δ(i,I)]*L[I+δ(i,I),i])
    end
    return s
end
@fastmath @inline mult(I,L,D,x) = @inbounds(x[I]*D[I])+multL(I,L,x)+multU(I,L,x)

"""
    mult(A::AbstractPoisson,x)

Efficient function for Poisson matrix-vector multiplication. Allocates and returns
`b = Ax` with `b=0` in the ghost cells.
"""
function mult(p::Poisson,x)
    @assert axes(p.x)==axes(x)
    b = similar(x); fill!(b,0)
    @inside b[I] = mult(I,p.L,p.D,x)
    return b
end

@fastmath residual!(p::Poisson,b) =
    @inside p.r[I] = b[I]-mult(I,p.L,p.D,p.x)

@fastmath function increment!(p::Poisson)
    @inside p.x[I] = p.x[I]+p.ϵ[I]
    @inside p.r[I] = p.r[I]-mult(I,p.L,p.D,p.ϵ)
end
"""
    GS!(p::Poisson;it=0)

Gauss-Sidel smoother. When it=0, the function serves as a Jacobi preconditioner.
"""
@fastmath function GS!(p::Poisson;it=0)
    @inside p.ϵ[I] = p.r[I]*p.iD[I]
    for i ∈ 1:it
        @inside p.ϵ[I] = p.iD[I]*(p.r[I]-multL(I,p.L,p.ϵ)-multU(I,p.L,p.ϵ))
    end
    increment!(p)
end

"""
    solver!(x,A::AbstractPoisson,b;log,tol,itmx)

Approximate iterative solver for the Poisson matrix equation `Ax=b`.

    `x`: Initial-solution vector mutated by `solver!`
    `A`: Poisson matrix
    `b`: Right-Hand-Side vector
    `log`: If `true`, this function returns a vector holding the `L₂`-norm of the residual at each iteration.
    `tol`: Convergence tolerance on the `L₂`-norm residual.
    'itmx': Maximum number of iterations
"""
function solver!(p::Poisson,b;log=false,tol=1e-4,itmx=1e3)
    @assert size(p.x)==size(b)
    residual!(p,b); r₂ = L₂(p.r)
    log && (res = [r₂])
    nᵖ=0
    while r₂>tol && nᵖ<itmx
        GS!(p,it=5); r₂ = L₂(p.r)
        log && push!(res,r₂)
        nᵖ+=1
    end
    push!(p.n,nᵖ)
    log && return res
end
