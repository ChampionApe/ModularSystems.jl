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

function _build_model(b::Block, d::Dataset; start_values, replace_nothing, silent)
    factory = optimizer_factory(b.model)
    factory === nothing && throw(ArgumentError(
        "no optimizer for this model; call set_optimizer_factory!(model, Ipopt.Optimizer) or pass " *
        "optimizer = ... to solve"))

    sm = JuMP.Model(factory)
    JuMP.set_objective_sense(sm, MOI.FEASIBILITY_SENSE)
    # The intermediate model is ours, not the caller's, so it does not inherit their verbosity
    # setting and would otherwise flood stdout on every solve. Failures still raise, and the
    # termination status is recorded on the dataset.
    silent && JuMP.set_silent(sm)

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
        start === nothing && (start = replace_nothing)
        start === nothing || isnan(start) || JuMP.set_start_value(nv, start)
    end

    n = 0
    for c in b.constraints
        is_solved(c) || continue
        n += 1
        func = _substitute(jump_func(c), map, d)
        con = JuMP.@constraint(sm, func in moi_set(c))
        # Naming a constraint after the variable it determines is what keeps solver output legible.
        # The fallback for an unpaired constraint is positional and provisional — see notes/TODO.md
        # C11, which is the decision about what unpaired constraints should actually be called.
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
- `optimizer`: optimizer factory, defaulting to the one stored by [`set_optimizer_factory!`](@ref).
- `start_values::Dataset`: starting points, falling back to `d`'s own values.
- `replace_nothing::Number`: starting point for an unknown with no value anywhere. Useful in early
  calibration, when a variable exists but has no data yet.
- `check_binding_bounds::Bool = true`: on a square system, raise [`BindingBoundError`](@ref) if a
  bound is active at the solution.
- `bound_tolerance::Real = 1e-8`: how close to a bound counts as sitting on it.
- `silent::Bool = true`: suppress solver output. The intermediate model is built here rather than by
  the caller, so it does not inherit their verbosity setting; pass `false` to see the solver's log.
- `run_checks::Bool = true`, `check_atol`, `check_rtol`: evaluate the block's `@check` constraints
  against the solution, raising [`CheckFailure`](@ref) on a miss.

Only square systems are solved so far; a block carrying an objective raises.
"""
function solve!(
    b::Block,
    d::Dataset;
    optimizer = nothing,
    start_values::Union{Nothing,Dataset} = nothing,
    replace_nothing::Union{Nothing,Number} = nothing,
    check_binding_bounds::Bool = true,
    bound_tolerance::Real = 1e-8,
    silent::Bool = true,
    run_checks::Bool = true,
    check_atol::Real = 1e-6,
    check_rtol::Real = 1e-8,
)
    validate(b)
    b.objective === nothing || throw(ArgumentError(
        "this block carries an objective; the optimization path is not implemented yet"))

    optimizer === nothing || set_optimizer_factory!(b.model, optimizer)
    sm, map = _build_model(
        b, d; start_values = start_values, replace_nothing = replace_nothing, silent = silent)

    JuMP.optimize!(sm)
    JuMP.assert_is_solved_and_feasible(sm)

    for (v, sv) in map
        d[v] = JuMP.value(sv)
    end

    d.meta.termination_status = JuMP.termination_status(sm)
    d.meta.solve_time = JuMP.solve_time(sm)

    if check_binding_bounds && issquare(b)
        _assert_no_binding_bounds(b, d, bound_tolerance)
    end
    run_checks && assert_checks(b, d; atol = check_atol, rtol = check_rtol)
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

function _assert_no_binding_bounds(b::Block, d::Dataset, tol::Real)
    hits = Tuple{VariableRef,Float64}[]
    for v in unknowns(b)
        val = d[v]
        val === nothing && continue
        lo, hi = _effective_bounds(d, v)
        lo === nothing || abs(val - lo) > tol || push!(hits, (v, float(lo)))
        hi === nothing || abs(val - hi) > tol || push!(hits, (v, float(hi)))
    end
    isempty(hits) || throw(BindingBoundError(hits))
    return nothing
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

function Base.showerror(io::IO, e::CheckFailure)
    print(io, "CheckFailure: ", length(e.failures),
              length(e.failures) == 1 ? " check did not hold at the solution:" :
                                        " checks did not hold at the solution:")
    for (msg, gap) in e.failures
        print(io, "\n  ", isempty(msg) ? "(unnamed check)" : msg, " — off by ", gap)
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
        gap <= max(atol, rtol * scale) || push!(failures, (c.message, gap))
    end
    isempty(failures) || throw(CheckFailure(failures))
    return d
end
