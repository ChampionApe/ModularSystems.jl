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

What an iteration to a fixed point did: whether it converged, how many passes it took, the final
change in the exchanged quantities, and the change at every pass.

`history` is the useful part when something goes wrong. Falling and then flattening means the
tolerance is too tight; growing means the coupling is unstable and wants damping; alternating in sign
means it is overshooting, which damping also fixes.
"""
struct ConvergenceReport
    converged::Bool
    iterations::Int
    change::Float64
    history::Vector{Float64}
end

function Base.show(io::IO, r::ConvergenceReport)
    print(io, "ConvergenceReport(", r.converged ? "converged" : "did NOT converge",
          " after ", r.iterations, r.iterations == 1 ? " pass" : " passes",
          ", change ", r.change, ")")
end

"""
    ConvergenceFailure

Raised when [`fixed_point!`](@ref) runs out of passes. Carries the [`ConvergenceReport`](@ref), so
the history that shows *how* it failed is available to the caller.

This raises rather than returning an unconverged answer for the same reason a binding bound on a
square solve raises: every individual solve in a diverging soft link succeeds, so there is no other
symptom. A loop that quietly returns its last iterate hands back numbers that look like a solution
and are not.
"""
struct ConvergenceFailure <: Exception
    report::ConvergenceReport
    maxiter::Int
end

function Base.showerror(io::IO, e::ConvergenceFailure)
    r = e.report
    print(io, "ConvergenceFailure: the coupled models did not settle in ", e.maxiter,
              " passes; the exchanged quantities were still moving by ", r.change, ".")
    if length(r.history) >= 3
        recent = r.history[max(1, end - 4):end]
        print(io, "\n  last changes: ", join((string(round(h, sigdigits = 3)) for h in recent), ", "))
        if r.history[end] > r.history[1]
            print(io, "\n  The change is growing, so this is diverging rather than converging ",
                      "slowly. Damping helps only if the link is overshooting — if it is walking ",
                      "away in one direction, the coupling itself is wrong.")
        elseif length(r.history) > 5 && r.history[end] > 0.1 * r.history[end - 4]
            print(io, "\n  The change is falling, but slowly. Try more passes, or damping.")
        end
    end
    print(io, "\n  The report is on the exception as `.report`.")
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

function _change(new, old, atol, rtol)
    worst = 0.0
    done = true
    for (a, b) in zip(new, old)
        (a === nothing || b === nothing) && (done = false; continue)
        gap = abs(a - b)
        worst = max(worst, gap)
        gap <= max(atol, rtol * abs(a)) || (done = false)
    end
    return worst, done
end

"""
    fixed_point!(step!, exchanged; kwargs...) -> ConvergenceReport

Run `step!` repeatedly until the `exchanged` quantities stop moving, and **raise** if they do not.

This is how separate models are soft-linked: each pass solves them in turn, each consuming the
other's last answer, until neither changes what it hands over. `step!` takes no arguments and does
one pass — solving, and copying values between datasets.

`exchanged` lists the cells that carry information *between* passes, as `dataset => variable` pairs.
These are the feedback: the cells whose value at the start of a pass determines that pass. A quantity
that a transfer overwrites before anything reads it carries no state and does not belong here — it is
transferred, but it is not what the loop is converging.

# Keywords
- `atol = 1e-8`, `rtol = 1e-6`: a pass has converged when every exchanged cell moved by no more than
  `max(atol, rtol * |value|)`.
- `maxiter = 100`: passes before giving up.
- `damping = 0.0`: in `[0, 1)`. Each exchanged cell is moved only `(1 - damping)` of the way to its
  new value, and the blend is written back so the next pass reads it.

  Damping fixes **overshoot**, not expansion. If a pass multiplies the error by `m`, damping makes
  that `(1 - damping)·m + damping`: for `m < -1` — two models leapfrogging each other, the change
  alternating in sign — some `damping` brings it inside `(-1, 1)`. For `m > 1`, where the link walks
  away in one direction, `(1 - damping)·m + damping > 1` for every admissible value, and no amount of
  damping helps. A link that diverges monotonically is miscoupled, not under-damped.
- `raise = true`: set `false` to return an unconverged report instead of raising. Reach for it when
  you intend to inspect `history`, not to carry on with the numbers.

# Why it raises
Every individual solve in a diverging soft link converges and reports success — the models each
answer the question they were given perfectly well, and the pair never agrees. There is no other
symptom, so a loop that returns its last iterate after running out of passes hands back numbers that
look exactly like a solution. See [`ConvergenceFailure`](@ref).

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
    cells = [(first(p), last(p)) for p in exchanged]
    isempty(cells) && throw(ArgumentError(
        "nothing to converge: `exchanged` is empty, so there is no way to tell whether the coupled " *
        "models have settled. List the cells that carry values between passes."))
    0 <= damping < 1 || throw(ArgumentError(
        "damping must be in [0, 1); got $damping. At 1 nothing ever updates."))

    for (d, v) in cells
        JuMP.owner_model(v) === JuMP.owner_model(d) || throw(ArgumentError(
            "$(JuMP.name(v)) does not belong to the dataset it is paired with"))
    end

    previous = _read_cells(cells)
    history = Float64[]
    change = Inf

    for iter in 1:maxiter
        step!()
        current = _read_cells(cells)

        if damping > 0 && !any(isnothing, previous)
            current = [(1 - damping) * c + damping * p for (c, p) in zip(current, previous)]
            _write_cells!(cells, current)
        end

        change, done = _change(current, previous, atol, rtol)
        push!(history, change)
        previous = current

        if done
            return ConvergenceReport(true, iter, change, history)
        end
    end

    report = ConvergenceReport(false, maxiter, change, history)
    raise && throw(ConvergenceFailure(report, maxiter))
    return report
end
