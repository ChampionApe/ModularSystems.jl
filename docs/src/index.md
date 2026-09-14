# ModularSystems.jl

A Julia package for **modular systems of equations**: constraints collected into composable blocks,
each constraint optionally paired with the variable it determines. Square systems — as many equations
as unknowns — are the common case and get a dedicated solver, but they are not a requirement: a block
may carry an objective and be solved as an optimization problem instead.

!!! warning "Early days"
    Square systems solve; the optimization path does not yet. See [Design](@ref) for what has been
    decided and what has not. Nothing in the API is stable.

## Installation

```julia
julia> using Pkg; Pkg.develop(url = "https://github.com/ChampionApe/ModularSystems.jl")
```

You also need a solver. Anything JuMP supports will do; the examples here use Ipopt. (Ipopt prints a
licence banner from its C library on the first solve, before any verbosity setting applies — the `sb`
option below is what suppresses it.)

## A first model

Two labour types, each with a productivity and a workforce. Each equation is written next to the
variable it determines.

```jldoctest quickstart
julia> using ModularSystems, JuMP, Ipopt

julia> model = Model();

julia> set_optimizer_factory!(model, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"));

julia> J = 1:2;

julia> @variable(model, L[J]);   # labour demand

julia> @variable(model, w[J]);   # wage

julia> @variable(model, N[J]);   # workforce

julia> @variable(model, rho[J]); # productivity

julia> block = @block model begin
           @square
           L[j in J], L[j] == rho[j] * N[j]
           w[j in J], w[j] == L[j] / 100
       end;

julia> issquare(block)
true

julia> degrees_of_freedom(block)
0
```

`@square` is an assertion: the block claims to be square and is checked as it is built. Drop it and
nothing is checked — squareness is a property here, not a requirement.

Values live in a [`Dataset`](@ref), one per scenario:

```jldoctest quickstart
julia> data = Dataset(model);

julia> data[N] = [3200.0, 500.0];

julia> data[rho] = [1.0, 2.0];

julia> baseline = solve(block, data; replace_nothing = 1.0);

julia> round(baseline[L[1]], digits = 2)
3200.0

julia> round(baseline[w[2]], digits = 2)
10.0
```

`solve` returns a new dataset and leaves `data` alone; `solve!` writes in place. Anything the block
does not solve for — here `N` and `rho` — is substituted from the dataset as a number and never
reaches the solver.

A scenario is a copy with something changed, and scenarios compare with ordinary arithmetic:

```jldoctest quickstart
julia> scenario = copy(baseline);

julia> scenario[N] = [2700.0, 1000.0];

julia> scenario = solve(block, scenario; replace_nothing = 1.0);

julia> multipliers = scenario ./ baseline .- 1;

julia> round(multipliers[L[2]], digits = 4)
1.0
```

Arithmetic works on values and returns a value-only dataset: bounds and solve metadata are dropped,
because a ratio of two scenarios is not itself a scenario.

## When the system is not square

A block may instead carry an objective, and is then solved as an optimization problem. Nothing else
changes: the same macro, the same dataset, the same substitution of exogenous values.

```jldoctest quickstart
julia> @variable(model, Lhat[J]);   # observed labour demand

julia> @variable(model, rho_bar);   # one productivity shared by both types

julia> estimation = @block model begin
           @unknowns rho_bar, L
           [j in J], L[j] == rho_bar * N[j]
           @objective Min sum((L[j] - Lhat[j])^2 for j in J)
       end;

julia> issquare(estimation)
false

julia> degrees_of_freedom(estimation)
1

julia> obs = Dataset(model);

julia> obs[N] = [100.0, 200.0];

julia> obs[Lhat] = [110.0, 190.0];

julia> fitted = solve(estimation, obs; replace_nothing = 1.0);

julia> round(fitted[rho_bar], digits = 4)
0.98
```

Two unknowns, one equation each, and an objective — so one degree of freedom, and least squares picks
the point. `issquare` is `false` and nothing complains, because squareness is a property of a block
rather than a requirement of one.

Pairings are still allowed on a block with an objective; they are simply inert, since the pairing is
documentation and a square-solver precondition rather than something that orders the system.

## Composing blocks

A block is a unit of model code, and a model is their sum. Each module owns its equations:

```jldoctest quickstart
julia> labour = @block model begin
           L[j in J], L[j] == rho[j] * N[j]
       end;

julia> wages = @block model begin
           w[j in J], w[j] == L[j] / 100
       end;

julia> whole = labour + wages;

julia> length(whole)
4

julia> issquare(whole)
true
```

A variable determined in both blocks raises rather than one equation quietly winning, and at most one
objective may appear across a sum.

A composed block is **never** marked square, whatever its parts claimed — two square blocks need not
compose to a square system, so inheriting the claim would skip the check where it is most likely to
catch something. Re-assert explicitly:

```jldoctest quickstart
julia> whole = assert_square!(whole);

julia> issquare(whole)
true
```

## Bounds

Bounds intrinsic to a variable — `K >= 0` — belong on the JuMP variable. Bounds that belong to *this*
problem go in the dataset, where they can differ between scenarios:

```jldoctest quickstart
julia> set_bounds!(data, L[1]; lower = 0.0);

julia> bounds(data, L[1])
(0.0, nothing)
```

The bound applied at solve time is the intersection of the two, and an empty intersection raises
rather than surfacing later as an unexplained infeasibility.

On a **square** solve, a bound that is active at the solution raises [`BindingBoundError`](@ref): the
system did not determine the answer, and the solver would have reported success anyway. On an
optimization solve an active bound is expected, so it is recorded in `meta.binding_bounds` instead.

## Blocks, pairings and squareness

A **block** is a composable collection of constraints over a JuMP model, together with the set of
variables being solved for and, optionally, an objective. Blocks are developed, tested and documented
one at a time, then summed into the system you actually solve.

Each constraint may be **paired** with the variable it is understood to determine. The pairing is
documentation and a precondition: it names constraints in solver output and diagnostics, and it is
what the square solver checks before it runs. It does not order the system or drive the solution
write-back, and in a block with an objective it is inert.

A system is **square** when it has no objective and every solved constraint is an equality paired
with a distinct variable, together covering the unknowns. That is the common case in macroeconomic
modelling and it gets a dedicated solve path. It is not a requirement — the number that generalises
is the degrees of freedom, which is defined either way.

Calibration is then not a special mode: it is the same block with a different partition of variables
into unknown and fixed.

## Relation to SquareModels.jl

[SquareModels.jl](https://github.com/MartinBonde/SquareModels.jl) by Martin Bonde solves the same
class of problem and is where these ideas come from. ModularSystems.jl is an independent
implementation with different interface preferences; it shares no code and is not a fork.
