# Two separate models, soft-linked: solved in alternation until what they exchange stops moving.
#
# This is the shape that turns up when a macro model and a bottom-up energy model are maintained by
# different people, at different granularity, and neither can simply be pasted into the other. They
# are coupled by a handful of quantities instead: the macro model says how much energy each sector
# wants, the energy model prices it, and each answer changes the other's question.
#
# Everything here is deliberately written out by hand, with no package machinery beyond `Problem`,
# to find out what a soft link actually needs. Run with:
#
#     julia --project=docs examples/softLink.jl

using ModularSystems
using JuMP
using Ipopt
using Printf

const S = 1:2          # sectors
const BETA = 0.5       # labour exponent
const ALPHA = 0.3      # energy exponent

# BETA + ALPHA < 1 on purpose. Under constant returns this model has no interior solution: output
# cancels out of the two first-order conditions, leaving 1 = A[s] * (BETA/w)^BETA * (ALPHA/pe)^ALPHA,
# which two sectors with different A[s] facing one wage and one energy price cannot both satisfy.
# `assert_solvable` passes on that version and the solve collapses onto the variable bounds, which is
# the documented limit of a structural check: it says the incidence pattern admits a solution order,
# not that the numbers do.

opts = SolveOptions(replace_nothing = 1.0)

# ---------------------------------------------------------------------------------------------
# The macro model: output from labour and energy, given an energy price it does not set
# ---------------------------------------------------------------------------------------------

macro_model = Model()
set_optimizer_factory!(macro_model, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))

@variable(macro_model, Y[S] >= 1e-6)      # output
@variable(macro_model, L[S] >= 1e-6)      # labour
@variable(macro_model, E[S] >= 1e-6)      # energy demanded
@variable(macro_model, w >= 1e-6)         # wage
@variable(macro_model, pe >= 1e-6)        # energy price        <- from the energy model
@variable(macro_model, A[S])              # productivity        (exogenous)
@variable(macro_model, Lbar)              # labour supply       (exogenous)

macro_block = @block macro_model begin
    @square
    Y[s in S],  Y[s] == A[s] * L[s]^BETA * E[s]^ALPHA
    E[s in S],  pe * E[s] == ALPHA * Y[s]
    L[s in S],  w * L[s] == BETA * Y[s]
    w,          sum(L[s] for s in S) == Lbar
end

macro_data = Dataset(macro_model)
macro_data[A] = [1.0, 1.2]
macro_data[Lbar] = 100.0
macro_data[pe] = 1.0                      # the initial guess the loop starts from

macro_problem = Problem(macro_block, macro_data; options = opts)

# ---------------------------------------------------------------------------------------------
# The energy model: a price that rises with total demand
# ---------------------------------------------------------------------------------------------
#
# A separate JuMP model, with its own variables. Nothing connects the two except the values passed
# between their datasets — which is the whole point of a soft link, and also why nothing in the
# package can check the coupling for you.

energy_model = Model()
set_optimizer_factory!(energy_model, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))

@variable(energy_model, q[S] >= 1e-6)     # energy delivered per sector  <- from the macro model
@variable(energy_model, total >= 1e-6)    # total energy
@variable(energy_model, price >= 1e-6)    # the price it charges
@variable(energy_model, base)             # baseline cost       (exogenous)
@variable(energy_model, slope)            # cost slope          (exogenous)

energy_block = @block energy_model begin
    @square
    total,  total == sum(q[s] for s in S)
    price,  price == base + slope * total
end

energy_data = Dataset(energy_model)
energy_data[base] = 0.5
energy_data[slope] = 0.02
energy_data[q] = [10.0, 10.0]             # a starting guess, replaced on the first pass

energy_problem = Problem(energy_block, energy_data; options = opts)

# ---------------------------------------------------------------------------------------------
# The link
# ---------------------------------------------------------------------------------------------
#
# Passing values across needs no machinery: `energy_data[q[s]] = macro_data[E[s]]` is a read of one
# dataset and a write to another, and a Dataset refuses a variable from the wrong model, so a
# mis-wired coupling raises instead of producing a plausible number.
#
# One pass of the loop: solve the macro model at the current energy price, hand its demand to the
# energy model, solve that, hand the price back.

function pass!()
    solve!(macro_problem)
    for s in S
        energy_data[q[s]] = macro_data[E[s]]
    end
    solve!(energy_problem)
    macro_data[pe] = energy_data[price]
    return nothing
end

# `pe` is the only cell listed as exchanged, and that is not an omission. It is the *feedback*: its
# value at the start of a pass is what determines that pass. `q[s]` is overwritten by the transfer
# before the energy model reads it, so it carries nothing between passes — it is transferred, but it
# is not what the loop is converging.
exchanged = [macro_data => pe]

energy_demand() = sum(macro_data[E[s]] for s in S)

println("=== a gently sloped supply curve: the link settles on its own ===")
report = fixed_point!(pass!, exchanged)
println(report)
@printf("  energy price             %10.6f\n", macro_data[pe])
@printf("  demanded by the macro    %10.6f\n", energy_demand())
@printf("  supplied by the energy   %10.6f\n", energy_data[total])
@printf("  the two models disagree by %.3e\n", abs(energy_demand() - energy_data[total]))

# ---------------------------------------------------------------------------------------------
# When it does not settle
# ---------------------------------------------------------------------------------------------
#
# A steeper supply curve makes the two models overshoot each other: each answers the other's last
# answer and the pair oscillates. Every individual solve still converges and reports success — there
# is no symptom anywhere except that the exchanged price never stops moving. That is exactly why the
# loop raises rather than handing back its last iterate.

println("\n=== a steep supply curve: the same link will not settle ===")
energy_data[slope] = 0.3
macro_data[pe] = 1.0
try
    fixed_point!(pass!, exchanged; maxiter = 8)
    println("  (it converged, unexpectedly)")
catch e
    e isa ConvergenceFailure || rethrow()
    println("  raised, as it should have:")
    for line in split(sprint(showerror, e), '\n')
        println("    ", line)
    end
end

# Damping moves each exchanged cell only part of the way to its new value, which is enough to stop
# two models overshooting each other. The blend is written back, so the next pass reads it.
println("\n=== the same steep link, damped ===")
macro_data[pe] = 1.0
damped = fixed_point!(pass!, exchanged; damping = 0.5, maxiter = 200)
println(damped)
@printf("  energy price             %10.6f\n", macro_data[pe])
@printf("  the two models disagree by %.3e\n", abs(energy_demand() - energy_data[total]))

# A diverging link that is *inspected* rather than trusted: `raise = false` hands back the report so
# the history can be read. The numbers in the datasets are not a solution and must not be used.
println("\n=== reading the history of a failure instead of raising ===")
macro_data[pe] = 1.0
failed = fixed_point!(pass!, exchanged; maxiter = 6, raise = false)
println(failed)
println("  change per pass: ", join((string(round(h, sigdigits = 3)) for h in failed.history), ", "))
println("  Falling, but by a few percent a pass while still of order one — so this link is not")
println("  diverging, it is oscillating its way in far too slowly to be left alone. Damping above")
println("  reached the same fixed point in 6 passes. That distinction is what the history is for.")
