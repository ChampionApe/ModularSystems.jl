# Solve settings as a value, separate from the data they are applied to.

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
) = SolveOptions(optimizer, replace_nothing, check_binding_bounds, bound_tolerance,
                 silent, run_checks, check_atol, check_rtol)

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
