# The states a model can be solved in, named and held together.
#
# A model is rarely solved one way. It is calibrated, then run as a baseline, then shocked; its
# satellite modules are sometimes linked in and sometimes held exogenous. Each of those is a
# [`Problem`](@ref) — a block, a dataset, options — and the point of collecting them is that the set
# is then enumerable: it can be listed, diagnosed all at once, and printed as an answer to "what can
# this model do?".

"""
    ModelSpec(model)

The named states a model can be solved in: a registry of [`Problem`](@ref)s over one JuMP model.

Modes are kept in registration order, so listing them is deterministic and reads like the workflow
they describe. Every mode must be over the same model as the spec, which is the one thing that
cannot be checked later.

The registry is a value like everything else here: registering returns the spec, modes are looked up
by name, and nothing anywhere holds a "current mode". A mode you are working with is a variable in
your own code, not hidden state in the model.

```julia
spec = ModelSpec(model)
register!(spec, :calibration, Problem(calibration_block, observed))
register!(spec, :baseline,    Problem(behavioural, calibrated))
register!(spec, :shock,       Problem(spec[:baseline]; data = shocked))

modes(spec)              # [:calibration, :baseline, :shock]
solve!(spec, :baseline)  # solve one of them
diagnose(spec)           # check all of them at once
```
"""
struct ModelSpec
    model::JuMP.AbstractModel
    names::Vector{Symbol}
    problems::Dict{Symbol,Problem}
end

ModelSpec(model::JuMP.AbstractModel) = ModelSpec(model, Symbol[], Dict{Symbol,Problem}())

JuMP.owner_model(s::ModelSpec) = s.model

"""
    register!(spec::ModelSpec, name::Symbol, p::Problem) -> ModelSpec
    register!(spec::ModelSpec, name::Symbol, block, data; kwargs...) -> ModelSpec

Add a named mode. The second form builds the [`Problem`](@ref) in place, taking its keywords.

Raises on a name already registered rather than replacing it: overwriting a mode silently is how a
workflow ends up running something other than what its script says. Remove it first with
[`unregister!`](@ref) if replacing is what you mean.
"""
function register!(s::ModelSpec, name::Symbol, p::Problem)
    haskey(s.problems, name) && throw(ArgumentError(
        "mode :$name is already registered; use unregister! first if you mean to replace it"))
    p.block.model === s.model || throw(ArgumentError(
        "mode :$name is over a different model than this spec"))
    push!(s.names, name)
    s.problems[name] = p
    return s
end

register!(s::ModelSpec, name::Symbol, block::Block, data::Dataset; kwargs...) =
    register!(s, name, Problem(block, data; kwargs...))

"""
    unregister!(spec::ModelSpec, name::Symbol) -> ModelSpec

Remove a mode. Raises if it is not there, so a typo does not pass quietly.
"""
function unregister!(s::ModelSpec, name::Symbol)
    haskey(s.problems, name) || throw(KeyError(name))
    delete!(s.problems, name)
    deleteat!(s.names, findfirst(==(name), s.names))
    return s
end

"""
    modes(spec::ModelSpec) -> Vector{Symbol}

The registered mode names, in registration order.
"""
modes(s::ModelSpec) = copy(s.names)

Base.getindex(s::ModelSpec, name::Symbol) = s.problems[name]
Base.haskey(s::ModelSpec, name::Symbol) = haskey(s.problems, name)
Base.length(s::ModelSpec) = length(s.names)
Base.keys(s::ModelSpec) = modes(s)

"""
    solve(spec::ModelSpec, name::Symbol; kwargs...) -> Dataset
    solve!(spec::ModelSpec, name::Symbol; kwargs...) -> Dataset

Solve one registered mode. `solve` returns a solved copy; `solve!` writes into that mode's dataset,
which is what lets the next mode start from it.
"""
solve(s::ModelSpec, name::Symbol; kwargs...) = solve(s[name]; kwargs...)
solve!(s::ModelSpec, name::Symbol; kwargs...) = solve!(s[name]; kwargs...)

"""
    diagnose(spec::ModelSpec) -> Vector{Pair{Symbol,Diagnosis}}

Diagnose every mode against its own data, in registration order. The reason to have the registry at
all: one call says whether the whole workflow is sound, instead of one call per mode and a list kept
by hand.
"""
diagnose(s::ModelSpec) = [name => diagnose(s[name]) for name in s.names]

"""
    assert_solvable(spec::ModelSpec) -> ModelSpec

Raise [`StructuralError`](@ref) on the first mode that is not structurally sound, naming it.
"""
function assert_solvable(s::ModelSpec)
    for name in s.names
        x = diagnose(s[name].block)
        isclean(x) || throw(StructuralError(x))
    end
    return s
end

# ---------------------------------------------------------------------------------------------
# Inferred dependencies
# ---------------------------------------------------------------------------------------------

"""
    dependencies(spec::ModelSpec) -> Vector{Pair{Symbol,Symbol}}

Which modes feed which, inferred from the datasets they share rather than declared.

A mode that starts from another mode's dataset is downstream of it, so `a => b` means "b starts from
a's data". This needs no declaration syntax because the sharing is already there in the objects: a
workflow is chained by handing one mode's dataset to the next, and object identity records that.

Only `start` is read as a dependency edge, never `data`. Two modes writing into the same dataset —
which is the ordinary calibrate-then-solve-in-place idiom — say nothing about which runs first, and
treating that as an edge produces a cycle rather than an ordering.

!!! warning
    This is inference, not a contract. It sees a dependency only where one mode's `start` is
    *the same object* as another's `data`; a workflow that copies between stages is invisible to it.
"""
function dependencies(s::ModelSpec)
    edges = Pair{Symbol,Symbol}[]
    for downstream in s.names
        st = s[downstream].start
        st === nothing && continue
        for upstream in s.names
            upstream === downstream && continue
            s[upstream].data === st && push!(edges, upstream => downstream)
        end
    end
    return edges
end

function Base.show(io::IO, s::ModelSpec)
    print(io, "ModelSpec(", length(s.names), " mode", length(s.names) == 1 ? "" : "s")
    isempty(s.names) || print(io, ": ", join((":" * String(n) for n in s.names), ", "))
    print(io, ")")
end

function Base.show(io::IO, ::MIME"text/plain", s::ModelSpec)
    println(io, "ModelSpec over ", length(s.names), " mode", length(s.names) == 1 ? "" : "s")
    for name in s.names
        p = s.problems[name]
        x = diagnose(p.block)
        println(io, "  :", name, rpad("", max(1, 20 - length(String(name)))),
                isclean(x) ? "ok  " : "PROBLEM  ", _shape_summary(p, x))
    end
    edges = dependencies(s)
    if !isempty(edges)
        println(io, "  dependencies (inferred from shared datasets):")
        for (a, b) in edges
            println(io, "    :", a, " -> :", b)
        end
    end
    return nothing
end

function _shape_summary(p::Problem, x::Diagnosis)
    parts = [string(x.unknowns, " unknowns")]
    x.has_objective && push!(parts, "objective")
    x.has_objective || push!(parts, string("largest ", x.largest))
    p.start === nothing || push!(parts, "started")
    return join(parts, ", ")
end
