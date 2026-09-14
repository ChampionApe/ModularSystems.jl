# A model with several states, and the structure that names them.
#
# The point of this example is not the economics — it is a two-sector growth model with an energy
# satellite, kept as small as it can be while still having the shape that matters. The point is that
# a real model is never solved one way. This one is solved five:
#
#   :static_calibration    steady-state closure, solve for productivity from observed output
#   :dynamic_calibration   accumulation closure, solve for a productivity path
#   :baseline_unlinked     run it forward with energy costs held exogenous
#   :baseline_linked       run it forward with the energy module determining those costs
#   :shock_linked          the same, with less energy available
#
# Two things are worth watching. Linking a module in is **block composition** — `core + energy` —
# not a flag, and calibration is **the same equations with a different unknown set** — a `swap`, not
# a second model. Both fall out of the package's primitives rather than needing machinery.
#
# Run with:
#
#     julia --project=docs examples/multiModeModel.jl

using ModularSystems
using JuMP
using Ipopt

const J = 1:2          # sectors
const P = 1:6          # periods
const DELTA = 0.1      # depreciation
const ALPHA = 0.3      # capital share

model = Model()
set_optimizer_factory!(model, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))

# Lower bounds here are *intrinsic*: capital and labour are positive in every problem this model
# appears in, and a Cobb-Douglas function is undefined without that. Problem bounds — "in this
# calibration keep rho within these limits" — would go on the Dataset instead.
@variable(model, Y[J, P] >= 1e-3)        # output
@variable(model, K[J, P] >= 1e-3)        # capital
@variable(model, L[J, P] >= 1e-3)        # labour
@variable(model, I[J, P])                # investment
@variable(model, rho[J, P] >= 1e-3)      # productivity          (calibrated)
@variable(model, w[P] >= 1e-3)           # wage
@variable(model, ecost[J, P])            # energy cost           (exogenous when unlinked)
@variable(model, E[J, P] >= 1e-3)        # energy use
@variable(model, pE[P] >= 1e-3)          # energy price
@variable(model, Lbar[P])                # labour supply         (exogenous)
@variable(model, Ebar[P])                # energy supply         (exogenous)
@variable(model, K0[J])                  # initial capital       (exogenous)

# ---------------------------------------------------------------------------------------------
# The blocks
# ---------------------------------------------------------------------------------------------

# Production, factor demand and the labour market. Note `ecost`: the core does not say where energy
# costs come from, only that they reduce what is available to invest. That is the seam the energy
# module attaches to.
core = @block model begin
    Y[j in J, t in P],  Y[j, t] == rho[j, t] * K[j, t]^ALPHA * L[j, t]^(1 - ALPHA)
    L[j in J, t in P],  L[j, t] == (1 - ALPHA) * Y[j, t] / w[t]
    w[t in P],          sum(L[j, t] for j in J) == Lbar[t]
    I[j in J, t in P],  I[j, t] == 0.2 * (Y[j, t] - ecost[j, t])
end

# The dynamic closure: capital comes from the period before.
accumulation = @block model begin
    K[j in J, t in P],  K[j, t] == (t == 1 ? K0[j] : (1 - DELTA) * K[j, t - 1] + I[j, t - 1])
end

# The static closure: the same variable determined by a steady state instead. Swapping the closure
# is swapping which block is added, and the core does not know which one it got.
steady = @block model begin
    K[j in J, t in P],  I[j, t] == DELTA * K[j, t]
end

# The energy satellite, and the one equation that couples it to the core.
energy = @block model begin
    E[j in J, t in P],  E[j, t] == 0.1 * Y[j, t] / pE[t]^0.5
    pE[t in P],         sum(E[j, t] for j in J) == Ebar[t]
end

coupling = @block model begin
    ecost[j in J, t in P],  ecost[j, t] == pE[t] * E[j, t]
end

# Composition is `+`. A linked run is three blocks; an unlinked run is one fewer, with `ecost` left
# exogenous and read from the data.
dynamic_unlinked = core + accumulation
dynamic_linked = core + accumulation + energy + coupling
static_linked = core + steady + energy + coupling

# Calibration is the same equations solved for the parameter instead of the outcome.
static_calibration = swap(static_linked, @group(rho[j in J, t in P]) => @group(Y[j in J, t in P]))
dynamic_calibration = swap(dynamic_linked, @group(rho[j in J, t in P]) => @group(Y[j in J, t in P]))

# ---------------------------------------------------------------------------------------------
# The data
# ---------------------------------------------------------------------------------------------

observed = Dataset(model)
observed[Lbar] = [100.0 + 2.0 * t for t in P]
observed[Ebar] = [40.0 for _ in P]
observed[K0] = [150.0, 100.0]
for j in J, t in P
    observed[Y[j, t]] = (j == 1 ? 120.0 : 80.0) * (1 + 0.02 * (t - 1))   # the observation
end

opts = SolveOptions(replace_nothing = 1.0)

# ---------------------------------------------------------------------------------------------
# The states this model can be solved in
# ---------------------------------------------------------------------------------------------

spec = ModelSpec(model)
register!(spec, :static_calibration, Problem(static_calibration, observed; options = opts);
          about = "steady-state closure; productivity from observed output")
register!(spec, :dynamic_calibration, Problem(dynamic_calibration, observed; options = opts);
          about = "accumulation closure; productivity path from observed output and K0")
register!(spec, :baseline_unlinked, Problem(dynamic_unlinked, observed; options = opts);
          about = "forward run, energy costs held exogenous")
register!(spec, :baseline_linked, Problem(dynamic_linked, observed; options = opts);
          about = "forward run, energy module determining costs")

println("=== what this model can do ===")
show(stdout, MIME("text/plain"), spec)

# Every mode is structurally sound before any of them is run. That is the block-only check: it
# cannot go stale, because a block is a value.
assert_solvable(spec)
println("\nall modes are structurally sound")

# Readiness says something different, and more useful: which modes could run *now*. Nobody declared
# that the calibrations come first — they are first because the baselines need a parameter that is
# not in the data until a calibration has produced it.
println("\n=== which modes are ready to run against the observed data ===")
println("  ready now: ", ready(spec))
for (name, x) in diagnose(spec)
    isclean(x) && continue
    println("  :", rpad(name, 21), "needs ",
            join((JuMP.name(v) for v in Iterators.take(x.missing_values, 3)), ", "), " …")
end

# ---------------------------------------------------------------------------------------------
# Running the workflow
# ---------------------------------------------------------------------------------------------

row(d, x, t) = [round(d[x[j, t]], digits = 3) for j in J]

# The two calibrations answer different questions, which is why both exist. The static one asks what
# capital would be if the economy sat still at the observed output; the dynamic one takes the
# observed initial capital seriously and asks what productivity path is consistent with the observed
# output given it. Only the second is a starting point for a baseline, because only the second used
# the actual K0 — running a baseline off the static answer would quietly start it somewhere else.
println("\n=== static calibration: the steady state behind the observation ===")
steady_state = solve(spec, :static_calibration)   # non-mutating, so it cannot contaminate the data
println("  productivity, period 1:  ", row(steady_state, rho, 1))
println("  steady-state capital:    ", row(steady_state, K, 1))

println("\n=== dynamic calibration: the productivity path, given the observed K0 ===")
solve!(spec, :dynamic_calibration)                # in place: this is what the baseline reads
println("  productivity, period 1:  ", row(observed, rho, 1))
println("  productivity, period 6:  ", row(observed, rho, 6))
println("  capital, period 1:       ", row(observed, K, 1), "   (= K0, as it must be)")

# With rho in the data the baseline is ready, and it must reproduce the observation: the same
# equations, run the other way round. If it does not, the calibration did not do its job.
println("\n=== baseline, linked ===")
baseline = solve(spec, :baseline_linked)
println("  output, period 1:        ", row(baseline, Y, 1))
println("  output, period 6:        ", row(baseline, Y, 6))
reproduced = maximum(abs(baseline[Y[j, t]] - observed[Y[j, t]]) for j in J, t in P)
println("  worst gap vs observed:   ", round(reproduced, sigdigits = 3))
@assert reproduced < 1e-6 "the baseline did not reproduce the observation it was calibrated to"
println("  largest subsystem:       ", largest_subsystem(decompose(dynamic_linked)),
        " of ", length(unknowns(dynamic_linked)), " unknowns")

# A shock is a mode derived from another: same block, same options, different data, started from the
# baseline solution. Deriving rather than rebuilding is what keeps the two in step.
shocked = copy(baseline)
shocked[Ebar] = [30.0 for _ in P]        # a third less energy
register!(spec, :shock_linked, Problem(spec[:baseline_linked]; data = shocked, start = baseline);
          about = "a third less energy, module linked")

println("\n=== shock: a third less energy, linked ===")
shock = solve(spec, :shock_linked)
multipliers = shock ./ baseline .- 1
println("  energy price, period 1:  ", round(shock[pE[1]], digits = 4),
        "  (", round(100 * multipliers[pE[1]], digits = 1), "%)")
println("  output multipliers, t=6: ", row(multipliers .* 100, Y, 6), " %")

# The same shock with the energy module NOT linked in: energy costs stay at their baseline level, so
# the shock cannot reach the core at all. The difference between the two numbers is the whole content
# of "linked", and it is one block in a sum.
# Derived from the registered mode rather than rebuilt, so the options and the block cannot drift
# apart from the baseline this is meant to be comparable with.
register!(spec, :shock_unlinked,
          Problem(spec[:baseline_unlinked]; data = copy(shocked), start = baseline);
          about = "the same shock, module not linked")
println("\n=== the same shock, unlinked ===")
shock_u = solve(spec, :shock_unlinked)
mult_u = shock_u ./ baseline .- 1
println("  output multipliers, t=6: ", row(mult_u .* 100, Y, 6), " %")
println("  (zero, because with the energy module out, nothing carries the shock to the core)")

println("\n=== the workflow, as the spec sees it ===")
show(stdout, MIME("text/plain"), spec)
println()
