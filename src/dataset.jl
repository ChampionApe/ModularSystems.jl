# Dataset: values, bounds and solve metadata for one scenario over a model.

"""
    SolveMetadata

What a solve reports about itself, held per dataset. Every field is `nothing` until a solve writes it.
"""
mutable struct SolveMetadata
    termination_status::Any
    objective_value::Union{Nothing,Float64}
    solve_time::Union{Nothing,Float64}
end

SolveMetadata() = SolveMetadata(nothing, nothing, nothing)

Base.copy(m::SolveMetadata) = SolveMetadata(m.termination_status, m.objective_value, m.solve_time)

"""
    Dataset{T}(model)
    Dataset(model)          # T = Float64

Values for one scenario over a JuMP model, plus the problem bounds and solve metadata that belong
with it. Layers share one key space — the variable [`slot`](@ref) — so a bound and a value for the
same variable are found the same way.

| layer | storage | why |
|---|---|---|
| values | dense vector | nearly every variable has one |
| `lower`, `upper` | sparse dicts | bounds are genuinely rare |
| metadata | one record | per dataset, not per variable |

Bounds here are *problem* bounds, meaningful only for a variable a block treats as unknown. Bounds
intrinsic to a variable (`K ≥ 0`) belong on the JuMP variable instead.

Model metadata is shared through [`ModelLayout`](@ref), so scenarios over one model are cheap:
`copy` duplicates the layers, never the model information.

Arithmetic (`+`, `-`, `*`, `/`, and their broadcast forms) operates on values and returns a
**value-only** dataset: bounds and solve metadata are dropped, since a ratio of two scenarios is not
itself a scenario. `copy` is what preserves every layer. A cell missing from either operand is
missing from the result rather than being read as zero.
"""
struct Dataset{T}
    layout::ModelLayout
    values::Vector{Union{T,Nothing}}
    lower::Dict{Int,Float64}
    upper::Dict{Int,Float64}
    meta::SolveMetadata
end

function Dataset{T}(model::JuMP.AbstractModel) where {T}
    l = layout(model)
    # Variables may have been declared since the layout was created. Sizing correctly here costs one
    # O(num_variables) scan per dataset and saves repeated growth on the write path.
    note_slot!(l, highest_slot(model))
    return Dataset{T}(
        l,
        Vector{Union{T,Nothing}}(nothing, l.nslots),
        Dict{Int,Float64}(),
        Dict{Int,Float64}(),
        SolveMetadata(),
    )
end

Dataset(model::JuMP.AbstractModel) = Dataset{Float64}(model)

JuMP.owner_model(d::Dataset) = d.layout.model

Base.copy(d::Dataset{T}) where {T} =
    Dataset{T}(d.layout, copy(d.values), copy(d.lower), copy(d.upper), copy(d.meta))

Base.length(d::Dataset) = length(d.values)

# ---------------------------------------------------------------------------------------------
# Slot resolution
# ---------------------------------------------------------------------------------------------

# Every access goes through here: it is the one place that checks the variable belongs to this
# dataset's model. A VariableRef from another model would otherwise read a slot that happens to
# exist and return a plausible wrong number.
@inline function _slot(d::Dataset, v::JuMP.AbstractVariableRef)
    JuMP.owner_model(v) === d.layout.model ||
        throw(ArgumentError("variable $(JuMP.name(v)) belongs to a different model than this Dataset"))
    return slot(v)
end

# Grow to fit a variable declared after this dataset was built. Amortised O(1), and no rescan of the
# model: the slot itself says how far to grow.
@inline function _ensure!(d::Dataset, s::Int)
    old = length(d.values)
    if s > old
        note_slot!(d.layout, s)
        resize!(d.values, s)
        # resize! leaves the new slots undefined, not `nothing`. The old length must be captured
        # before the resize, or this fills the whole vector and erases every existing value.
        fill!(view(d.values, (old + 1):s), nothing)
    end
    return s
end

# ---------------------------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------------------------

function Base.getindex(d::Dataset, v::JuMP.AbstractVariableRef)
    s = _slot(d, v)
    return s <= length(d.values) ? d.values[s] : nothing
end

function Base.setindex!(d::Dataset{T}, value, v::JuMP.AbstractVariableRef) where {T}
    s = _ensure!(d, _slot(d, v))
    d.values[s] = value === nothing ? nothing : convert(T, value)
    return value
end

Base.getindex(d::Dataset, c::AbstractArray{<:JuMP.AbstractVariableRef}) = map(v -> d[v], c)

function Base.setindex!(d::Dataset, value::Number, c::AbstractArray{<:JuMP.AbstractVariableRef})
    for v in c
        d[v] = value
    end
    return value
end

function Base.setindex!(d::Dataset, values, c::AbstractArray{<:JuMP.AbstractVariableRef})
    length(values) == length(c) || throw(DimensionMismatch(
        "got $(length(values)) values for $(length(c)) variables"))
    for (v, x) in zip(c, values)
        d[v] = x
    end
    return values
end

Base.haskey(d::Dataset, v::JuMP.AbstractVariableRef) = d[v] !== nothing

# ---------------------------------------------------------------------------------------------
# Bounds
# ---------------------------------------------------------------------------------------------

"""
    set_bounds!(d::Dataset, v; lower = nothing, upper = nothing)

Set problem bounds on a variable. A keyword left `nothing` leaves that side untouched; use
[`clear_bounds!`](@ref) to remove one. Raises if the resulting interval is empty, since an empty
interval otherwise surfaces much later as an unexplained infeasibility.
"""
function set_bounds!(d::Dataset, v::JuMP.AbstractVariableRef; lower = nothing, upper = nothing)
    s = _ensure!(d, _slot(d, v))
    lo = lower === nothing ? get(d.lower, s, nothing) : convert(Float64, lower)
    hi = upper === nothing ? get(d.upper, s, nothing) : convert(Float64, upper)
    if lo !== nothing && hi !== nothing && lo > hi
        throw(ArgumentError("empty bound interval [$lo, $hi] for $(JuMP.name(v))"))
    end
    lo === nothing || (d.lower[s] = lo)
    hi === nothing || (d.upper[s] = hi)
    return (lo, hi)
end

"""
    bounds(d::Dataset, v) -> (lower, upper)

The problem bounds on a variable, each `nothing` when unset. These are the dataset's bounds only;
the effective bound at solve time is their intersection with the variable's intrinsic JuMP bounds.
"""
function bounds(d::Dataset, v::JuMP.AbstractVariableRef)
    s = _slot(d, v)
    return (get(d.lower, s, nothing), get(d.upper, s, nothing))
end

"""
    clear_bounds!(d::Dataset, v)

Remove both problem bounds from a variable. Intrinsic JuMP bounds are untouched.
"""
function clear_bounds!(d::Dataset, v::JuMP.AbstractVariableRef)
    s = _slot(d, v)
    delete!(d.lower, s)
    delete!(d.upper, s)
    return nothing
end

# ---------------------------------------------------------------------------------------------
# Arithmetic
# ---------------------------------------------------------------------------------------------

# A Dataset is a broadcast scalar, so `scenario ./ baseline .- 1` dispatches to the two-argument
# methods below rather than iterating cells. That is what makes an elementwise expression over whole
# scenarios cost one pass and allocate one result.
Base.broadcastable(d::Dataset) = Ref(d)

# `nothing` propagates: a cell missing from either operand is missing from the result, rather than
# being silently read as zero.
@inline _apply(f, a, b) = (a === nothing || b === nothing) ? nothing : f(a, b)

function _elementwise(f, a::Dataset{T}, b::Dataset) where {T}
    a.layout === b.layout ||
        throw(ArgumentError("datasets belong to different models"))
    n = max(length(a.values), length(b.values))
    out = Vector{Union{T,Nothing}}(nothing, n)
    @inbounds for s in 1:n
        av = s <= length(a.values) ? a.values[s] : nothing
        bv = s <= length(b.values) ? b.values[s] : nothing
        out[s] = _apply(f, av, bv)
    end
    return Dataset{T}(a.layout, out, Dict{Int,Float64}(), Dict{Int,Float64}(), SolveMetadata())
end

function _elementwise(f, a::Dataset{T}, x::Number) where {T}
    out = Vector{Union{T,Nothing}}(nothing, length(a.values))
    @inbounds for s in eachindex(a.values)
        out[s] = _apply(f, a.values[s], x)
    end
    return Dataset{T}(a.layout, out, Dict{Int,Float64}(), Dict{Int,Float64}(), SolveMetadata())
end

function _elementwise(f, x::Number, a::Dataset{T}) where {T}
    out = Vector{Union{T,Nothing}}(nothing, length(a.values))
    @inbounds for s in eachindex(a.values)
        out[s] = _apply(f, x, a.values[s])
    end
    return Dataset{T}(a.layout, out, Dict{Int,Float64}(), Dict{Int,Float64}(), SolveMetadata())
end

# Elementwise over values, returning a value-only dataset: bounds and solve metadata are dropped,
# because a ratio or difference of two scenarios is not itself a scenario and their bounds would not
# describe it. `copy` is what carries every layer.
for op in (:+, :-, :*, :/)
    @eval begin
        Base.$op(a::Dataset, b::Dataset) = _elementwise($op, a, b)
        Base.$op(a::Dataset, x::Number) = _elementwise($op, a, x)
        Base.$op(x::Number, a::Dataset) = _elementwise($op, x, a)
    end
end

# ---------------------------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------------------------

function Base.show(io::IO, d::Dataset{T}) where {T}
    set = count(!isnothing, d.values)
    print(io, "Dataset{", T, "}(", set, "/", length(d.values), " values")
    isempty(d.lower) && isempty(d.upper) ||
        print(io, ", ", length(union(keys(d.lower), keys(d.upper))), " bounded")
    d.meta.termination_status === nothing || print(io, ", ", d.meta.termination_status)
    print(io, ")")
end
