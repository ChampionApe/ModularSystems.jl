# IndexSet: a sparsity pattern as a value — the coordinate-level twin of VariableGroup.

"""
    IndexSet(axes::NTuple{N,Symbol}, coords)
    IndexSet(axes, coords)

An ordered, duplicate-free set of coordinate tuples with named axes. Where a [`VariableGroup`](@ref)
is a set of variable *cells*, an `IndexSet` is a set of the *coordinates* those cells sit at, and it
carries the same `∪`, `∩` and `setdiff`.

Its purpose is sparse variables. Declaring one with a filter makes JuMP evaluate the predicate over
the full product of the axes, which scales with that product rather than with the number of variables
created. Declaring over a coordinate axis does not:

```julia
pairs = IndexSet((:p, :i), [(:food, :agri), (:steel, :mfg)])
@variable(model, use[pairs, t in years])     # plain JuMP, no scan
use[(:food, :agri), 2030]
```

A coordinate-keyed container is also dense over its own axes, so there are no absent cells to raise
`KeyError` and nothing for a zero sentinel to paper over. Equations iterate the pattern instead of
guarding a product:

```julia
sum(use[k, t] * price[k, t] for k in patternA ∩ patternB)
```

Use [`select_axes`](@ref) to project onto fewer axes and [`group_by`](@ref) to bucket coordinates by
some of them, which is what replaces summing over one index of a sparse variable.
"""
struct IndexSet{N,T<:Tuple}
    axes::NTuple{N,Symbol}
    coords::Vector{T}
    set::Set{T}

    # Explicit, to suppress the generated converting constructor that would otherwise claim any
    # three-argument call.
    function IndexSet(axes::NTuple{N,Symbol}, coords::Vector{T}, set::Set{T}) where {N,T<:Tuple}
        return new{N,T}(axes, coords, set)
    end
end

function IndexSet(axes::NTuple{N,Symbol}, coords) where {N}
    items = collect(coords)
    isempty(items) && return IndexSet(axes, Tuple{}[], Set{Tuple{}}())
    T = typeof(first(items))
    out = T[]
    seen = Set{T}()
    for c in items
        length(c) == N || throw(DimensionMismatch(
            "coordinate $c has $(length(c)) entries but there are $N axes"))
        if !(c in seen)
            push!(seen, c)
            push!(out, c)
        end
    end
    return IndexSet(axes, out, seen)
end

IndexSet(axes::AbstractVector{Symbol}, coords) = IndexSet(Tuple(axes), coords)

Base.length(s::IndexSet) = length(s.coords)
Base.isempty(s::IndexSet) = isempty(s.coords)
Base.iterate(s::IndexSet, state...) = iterate(s.coords, state...)
Base.eltype(::Type{IndexSet{N,T}}) where {N,T} = T
Base.getindex(s::IndexSet, i) = s.coords[i]
Base.in(c, s::IndexSet) = c in s.set
Base.collect(s::IndexSet) = copy(s.coords)
Base.:(==)(a::IndexSet, b::IndexSet) = a.axes == b.axes && a.coords == b.coords

axisnames(s::IndexSet) = s.axes

function _same_axes(a::IndexSet, b::IndexSet)
    a.axes == b.axes || throw(ArgumentError(
        "index sets have different axes: $(a.axes) and $(b.axes)"))
    return a.axes
end

# Left operand's order is kept, as for VariableGroup, so narrowing a pattern does not reshuffle it.
function Base.union(a::IndexSet, b::IndexSet...)
    for s in b
        _same_axes(a, s)
    end
    return IndexSet(a.axes, vcat(a.coords, (s.coords for s in b)...))
end

function Base.intersect(a::IndexSet, b::IndexSet...)
    for s in b
        _same_axes(a, s)
    end
    return IndexSet(a.axes, [c for c in a.coords if all(s -> c in s.set, b)])
end

function Base.setdiff(a::IndexSet, b::IndexSet...)
    for s in b
        _same_axes(a, s)
    end
    return IndexSet(a.axes, [c for c in a.coords if !any(s -> c in s.set, b)])
end

_axis_positions(s::IndexSet, names) = map(names) do n
    p = findfirst(==(n), s.axes)
    p === nothing && throw(ArgumentError("no axis named $n; this set has $(s.axes)"))
    p
end

"""
    select_axes(s::IndexSet, names::Symbol...) -> IndexSet

Project onto the named axes, dropping duplicates that the projection creates. `select_axes(pairs, :p)`
turns a product-industry pattern into the set of products that occur in it.
"""
function select_axes(s::IndexSet, names::Symbol...)
    pos = _axis_positions(s, names)
    return IndexSet(names, [Tuple(c[p] for p in pos) for c in s.coords])
end

"""
    group_by(s::IndexSet, names::Symbol...) -> Dict

Bucket coordinates by the named axes: the key is the projection onto those axes, the value is the
`IndexSet` of full coordinates sharing it.

This is what replaces summing over one index of a sparse variable. Rather than ranging over an axis
and guarding each access, take the coordinates that actually exist for the fixed part:

```julia
by_product = group_by(pairs, :p)
sum(use[k, t] for k in by_product[(:food,)])
```
"""
function group_by(s::IndexSet, names::Symbol...)
    pos = _axis_positions(s, names)
    buckets = Dict{Tuple,Vector{eltype(s.coords)}}()
    for c in s.coords
        key = Tuple(c[p] for p in pos)
        push!(get!(buckets, key, eltype(s.coords)[]), c)
    end
    return Dict(k => IndexSet(s.axes, v) for (k, v) in buckets)
end

function Base.show(io::IO, s::IndexSet)
    print(io, "IndexSet", s.axes, " with ", length(s), " coordinate", length(s) == 1 ? "" : "s")
end
