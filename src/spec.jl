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
    about::Dict{Symbol,String}
end

ModelSpec(model::JuMP.AbstractModel) =
    ModelSpec(model, Symbol[], Dict{Symbol,Problem}(), Dict{Symbol,String}())

JuMP.owner_model(s::ModelSpec) = s.model

"""
    register!(spec::ModelSpec, name::Symbol, p::Problem; about = "") -> ModelSpec
    register!(spec::ModelSpec, name::Symbol, block, data; about = "", kwargs...) -> ModelSpec

Add a named mode. The second form builds the [`Problem`](@ref) in place, taking its keywords.

`about` is one line of prose, shown when the spec is displayed. Worth writing: composition through
`+` is not recoverable from the result, so two modes that answer completely different questions —
a steady-state calibration and a dynamic one, say — otherwise print as two identical rows of counts.
The name is the identity; this is the explanation.

Raises on a name already registered rather than replacing it: overwriting a mode silently is how a
workflow ends up running something other than what its script says. Remove it first with
[`unregister!`](@ref) if replacing is what you mean.
"""
function register!(s::ModelSpec, name::Symbol, p::Problem; about::AbstractString = "")
    haskey(s.problems, name) && throw(ArgumentError(
        "mode :$name is already registered; use unregister! first if you mean to replace it"))
    p.block.model === s.model || throw(ArgumentError(
        "mode :$name is over a different model than this spec"))
    push!(s.names, name)
    s.problems[name] = p
    isempty(about) || (s.about[name] = String(about))
    return s
end

register!(s::ModelSpec, name::Symbol, block::Block, data::Dataset;
          about::AbstractString = "", kwargs...) =
    register!(s, name, Problem(block, data; kwargs...); about = about)

"""
    unregister!(spec::ModelSpec, name::Symbol) -> ModelSpec

Remove a mode. Raises if it is not there, so a typo does not pass quietly.
"""
function unregister!(s::ModelSpec, name::Symbol)
    haskey(s.problems, name) || throw(KeyError(name))
    delete!(s.problems, name)
    delete!(s.about, name)
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

Raise [`StructuralError`](@ref) on the first mode that is not structurally sound, naming it. Naming
it is the whole point: a diagnosis on its own does not say which of a dozen modes it came from.
"""
function assert_solvable(s::ModelSpec)
    for name in s.names
        x = diagnose(s[name].block)
        isclean(x) || throw(StructuralError(x, "mode :$name"))
    end
    return s
end

# ---------------------------------------------------------------------------------------------
# Readiness
# ---------------------------------------------------------------------------------------------
#
# This is where a dependency graph would go, and deliberately does not. An experiment inferred the
# edges from modes sharing a dataset object; `examples/multiModeModel.jl` showed why that cannot
# work, since `solve` is non-mutating and hands back a *fresh* dataset, breaking the identity link
# the inference needs. Declaring the edges instead was rejected for a better reason than difficulty:
# a declared order is a second statement of something the equations already imply, and it can drift
# from them. Readiness cannot — it is read off the data as it actually stands.

"""
    ready(spec::ModelSpec) -> Vector{Symbol}

The modes that could be solved right now, in registration order: those whose block is sound *and*
whose data has every exogenous value the block needs.

This is what a workflow's ordering looks like when it is derived rather than declared. A calibration
is ready before the baseline that consumes its output, because the baseline's parameters are still
unset — nobody has to say so, and nobody can say it wrongly. Re-ask after each solve and the order
falls out.

```julia
ready(spec)                  # [:calibration]
solve!(spec, :calibration)
ready(spec)                  # [:calibration, :baseline]
```

Use [`diagnose`](@ref) on the spec for *why* a mode is not ready.
"""
ready(s::ModelSpec) = Symbol[name for name in s.names if isclean(diagnose(s[name]))]

function Base.show(io::IO, s::ModelSpec)
    print(io, "ModelSpec(", length(s.names), " mode", length(s.names) == 1 ? "" : "s")
    isempty(s.names) || print(io, ": ", join((":" * String(n) for n in s.names), ", "))
    print(io, ")")
end

# Diagnosed against the DATA, not against the block alone. The block-only check is true of every
# mode at all times, so a column reporting it says "ok" beside a mode that cannot run — which is
# exactly what a reader will take it to mean is not the case.
function Base.show(io::IO, ::MIME"text/plain", s::ModelSpec)
    println(io, "ModelSpec over ", length(s.names), " mode", length(s.names) == 1 ? "" : "s")
    width = isempty(s.names) ? 0 : maximum(length(String(n)) for n in s.names)
    for name in s.names
        p = s.problems[name]
        x = diagnose(p)
        print(io, "  :", rpad(String(name), width + 2), rpad(_readiness(x), 34))
        note = get(s.about, name, "")
        println(io, isempty(note) ? _shape_summary(p, x) : note)
    end
    return nothing
end

function _readiness(x::Diagnosis)
    isclean(x) && return "ready"
    if !isempty(x.missing_values)
        names = join((JuMP.name(v) for v in Iterators.take(x.missing_values, 2)), ", ")
        more = length(x.missing_values) - 2
        return "needs " * names * (more > 0 ? " (+$more)" : "")
    end
    return "NOT SOLVABLE"
end

function _shape_summary(p::Problem, x::Diagnosis)
    parts = [string(x.unknowns, " unknowns")]
    x.has_objective && push!(parts, "objective")
    p.start === nothing || push!(parts, "started")
    return join(parts, ", ")
end
