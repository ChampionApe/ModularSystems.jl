# Solving a block against a dataset.

const _OPTIMIZER_KEY = :ModularSystems_optimizer

"""
    set_optimizer_factory!(model, optimizer) -> model

Remember the optimizer a solve should use for this model, so [`solve`](@ref) need not be told each
time. A solve builds its own intermediate model, so it cannot inherit the optimizer attached to the
model the variables live in.
"""
function set_optimizer_factory!(model::JuMP.AbstractModel, optimizer)
    model.ext[_OPTIMIZER_KEY] = optimizer
    return model
end

optimizer_factory(model::JuMP.AbstractModel) = get(model.ext, _OPTIMIZER_KEY, nothing)

"""
    BindingBoundError

Raised when a bound is active at the solution of a **square** system. The system then did not
determine the answer — the problem has silently become a complementarity problem, and the solver
still reports success. On a block with an objective an active bound is normal and is not raised.

`variables` lists the offending variables paired with the bound they sit on.
"""
struct BindingBoundError <: Exception
    variables::Vector{Tuple{VariableRef,Float64}}
end

function Base.showerror(io::IO, e::BindingBoundError)
    print(io, "BindingBoundError: a bound is active at the solution of a square system, so the ",
              "system did not determine the answer:")
    for (v, b) in e.variables
        print(io, "\n  ", JuMP.name(v), " sits on its bound ", b)
    end
    print(io, "\nRelax the bound, or pass check_binding_bounds = false if this is intended.")
end

# ---------------------------------------------------------------------------------------------
# Expression substitution
# ---------------------------------------------------------------------------------------------

# Branches on whether a variable is an unknown, never on whether it is paired: the pairing plays no
# part in building or solving the system. An unknown maps to its counterpart in the intermediate
# model; anything else is replaced by its value, so exogenous variables never reach the solver.
_substitute(x::Number, ::Dict, ::Dataset) = x

function _exogenous_value(d::Dataset, v::VariableRef)
    val = d[v]
    val === nothing && throw(ArgumentError(
        "no value for exogenous variable $(JuMP.name(v)); set it in the dataset or make it an unknown"))
    return val
end

_substitute(v::VariableRef, map::Dict, d::Dataset) =
    haskey(map, v) ? map[v] : _exogenous_value(d, v)

function _substitute(e::JuMP.GenericAffExpr, map::Dict, d::Dataset)
    out = JuMP.AffExpr(e.constant)
    for (v, coef) in e.terms
        if haskey(map, v)
            JuMP.add_to_expression!(out, coef, map[v])
        else
            JuMP.add_to_expression!(out, coef * _exogenous_value(d, v))
        end
    end
    return out
end

function _substitute(e::JuMP.GenericQuadExpr, map::Dict, d::Dataset)
    acc = _substitute(e.aff, map, d)
    for (pair, coef) in e.terms
        acc = acc + coef * _substitute(pair.a, map, d) * _substitute(pair.b, map, d)
    end
    return acc
end

function _substitute(e::JuMP.GenericNonlinearExpr, map::Dict, d::Dataset)
    args = Any[_substitute(arg, map, d) for arg in e.args]
    return JuMP.GenericNonlinearExpr{VariableRef}(e.head, args)
end

# ---------------------------------------------------------------------------------------------
# Bounds
# ---------------------------------------------------------------------------------------------

# The effective bound is the intersection of the variable's intrinsic JuMP bound with the dataset's
# problem bound. An empty intersection is raised here rather than left to surface as an unexplained
# infeasibility several seconds later.
function _effective_bounds(d::Dataset, v::VariableRef)
    lo = JuMP.has_lower_bound(v) ? JuMP.lower_bound(v) : nothing
    hi = JuMP.has_upper_bound(v) ? JuMP.upper_bound(v) : nothing
    dlo, dhi = bounds(d, v)
    dlo === nothing || (lo = lo === nothing ? dlo : max(lo, dlo))
    dhi === nothing || (hi = hi === nothing ? dhi : min(hi, dhi))
    if lo !== nothing && hi !== nothing && lo > hi
        throw(ArgumentError(
            "empty effective bound interval [$lo, $hi] for $(JuMP.name(v)): the dataset's problem " *
            "bound and the variable's intrinsic bound do not overlap"))
    end
    return (lo, hi)
end

# ---------------------------------------------------------------------------------------------
# Building the intermediate model
# ---------------------------------------------------------------------------------------------

function _build_model(b::Block, d::Dataset, o::SolveOptions; start_values)
    factory = o.optimizer === nothing ? optimizer_factory(b.model) : o.optimizer
    factory === nothing && throw(ArgumentError(
        "no optimizer for this model; call set_optimizer_factory!(model, Ipopt.Optimizer) or pass " *
        "optimizer = ... to solve"))

    sm = JuMP.Model(factory)
    JuMP.set_objective_sense(sm, MOI.FEASIBILITY_SENSE)
    # The intermediate model is ours, not the caller's, so it does not inherit their verbosity
    # setting and would otherwise flood stdout on every solve. Failures still raise, and the
    # termination status is recorded on the dataset.
    o.silent && JuMP.set_silent(sm)

    unk = unknowns(b)
    map = sizehint!(Dict{VariableRef,VariableRef}(), length(unk))
    for v in unk
        nv = JuMP.@variable(sm)
        map[v] = nv
        JuMP.set_name(nv, JuMP.name(v))

        lo, hi = _effective_bounds(d, v)
        lo === nothing || JuMP.set_lower_bound(nv, lo)
        hi === nothing || JuMP.set_upper_bound(nv, hi)

        start = start_values === nothing ? nothing : start_values[v]
        start === nothing && (start = d[v])
        start === nothing && (start = o.replace_nothing)
        start === nothing || isnan(start) || JuMP.set_start_value(nv, start)
    end

    if b.objective !== nothing
        sense, func = b.objective
        JuMP.set_objective(sm, sense, _substitute(func, map, d))
    end

    n = 0
    for c in b.constraints
        is_solved(c) || continue
        n += 1
        func = _substitute(jump_func(c), map, d)
        con = JuMP.@constraint(sm, func in moi_set(c))
        # A paired constraint is named after the variable it determines, which is what keeps solver
        # output legible. An unpaired one is named by its position among solved constraints: a solver
        # name has to be short and stable, so the source location that identifies it lives on the
        # constraint instead and is reported by `diagnose` and by a failed check.
        JuMP.set_name(con, is_paired(c) ? JuMP.name(c.determines) : "constraint[$n]")
    end

    return sm, map
end

# ---------------------------------------------------------------------------------------------
# Solving
# ---------------------------------------------------------------------------------------------

"""
    solve!(b::Block, d::Dataset; kwargs...) -> Dataset

Solve a block against a dataset, writing the solution into `d`. See [`solve`](@ref) for the form that
leaves `d` untouched.

Exogenous variables — anything not an unknown of the block — are substituted from the dataset, so the
intermediate model holds only the unknowns. Bounds applied to an unknown are the intersection of its
intrinsic JuMP bounds with the dataset's problem bounds.

# Keywords
- `options::SolveOptions`: how the solve is run. Every field of [`SolveOptions`](@ref) may also be
  passed here directly as a keyword, which overrides `options` for this call — so
  `solve!(b, d; silent = false)` and `solve!(b, d; options = SolveOptions(o; silent = false))` mean
  the same thing, and the settings can be named once and reused.
- `start_values::Dataset`: starting points, falling back to `d`'s own values. Data rather than a
  setting, which is why it is a keyword of its own and not a field of `SolveOptions`.

!!! note
    `optimizer` names the solver for **this solve only** and does not attach it to the model.
    [`set_optimizer_factory!`](@ref) is what sets a model's default.

A block carrying an objective is solved as an optimization problem: the objective is substituted
from the dataset like any other expression and attached to the same intermediate model, so the two
paths differ only at the tail. `meta.objective_value` records its value.
"""
function solve!(
    b::Block,
    d::Dataset;
    options::SolveOptions = _DEFAULT_OPTIONS,
    start_values::Union{Nothing,Dataset} = nothing,
    kwargs...,
)
    o = isempty(kwargs) ? options : SolveOptions(options; kwargs...)
    validate(b)
    sm, map = _build_model(b, d, o; start_values = start_values)

    JuMP.optimize!(sm)
    JuMP.assert_is_solved_and_feasible(sm)

    for (v, sv) in map
        d[v] = JuMP.value(sv)
    end

    d.meta.termination_status = JuMP.termination_status(sm)
    d.meta.solve_time = JuMP.solve_time(sm)
    d.meta.objective_value = b.objective === nothing ? nothing : JuMP.objective_value(sm)

    # Always computed, so the optimization path gets the report for free; only raised on the square
    # path, where an active bound means the system did not determine the answer.
    d.meta.binding_bounds = _binding_bounds(b, d, o.bound_tolerance)
    if o.check_binding_bounds && issquare(b) && !isempty(d.meta.binding_bounds)
        throw(BindingBoundError(d.meta.binding_bounds))
    end
    o.run_checks && assert_checks(b, d; atol = o.check_atol, rtol = o.check_rtol)
    return d
end

"""
    solve(b::Block, d::Dataset; kwargs...) -> Dataset

Solve a block against a dataset, returning a solved copy and leaving `d` untouched. Takes the same
keywords as [`solve!`](@ref), whose docstring describes them.
"""
function solve(b::Block, d::Dataset; kwargs...)
    out = copy(d)
    solve!(b, out; kwargs...)
    return out
end

# An interior-point solver does not land exactly on a bound: Ipopt relaxes bounds by roughly 1e-8 and
# stops slightly outside. A tolerance tighter than that relaxation detects nothing at all, which is
# why the default is 1e-6 rather than solver-precision. Scaled by the bound so it holds at any
# magnitude. See notes/crossCuttingFindings.md #1.
_on_bound(val, bound, tol) = abs(val - bound) <= max(tol, tol * abs(bound))

function _binding_bounds(b::Block, d::Dataset, tol::Real)
    hits = Tuple{VariableRef,Float64}[]
    for v in unknowns(b)
        val = d[v]
        val === nothing && continue
        lo, hi = _effective_bounds(d, v)
        lo === nothing || !_on_bound(val, lo, tol) || push!(hits, (v, float(lo)))
        hi === nothing || !_on_bound(val, hi, tol) || push!(hits, (v, float(hi)))
    end
    return hits
end

# ---------------------------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------------------------

"""
    CheckFailure

Raised when a `@check` constraint does not hold at the solution. `failures` pairs each failing
constraint's message with the gap by which it missed.
"""
struct CheckFailure <: Exception
    failures::Vector{Tuple{String,Float64}}
end

# A check with no message is identified by where it was written, which is the only handle an unpaired
# constraint has.
_check_label(c::Constraint) =
    !isempty(c.message) ? c.message :
    c.source !== nothing ? "check at " * c.source : "(unnamed check)" 

function Base.showerror(io::IO, e::CheckFailure)
    print(io, "CheckFailure: ", length(e.failures),
              length(e.failures) == 1 ? " check did not hold at the solution:" :
                                        " checks did not hold at the solution:")
    for (msg, gap) in e.failures
        print(io, "\n  ", msg, " — off by ", gap)
    end
end

# A check is evaluated, not solved. JuMP's own `value(f, expr)` walks any expression type — affine,
# quadratic or nonlinear — given a lookup from variable to number, so there is no second evaluator to
# keep in step with the substitution path.
function _check_gap(c::Constraint, d::Dataset)
    value = JuMP.value(v -> _exogenous_value(d, v), jump_func(c))
    set = moi_set(c)
    if set isa MOI.EqualTo
        return abs(value - set.value), abs(set.value)
    elseif set isa MOI.LessThan
        return max(0.0, value - set.upper), abs(set.upper)
    elseif set isa MOI.GreaterThan
        return max(0.0, set.lower - value), abs(set.lower)
    end
    throw(ArgumentError("cannot evaluate a check against $(typeof(set))"))
end

"""
    assert_checks(b::Block, d::Dataset; atol = 1e-6, rtol = 1e-8) -> Dataset

Evaluate every `@check` in a block against a dataset, raising [`CheckFailure`](@ref) if any misses by
more than `max(atol, rtol * scale)`. Called by [`solve`](@ref); call it directly to test a dataset
that was loaded or edited rather than solved.
"""
function assert_checks(b::Block, d::Dataset; atol::Real = 1e-6, rtol::Real = 1e-8)
    failures = Tuple{String,Float64}[]
    for c in b.constraints
        is_solved(c) && continue
        gap, scale = _check_gap(c, d)
        gap <= max(atol, rtol * scale) || push!(failures, (_check_label(c), gap))
    end
    isempty(failures) || throw(CheckFailure(failures))
    return d
end
