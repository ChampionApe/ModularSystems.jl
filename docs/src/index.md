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

## Calibration is a swap

Calibration solves the same equations for different variables: a parameter becomes unknown, an
observed outcome becomes data. [`swap`](@ref) exchanges them and re-points the equation that
determined the outcome, leaving the equations themselves untouched.

```jldoctest quickstart
julia> calibration = swap(block, rho => L);

julia> collect(unknowns(calibration))[1] == rho[1]
true

julia> issquare(calibration)
true

julia> observed = Dataset(model);

julia> observed[N] = [3200.0, 500.0];

julia> observed[L] = [3200.0, 1000.0];

julia> calibrated = solve(calibration, observed; replace_nothing = 1.0);

julia> round(calibrated[rho[1]], digits = 4)
1.0

julia> round(calibrated[rho[2]], digits = 4)
2.0
```

The behavioural block, unchanged, now reproduces the observation from those parameters — and a swap
preserves the shape of the system, so a block declared square stays declared square and is
re-checked.

Either side may be a variable, a container or a group, and group sides pair **in iteration order** —
which is why a [`VariableGroup`](@ref) is ordered. Use `@group` when the cells need selecting:

```julia
calibration = swap(block, @group(rho[j in J; j == 1]) => @group(L[j in J; j == 1]))
```

Underneath are two primitives that mean the same thing whether or not the block is square:
[`endogenize`](@ref) adds variables to the unknown set, [`exogenize`](@ref) removes them. `swap` is
the square-case combination that also re-points the pairing. Exogenising a variable that an equation
determines raises and points you at `swap`, since it would otherwise leave an equation determining
something no longer being solved for.

(They are `endogenize`/`exogenize` rather than `fix`/`free` because JuMP exports `fix` and `unfix`;
taking those names would force every user of both packages to qualify the call.)

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

## Diagnosing a block

`diagnose` reports the shape of a system and its structural problems without running a solver. It
reports rather than raises: it is meant to be read while a model is being written.

```jldoctest quickstart
julia> report = diagnose(whole, data);

julia> isclean(report)
true

julia> report.degrees_of_freedom
0

julia> report.square
true
```

It names three things that would otherwise surface as an unexplained solver failure: constraints left
with no unknown once exogenous values are substituted, unknowns appearing in no constraint and no
objective, and exogenous variables with no value. A `@block` entry records where it was written, so
an unpaired constraint — which has no variable name to be called by — is still identifiable.

## Tags and descriptions

Tags are cross-cutting labels on variable cells, attached after declaration and turned back into a
group on demand. Nothing shadows `JuMP.@variables`, so every JuMP declaration form keeps working.

```jldoctest quickstart
julia> const Quantity = Tag(:quantity);

julia> tag!(model, Quantity, L);

julia> length(tagged(model, Quantity))
2

julia> describe!(model, w, "Wage by labour type");

julia> description(w[1])
"Wage by labour type"
```

## Sparse patterns

A sparse variable declared with a filter makes JuMP evaluate the predicate over the full product of
its axes, which scales with that product rather than with the number of variables created. An
[`IndexSet`](@ref) is the pattern as a value, and declaring over it is plain JuMP with no scan:

```jldoctest quickstart
julia> pairs = IndexSet((:p, :i), [(:food, :agri), (:steel, :mfg), (:food, :mfg)]);

julia> @variable(model, use[pairs]);

julia> length(pairs)
3

julia> collect(select_axes(pairs, :p))
2-element Vector{Tuple{Symbol}}:
 (:food,)
 (:steel,)
```

A coordinate-keyed container is dense over its own axes, so there are no absent cells to guard.
Equations iterate the pattern instead of ranging over a product, and `group_by` is what replaces
summing over one index of a sparse variable:

```jldoctest quickstart
julia> by_product = group_by(pairs, :p);

julia> length(by_product[(:food,)])
2
```

`IndexSet` carries the same `∪`, `∩` and `setdiff` as [`VariableGroup`](@ref) — one is a set of
coordinates, the other a set of the cells at those coordinates.

## Reference: the `@block` grammar

| Form | Meaning |
|---|---|
| `x, expr` | constraint paired with `x` |
| `x[i in I], expr` | indexed, paired with `x[i]` |
| `x[t0], expr` | a fixed index — pairs with that one cell, no loop |
| `[i in I], expr` | indexed, unpaired |
| `expr` | scalar, unpaired |
| `@check expr "msg"` | evaluated after a solve, never solved |
| `@unknowns ...` | declares the unknown set |
| `@objective Min expr` | attaches an objective |
| `@square` | asserts squareness, checked as the block is built |

A comma-separated head names the variable a constraint determines; brackets alone give index sets and
leave the constraint unpaired. A filter goes after `;`, as in `x[t in T; t > t0]`. Fixed and looped
positions may be mixed: `x[s in S, :Equity, t in T]`.

`@unknowns` is required once any solved constraint is unpaired. That is what turns a dropped variable
name — `[i in I], ...` where `x[i in I], ...` was meant — into a degrees-of-freedom mismatch rather
than a silent change of problem.

A pairing on an inequality is an error, since an inequality determines nothing.
