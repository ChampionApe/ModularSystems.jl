# Solve settings as a value, separate from the data they are applied to.

"""
    SolveStrategy

How a block is handed to the solver. Both strategies compute the same answer; they differ in the work
done to reach it and in how readily they converge.

Subtypes are [`Monolithic`](@ref) and [`BlockTriangular`](@ref).
"""
abstract type SolveStrategy end

"""
    Monolithic()

Solve every unknown at once in a single intermediate model. The default, and the only strategy that
applies to a block carrying an objective.
"""
struct Monolithic <: SolveStrategy end

"""
    BlockTriangular()

Solve the block one subsystem at a time, in the order [`decompose`](@ref) finds, each subsystem
reading the results of the ones before it out of the dataset.

!!! warning "This is a convergence fallback, not a speed optimisation"
    It is **slower** than [`Monolithic`](@ref) — measured at 2× to 110× slower across model sizes
    from 125 to 21,500 unknowns. Entering an interior-point solver has a setup cost independent of
    problem size, and a one- or two-variable subsystem cannot amortise it: Ipopt's summed solve
    time over 400 tiny subsystems was 0.99 s against 0.004 s for the same system solved at once.

    What it buys is convergence. Each subsystem starts from the results of the ones before it,
    where a monolithic solve starts from whatever was supplied for everything at once. Over 70
    combinations of model shape and starting point, this converged 62 times against 58. Reach for
    it when a solve will not converge, not to make one faster.

    Tables in `archive/decompositionMeasurements.md`.

Requires a structurally sound square system. A block with an objective, one whose decomposition has
an over- or under-determined part, or one carrying a solved **inequality** — which determines nothing
and so belongs to no subsystem — raises rather than solving something adjacent to what was asked.
"""
struct BlockTriangular <: SolveStrategy end

"""
    SolveOptions(; kwargs...)
    SolveOptions(base::SolveOptions; kwargs...)

How a solve is run, as a value that can be named, reused and overridden. The second form derives
options from existing ones, changing only the fields named.

Settings only: `SolveOptions` carries nothing that belongs to a particular model, so one set of
options is reusable across models and scenarios. Starting values are a `Dataset` and therefore data,
which is why they are not here.

# Fields
- `optimizer`: optimizer factory for this solve. `nothing` falls back to the one attached to the
  model with [`set_optimizer_factory!`](@ref). Naming it here is what lets a calibration use a
  different solver, or different solver attributes, from the baseline it feeds.
- `replace_nothing`: starting point for an unknown with no value anywhere, or `nothing` to leave it
  to the solver.
- `check_binding_bounds`: on a square system, raise [`BindingBoundError`](@ref) if a bound is active
  at the solution.
- `bound_tolerance`: how close to a bound counts as sitting on it. Must not be tighter than the
  solver's own bound relaxation; see `notes/crossCuttingFindings.md` #1.
- `silent`: suppress solver output.
- `run_checks`, `check_atol`, `check_rtol`: evaluate `@check` constraints against the solution.
- `strategy::SolveStrategy`: [`Monolithic`](@ref) or [`BlockTriangular`](@ref). The answer does not
  depend on it, only the work done to reach it.

# Examples
```jldoctest
julia> base = SolveOptions(replace_nothing = 1.0);

julia> loud = SolveOptions(base; silent = false);

julia> loud.replace_nothing, loud.silent
(1.0, false)
```
"""
struct SolveOptions
    optimizer::Any
    replace_nothing::Union{Nothing,Float64}
    check_binding_bounds::Bool
    bound_tolerance::Float64
    silent::Bool
    run_checks::Bool
    check_atol::Float64
    check_rtol::Float64
    strategy::SolveStrategy
end

SolveOptions(;
    optimizer = nothing,
    replace_nothing = nothing,
    check_binding_bounds::Bool = true,
    bound_tolerance::Real = 1e-6,
    silent::Bool = true,
    run_checks::Bool = true,
    check_atol::Real = 1e-6,
    check_rtol::Real = 1e-8,
    strategy::SolveStrategy = Monolithic(),
) = SolveOptions(optimizer, replace_nothing, check_binding_bounds, bound_tolerance,
                 silent, run_checks, check_atol, check_rtol, strategy)

# Built by field name rather than by listing them, so adding a field cannot leave the derive
# constructor silently dropping it.
function SolveOptions(base::SolveOptions; kwargs...)
    unknown = setdiff(keys(kwargs), fieldnames(SolveOptions))
    isempty(unknown) || throw(ArgumentError(
        "SolveOptions has no field " * join(unknown, ", ") * "; the fields are " *
        join(fieldnames(SolveOptions), ", ")))
    return SolveOptions((get(kwargs, f, getfield(base, f)) for f in fieldnames(SolveOptions))...)
end

const _DEFAULT_OPTIONS = SolveOptions()

Base.:(==)(a::SolveOptions, b::SolveOptions) =
    all(getfield(a, f) == getfield(b, f) for f in fieldnames(SolveOptions))

# Shows what differs from the defaults. A settings object printed in full is unreadable, and the
# whole point of naming one is the handful of fields that are not standard.
function Base.show(io::IO, o::SolveOptions)
    print(io, "SolveOptions(")
    first = true
    for f in fieldnames(SolveOptions)
        v = getfield(o, f)
        v == getfield(_DEFAULT_OPTIONS, f) && continue
        first || print(io, ", ")
        first = false
        print(io, f, " = ", f === :optimizer ? "…" : repr(v))
    end
    first && print(io, "defaults")
    print(io, ")")
end
