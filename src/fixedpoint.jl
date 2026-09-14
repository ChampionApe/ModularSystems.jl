# Iterating coupled models to a fixed point.
#
# Soft-linking two models needs almost nothing from this package. Passing a value across is
# `dest[v] = src[w]` — a read of one dataset and a write to another — and `Dataset` already refuses a
# variable belonging to the wrong model, so a mis-wired coupling raises rather than producing a
# plausible number. The models themselves are ordinary `Problem`s.
#
# What is worth having is the loop, and only because of how it fails. Every individual solve in a
# diverging soft link succeeds and reports success; the pair simply never settles. A loop that runs
# out of iterations and returns its last answer is a wrong answer delivered quietly, which is the one
# thing this package is consistent about refusing — so this raises instead.

"""
    ConvergenceReport

What an iteration to a fixed point did: whether it converged, how many passes it took, and how far
the exchanged quantities were still moving.

`change` and every entry of `history` are measured in **multiples of the tolerance**, not in the
units of any variable: the worst, over the exchanged cells, of `|new - old| / max(atol, rtol*|new|)`.
So `1.0` is exactly at tolerance, `converged` means `change <= 1`, and one number is comparable
across cells of wildly different magnitude and across runs with different tolerances. A dimensional
worst-gap would be dominated by the largest cell and would say nothing about the others.

`history` is the useful part when something goes wrong: falling and then flattening means the
tolerance is too tight.

`scale` records the largest absolute value among the exchanged cells at each pass. It exists because
`history` alone cannot tell divergence from stagnation — a link that grows geometrically has a
roughly *constant* change in tolerance units, since the tolerance grows with the value. Whether the
numbers themselves are running away is a question only the raw magnitudes answer.
"""
struct ConvergenceReport
    converged::Bool
    iterations::Int
    change::Float64
    history::Vector{Float64}
    scale::Vector{Float64}
end

function Base.show(io::IO, r::ConvergenceReport)
    print(io, "ConvergenceReport(", r.converged ? "converged" : "did NOT converge",
          " after ", r.iterations, r.iterations == 1 ? " pass" : " passes",
          ", change ", r.change, "× tolerance)")
end

"""
    ConvergenceFailure

Raised when [`fixed_point!`](@ref) runs out of passes. Carries the [`ConvergenceReport`](@ref), so
the history that shows *how* it failed is available to the caller.

This raises rather than returning an unconverged answer for the same reason a binding bound on a
square solve raises: every individual solve in a diverging soft link succeeds, so there is no other
symptom. A loop that quietly returns its last iterate hands back numbers that look like a solution
and are not.

!!! warning
    The datasets hold the last iterate when this is raised. Those numbers are not a solution and must
    not be used as one.
"""
struct ConvergenceFailure <: Exception
    report::ConvergenceReport
    maxiter::Int
end

function Base.showerror(io::IO, e::ConvergenceFailure)
    r = e.report
    print(io, "ConvergenceFailure: the coupled models did not settle in ", e.maxiter,
              " passes; the exchanged quantities were still moving by ", r.change,
              "× their tolerance.")
    # Only finite entries mean anything: a pass in which some cell had no value yet records `Inf`,
    # and comparing against that would call every failure a success at getting smaller.
    finite = filter(isfinite, r.history)
    if length(finite) >= 3
        recent = finite[max(1, end - 4):end]
        print(io, "\n  last changes: ", join((string(round(h, sigdigits = 3)) for h in recent), ", "))
    end
    # Diagnosed from the raw magnitudes, not from `history`: a geometrically diverging link has a
    # roughly constant change in tolerance units, because the tolerance grows with the value too.
    if length(r.scale) >= 3 && r.scale[end] > 10 * max(r.scale[1], 1e-12)
        print(io, "\n  The exchanged values grew from ", round(r.scale[1], sigdigits = 3), " to ",
                  round(r.scale[end], sigdigits = 3), ", so this is diverging rather than ",
                  "converging slowly. Damping helps only if the link is overshooting — if it is ",
                  "walking away in one direction, the coupling itself is wrong.")
    elseif length(finite) >= 3 && finite[end] > 0.1 * finite[max(1, end - 4)]
        print(io, "\n  The change is falling, but slowly. Try more passes, or damping.")
    end
    print(io, "\n  The datasets hold the last iterate, which is not a solution.",
              "\n  The report is on the exception as `.report`.")
end

# The exchanged cells are read before the step and again after it, so they must be cells whose value
# at the START of a pass determines that pass — the feedback. A quantity that is overwritten by a
# transfer before anything reads it carries no state between passes and does not belong here.
_read_cells(cells) = Union{Nothing,Float64}[d[v] for (d, v) in cells]

function _write_cells!(cells, values)
    for ((d, v), x) in zip(cells, values)
        d[v] = x
    end
    return cells
end

# Measured in multiples of the tolerance, so one number covers cells of any magnitude. A cell with no
# value yet is not "unchanged" — it is unknown — so the whole pass is reported as `Inf` and cannot
# count as converged.
function _change(new, old, atol, rtol)
    worst = 0.0
    for (a, b) in zip(new, old)
        (a === nothing || b === nothing) && return (Inf, false)
        worst = max(worst, abs(a - b) / max(atol, rtol * abs(a)))
    end
    return worst, worst <= 1
end

# Accepts `dataset => variable`, `dataset => container` and `dataset => group`, because all three are
# things a user will write and two of them used to be a MethodError from deep inside the loop.
function _cells(exchanged)
    out = Tuple{Dataset,JuMP.AbstractVariableRef}[]
    for p in exchanged
        d, v = first(p), last(p)
        d isa Dataset || throw(ArgumentError(
            "each entry of `exchanged` must be `dataset => variable`; got $(typeof(d)) on the left"))
        if v isa JuMP.AbstractVariableRef
            push!(out, (d, v))
        else
            for x in v
                x isa JuMP.AbstractVariableRef || throw(ArgumentError(
                    "`exchanged` must name variables; got $(typeof(x))"))
                push!(out, (d, x))
            end
        end
    end
    return out
end

"""
    fixed_point!(step!, exchanged; kwargs...) -> ConvergenceReport

Run `step!` repeatedly until the `exchanged` quantities stop moving, and **raise** if they do not.

This is how separate models are soft-linked: each pass solves them in turn, each consuming the
other's last answer, until neither changes what it hands over. `step!` takes no arguments and does
one pass — solving, and copying values between datasets.

`exchanged` lists the cells that carry information *between* passes, as `dataset => variable` pairs;
a variable container or a [`VariableGroup`](@ref) on the right stands for all its cells, and a single
pair may be passed on its own. These are the feedback: the cells whose value at the start of a pass
determines that pass. A quantity that a transfer overwrites before anything reads it carries no state
and does not belong here — it is transferred, but it is not what the loop is converging.

# Keywords
- `atol = 1e-8`, `rtol = 1e-6`: a pass has converged when every exchanged cell moved by no more than
  `max(atol, rtol * |value|)`. `atol` must be positive, since it is what keeps the test meaningful
  for a cell converging to zero.
- `maxiter = 100`: passes before giving up. Must be at least 1.
- `damping = 0.0`: in `[0, 1)`. Each exchanged cell is moved only `(1 - damping)` of the way to its
  new value, and the blend is written back so the next pass reads it.

  Damping fixes **overshoot**, not expansion. If a pass multiplies the error by `m`, damping makes
  that `(1 - damping)·m + damping`: for `m < -1` — two models leapfrogging each other, the change
  alternating in sign — some `damping` brings it inside `(-1, 1)`. For `m > 1`, where the link walks
  away in one direction, `(1 - damping)·m + damping > 1` for every admissible value, and no amount of
  damping helps. A link that diverges monotonically is miscoupled, not under-damped.

  Convergence is always judged on the **raw** values the models produced, never on the blend. Judging
  the blend would scale the measured change by `(1 - damping)` and so scale the effective tolerance
  by `1 / (1 - damping)`, which is unbounded — a heavily damped run would report convergence on a
  link that never settles.
- `raise = true`: set `false` to return an unconverged report instead of raising. Reach for it when
  you intend to inspect `history`, not to carry on with the numbers.

# Why it raises
Every individual solve in a diverging soft link converges and reports success — the models each
answer the question they were given perfectly well, and the pair never agrees. There is no other
symptom, so a loop that returns its last iterate after running out of passes hands back numbers that
look exactly like a solution. See [`ConvergenceFailure`](@ref).

!!! warning "What is in the datasets afterwards"
    On success, the exchanged cells hold the raw values of the converging pass. On failure — or with
    `raise = false` — they hold the last iterate, which is not a solution.

    Note also that only the `exchanged` cells are checked. A link whose `exchanged` list names a cell
    nothing writes will sit at its initial value and be reported as converged on the first pass; the
    list has to name the feedback, and nothing can verify that for you.

```julia
report = fixed_point!([macro_data => pe]; damping = 0.5) do
    solve!(macro_problem)
    for s in S
        energy_data[q[s]] = macro_data[E[s]]
    end
    solve!(energy_problem)
    macro_data[pe] = energy_data[price]
end
```
"""
function fixed_point!(step!, exchanged;
                      atol::Real = 1e-8,
                      rtol::Real = 1e-6,
                      maxiter::Integer = 100,
                      damping::Real = 0.0,
                      raise::Bool = true)
    cells = _cells(exchanged)
    isempty(cells) && throw(ArgumentError(
        "nothing to converge: `exchanged` is empty, so there is no way to tell whether the coupled " *
        "models have settled. List the cells that carry values between passes."))
    0 <= damping < 1 || throw(ArgumentError(
        "damping must be in [0, 1); got $damping. At 1 nothing ever updates."))
    maxiter >= 1 || throw(ArgumentError(
        "maxiter must be at least 1; got $maxiter, which would fail without running a single pass."))
    atol > 0 || throw(ArgumentError(
        "atol must be positive; got $atol. It is what keeps the test meaningful for a cell " *
        "converging to zero, where the relative part vanishes."))
    rtol >= 0 || throw(ArgumentError("rtol must not be negative; got $rtol."))

    for (d, v) in cells
        JuMP.owner_model(v) === JuMP.owner_model(d) || throw(ArgumentError(
            "$(JuMP.name(v)) does not belong to the dataset it is paired with"))
    end

    previous = _read_cells(cells)
    history = Float64[]
    scale = Float64[]
    change = Inf

    for iter in 1:maxiter
        step!()
        current = _read_cells(cells)

        if iter == 1
            for ((_, v), x) in zip(cells, current)
                x === nothing && throw(ArgumentError(
                    "$(JuMP.name(v)) still has no value after a pass, so nothing in `step!` writes " *
                    "it. A cell the loop watches but the step never sets cannot converge, and " *
                    "naming the wrong cell is the one wiring mistake this check can catch."))
            end
        end

        # Measured on the RAW iterate, before any blending. See the `damping` keyword.
        change, done = _change(current, previous, atol, rtol)
        push!(history, change)
        push!(scale, maximum(x -> x === nothing ? 0.0 : abs(x), current))

        # Returning before the blend leaves the values the models actually produced in the datasets,
        # rather than a blend no solve ever saw.
        done && return ConvergenceReport(true, iter, change, history, scale)

        if damping > 0 && !any(isnothing, previous) && !any(isnothing, current)
            current = [(1 - damping) * c + damping * p for (c, p) in zip(current, previous)]
            _write_cells!(cells, current)
        end
        previous = current
    end

    report = ConvergenceReport(false, maxiter, change, history, scale)
    raise && throw(ConvergenceFailure(report, maxiter))
    return report
end

fixed_point!(step!, exchanged::Pair; kwargs...) = fixed_point!(step!, (exchanged,); kwargs...)
