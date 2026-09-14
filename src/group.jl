# VariableGroup: a named-by-binding, composable collection of variable cells.

"""
    VariableGroup(items...)
    VariableGroup(model, items...)

An ordered, duplicate-free collection of variable *cells*. `items` may be variable references,
containers of them (arrays, JuMP containers), other groups, or any iterable mixing those; they are
flattened in the order given.

Groups are what the interface takes wherever a set of variables is meant — declaring unknowns,
setting bounds, fixing and freeing. Elements are cells (`μ[1]`, `K[2030]`), not containers, because
every one of those call sites selects cells.

A group is a **value frozen at construction**, not a query re-evaluated against the model: membership
that could change between declaring unknowns and solving would be a wrong answer rather than an
error. All members must belong to one model, checked here.

Pass `model` explicitly when the group may be empty; otherwise the model is taken from the members.

Supports `∪`, `∩`, `setdiff`, `in`, `length`, `iterate` and `getindex`. It is deliberately **not** an
`AbstractVector` — that would invite `push!`, `similar` and array broadcasting, none of which a frozen
set of cells should promise.
"""
struct VariableGroup
    model::JuMP.AbstractModel
    vars::Vector{VariableRef}
    set::Set{VariableRef}

    # Declared explicitly to suppress Julia's generated converting constructor, which would otherwise
    # claim any three-argument call — so `VariableGroup(x, y[1], y[2])` tried to convert a
    # VariableRef into a model instead of reaching the varargs method below.
    function VariableGroup(
        model::JuMP.AbstractModel,
        vars::Vector{VariableRef},
        set::Set{VariableRef},
    )
        return new(model, vars, set)
    end
end

_collect_vars!(out, v::JuMP.AbstractVariableRef) = (push!(out, v); out)
_collect_vars!(out, g::VariableGroup) = (append!(out, g.vars); out)
function _collect_vars!(out, itr)
    for item in itr
        _collect_vars!(out, item)
    end
    return out
end

function VariableGroup(model::JuMP.AbstractModel, items...)
    raw = VariableRef[]
    _collect_vars!(raw, items)
    return _build_group(model, raw)
end

function VariableGroup(items...)
    raw = VariableRef[]
    _collect_vars!(raw, items)
    isempty(raw) && throw(ArgumentError(
        "cannot infer the model of an empty VariableGroup; pass the model as the first argument"))
    return _build_group(JuMP.owner_model(first(raw)), raw)
end

function _build_group(model::JuMP.AbstractModel, raw::Vector{VariableRef})
    vars = VariableRef[]
    set = Set{VariableRef}()
    for v in raw
        JuMP.owner_model(v) === model || throw(ArgumentError(
            "variable $(JuMP.name(v)) belongs to a different model than the rest of the group"))
        if !(v in set)
            push!(set, v)
            push!(vars, v)
        end
    end
    return VariableGroup(model, vars, set)
end

JuMP.owner_model(g::VariableGroup) = g.model

Base.length(g::VariableGroup) = length(g.vars)
Base.isempty(g::VariableGroup) = isempty(g.vars)
Base.iterate(g::VariableGroup, state...) = iterate(g.vars, state...)
Base.eltype(::Type{VariableGroup}) = VariableRef
Base.getindex(g::VariableGroup, i) = g.vars[i]
Base.in(v::JuMP.AbstractVariableRef, g::VariableGroup) = v in g.set
Base.collect(g::VariableGroup) = copy(g.vars)
Base.:(==)(a::VariableGroup, b::VariableGroup) = a.model === b.model && a.vars == b.vars

function _same_model(a::VariableGroup, b::VariableGroup)
    a.model === b.model ||
        throw(ArgumentError("groups belong to different models"))
    return a.model
end

# Set operations keep the left operand's ordering, so a group built from an ordered selection stays
# in that order after being narrowed — which is what makes a swap's pairing predictable.
function Base.union(a::VariableGroup, b::VariableGroup...)
    m = a.model
    for g in b
        _same_model(a, g)
    end
    return _build_group(m, vcat(a.vars, (g.vars for g in b)...))
end

function Base.intersect(a::VariableGroup, b::VariableGroup...)
    m = a.model
    for g in b
        _same_model(a, g)
    end
    return _build_group(m, [v for v in a.vars if all(g -> v in g.set, b)])
end

function Base.setdiff(a::VariableGroup, b::VariableGroup...)
    m = a.model
    for g in b
        _same_model(a, g)
    end
    return _build_group(m, [v for v in a.vars if !any(g -> v in g.set, b)])
end

function Base.show(io::IO, g::VariableGroup)
    print(io, "VariableGroup(", length(g), " variable", length(g) == 1 ? "" : "s")
    if !isempty(g) && length(g) <= 6
        print(io, ": ", join((JuMP.name(v) for v in g.vars), ", "))
    end
    print(io, ")")
end

# ---------------------------------------------------------------------------------------------
# Dataset integration
# ---------------------------------------------------------------------------------------------

Base.getindex(d::Dataset, g::VariableGroup) = [d[v] for v in g]

function Base.setindex!(d::Dataset, value::Number, g::VariableGroup)
    for v in g
        d[v] = value
    end
    return value
end

function Base.setindex!(d::Dataset, values, g::VariableGroup)
    length(values) == length(g) || throw(DimensionMismatch(
        "got $(length(values)) values for $(length(g)) variables"))
    for (v, x) in zip(g, values)
        d[v] = x
    end
    return values
end

"""
    set_bounds!(d::Dataset, g::VariableGroup; lower = nothing, upper = nothing)

Set the same problem bounds on every variable in a group. Cell-by-cell bound setting is unusable at
model scale, so this is the form that gets used.
"""
function set_bounds!(d::Dataset, g::VariableGroup; lower = nothing, upper = nothing)
    for v in g
        set_bounds!(d, v; lower = lower, upper = upper)
    end
    return (lower, upper)
end

"""
    clear_bounds!(d::Dataset, g::VariableGroup)

Remove problem bounds from every variable in a group.
"""
function clear_bounds!(d::Dataset, g::VariableGroup)
    for v in g
        clear_bounds!(d, v)
    end
    return nothing
end
