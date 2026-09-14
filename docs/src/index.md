# ModularSystems.jl

Modular framework for building, calibrating and solving economic models in Julia.

Models are assembled from composable **blocks** of constraints. Each constraint may be paired with the
variable it determines — square systems get a dedicated solver — but a block may equally carry an
objective and be solved as an optimization problem.

!!! warning "Early days"
    Everything documented here works, but nothing in the API is stable. See [Design](@ref) for what
    has been decided and why.

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

## Solve settings

`replace_nothing = 1.0` above is one of a handful of settings a solve takes. Retyping them at every
call site is how two solves end up differing by a keyword nobody meant to change, so they can be
named as a value:

```jldoctest quickstart
julia> opts = SolveOptions(replace_nothing = 1.0)
SolveOptions(replace_nothing = 1.0)

julia> round(solve(block, data; options = opts)[L[1]], digits = 2)
3200.0
```

Printing shows only what differs from the defaults, which is the part worth reading. Derive a variant
rather than rebuilding one, so the two cannot drift apart:

```jldoctest quickstart
julia> loud = SolveOptions(opts; silent = false);

julia> (loud.replace_nothing, loud.silent)
(1.0, false)
```

Every field of [`SolveOptions`](@ref) is also accepted directly as a keyword of [`solve`](@ref), where
it overrides the options passed alongside it — so `solve(block, data; options = opts, silent = false)`
and the `loud` above mean the same thing.

`SolveOptions` holds nothing belonging to a particular model, which is what makes one set reusable
across models and scenarios. Starting values are a `Dataset` and therefore data, so they stay a
keyword of their own:

```jldoctest quickstart
julia> solved = solve(block, data; options = opts, start_values = baseline);

julia> round(solved[w[1]], digits = 2)
32.0
```

Two solvers, two scopes. [`set_optimizer_factory!`](@ref) sets a model's default, as in the
quickstart. `optimizer` inside `SolveOptions` names the solver for **that solve only** and does not
attach itself to the model — which is what lets a calibration use different solver settings from the
baseline it feeds.

One thing is deliberately *not* a setting. Every field above is a knob that means the same thing on
any model, which is what makes a named set reusable. The solve
[strategy](@ref Decomposition) selects an algorithm with preconditions, so a profile carrying one
would fail on some of the models it was meant to be reused across. It is a keyword of `solve` and a
field of [`Problem`](@ref) instead.

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

Very similar to [SquareModels.jl](https://github.com/MartinBonde/SquareModels.jl) at its core, with
different approaches to inequalities, variable bounds and a number of other things. An independent
implementation: no shared code, not a fork, and no dependency on it.

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

It names five things that would otherwise surface as an unexplained solver failure. Three are found by
looking at each constraint in turn: constraints left with no unknown once exogenous values are
substituted (`trivial`), unknowns appearing in no constraint and no objective (`orphans`), and
exogenous variables with no value (`missing_values`). A `@block` entry records where it was written,
so an unpaired constraint — which has no variable name to be called by — is still identifiable.

The other two need the [decomposition](@ref Decomposition) below, and are the ones a count cannot
find. Here two equations determine the same variable and another unknown is left with nothing:

```jldoctest quickstart
julia> @variable(model, lonely);

julia> duplicated = @block model begin
           @unknowns L, lonely
           L[j in J],  L[j] == rho[j] * N[j]
           [i in 1:1], 2 * L[1] == 2 * rho[1] * N[1]
       end;

julia> bad = diagnose(duplicated, data);

julia> bad.degrees_of_freedom      # three unknowns, three equations
0

julia> isclean(bad)
false

julia> [i for (i, _) in bad.contested]
2-element Vector{Int64}:
 1
 3
```

`contested` lists equations left with no variable to determine, because everything they could have
determined is already spoken for. `undetermined` is its mirror: unknowns that *do* appear in
equations, but where every equation that could have determined them is determining something else.

`undetermined` is kept separate from `orphans` because they are different bugs. An orphan appears in
no equation at all, which is almost always a typo. An undetermined unknown appears in equations that
have been taken by something else, which is a modelling error — and the fix is a different one.

The counts say nothing is wrong here: three unknowns, three equations, zero degrees of freedom. Only
the structure shows that one equation was written twice and `lonely` is determined by nothing.

## Decomposition

A square block pairs each equation with the variable it determines. Read as a graph, that pairing is
a **perfect matching**, and a matching is what a system needs to be split into the smallest groups of
equations that must be solved together:

```jldoctest quickstart
julia> dec = decompose(whole)
Decomposition(4 subsystems, largest 1)

julia> iswelldetermined(dec)
true

julia> largest_subsystem(dec)
1
```

[`subsystems`](@ref) come back in **solve order**, whatever order the equations were written in: each
one's inputs are determined by the ones before it. [`largest_subsystem`](@ref) is the size of the
biggest group that has to be solved simultaneously — 1 here, because nothing in `whole` is mutually
determined.

Where the pairings are missing or do not cover the unknowns, a maximum matching is computed instead,
and [`overdetermined`](@ref) and [`underdetermined`](@ref) name the parts that are left over. That is
where `contested` and `undetermined` above come from.

`decompose` is cheap — a few microseconds per unknown, about a thousandth of the cost of solving — so
it is meant to be used freely while a model is being built.

### Solving one subsystem at a time

[`BlockTriangular`](@ref) solves each subsystem in turn, each reading the results of the ones before
it out of the dataset:

```jldoctest quickstart
julia> round(solve(block, data; options = opts, strategy = BlockTriangular())[L[1]], digits = 2)
3200.0
```

!!! warning "It is slower, and that is measured"
    This is **not** a speed optimisation. It is 2× to 110× *slower* than the default
    [`Monolithic`](@ref) across model sizes up to 21,500 unknowns. Entering an interior-point solver
    costs about the same whatever the problem size, and a one- or two-variable subsystem cannot
    amortise that: Ipopt's summed time over 400 tiny subsystems was 0.99 s against 0.004 s for the
    same system solved at once.

    What it buys is **convergence on a short system**. Every subsystem starts from the results of
    the ones before it, where a monolithic solve starts from whatever was supplied for everything
    at once.

    But each subsystem is solved to an *absolute* tolerance and its answer is handed on as exact,
    with nothing downstream able to correct it. On a long recursive chain that error accumulates —
    measured 2,700× worse than monolithic over 700 periods, and outright failure at 1,000. Reach
    for it on a short system that will not converge; not on a long recursive one, and never for
    speed.

It refuses rather than guessing: a block with an objective, one that is over- or under-determined, or
one carrying a solved *inequality* — which determines nothing, so it belongs to no subsystem — raises
instead of quietly solving a different problem.

## Problems and modes

A model is never solved one way. It is calibrated, run as a baseline, shocked; its satellite modules
are sometimes linked in and sometimes held exogenous. Each of those is a block, a dataset and some
settings — and `solve(block, data)` will accept any pairing of them, meaningful or not.

A [`Problem`](@ref) is one pairing that means something:

```jldoctest quickstart
julia> p = Problem(whole, data; options = opts)
Problem(4 constraints, 4 unknowns)

julia> round(solve(p)[w[2]], digits = 2)
10.0
```

A shock is a baseline with something different about it, so derive rather than rebuild:

```julia
shock = Problem(baseline_problem; data = shocked, start = baseline)
```

The constructor checks the **block** — see [`assert_solvable`](@ref) — and deliberately not the data.
A block is a value and cannot change underneath the problem, so a guarantee about it holds. A
`Dataset` is mutable by design, since a scenario *is* a dataset that gets edited, so a check on the
data taken at construction would be stale exactly when it mattered. Missing data is caught at solve
time instead, where it is still exact.

A [`ModelSpec`](@ref) collects the named modes:

```jldoctest quickstart
julia> spec = ModelSpec(model);

julia> register!(spec, :baseline, p; about = "forward run");

julia> modes(spec)
1-element Vector{Symbol}:
 :baseline

julia> ready(spec)
1-element Vector{Symbol}:
 :baseline
```

[`ready`](@ref) is how a workflow's ordering is expressed here, and it is **derived, not declared**: a
calibration comes before the baseline that consumes its output because the baseline's parameters are
not in the data until the calibration has run. Nobody writes that down, so nobody can write it down
wrongly. `diagnose(spec)` says *why* a mode is not ready, and displaying a spec shows it per mode.

There is deliberately no dependency graph and no "current mode". Modes are values; the one you are
working with is a variable in your own code, not hidden state in the model.

`examples/multiModeModel.jl` runs the whole story end to end — two calibrations, linked and unlinked
baselines, and a shock — on a two-sector model with an energy satellite.

## Soft-linking separate models

Sometimes two models cannot be made one. A macro model and a bottom-up energy model are maintained by
different people at different granularity, and neither can be pasted into the other — so they are
coupled by a handful of quantities instead, solved in alternation until neither changes what it hands
over.

Almost none of that needs the package. Passing a value across is a read of one dataset and a write to
another:

```julia
energy_data[q[s]] = macro_data[E[s]]
```

and a `Dataset` refuses a variable belonging to the wrong model, so a mis-wired coupling raises rather
than producing a plausible number. The models themselves are ordinary [`Problem`](@ref)s.

What does need help is the loop, and only because of how it fails. **Every individual solve in a
diverging soft link converges and reports success** — each model answers the question it was given
perfectly well, and the pair never agrees. There is no other symptom, so a loop that runs out of
iterations and returns its last values hands back numbers that look exactly like a solution.
[`fixed_point!`](@ref) raises instead:

```julia
report = fixed_point!([macro_data => pe]) do
    solve!(macro_problem)
    for s in S
        energy_data[q[s]] = macro_data[E[s]]
    end
    solve!(energy_problem)
    macro_data[pe] = energy_data[price]
end
```

The list is the cells that carry information **between** passes — the feedback, whose value at the
start of a pass determines that pass. `q[s]` is transferred too, but a transfer overwrites it before
anything reads it, so it carries no state and is not what the loop is converging.

`damping` moves each exchanged cell only part of the way to its new value, which is what settles two
models that overshoot each other. It fixes overshoot and not expansion: if the change alternates in
sign, damping will help; if the link walks away in one direction, no admissible amount of damping
brings it back and the coupling itself is wrong. A failure carries its `history`, which tells the two
apart.

`examples/softLink.jl` shows a link that settles, the same link made steep enough that it will not,
and damping fixing it.

## When a solve raises

Five failures have names, because each means something different and calls for a different fix.

| raised by | means |
|---|---|
| [`StructuralError`](@ref) | the block cannot be solved whatever the data says. Carries the [`Diagnosis`](@ref) that found it. |
| [`BindingBoundError`](@ref) | a bound is active at the solution of a **square** system, so the equations did not determine the answer. Never raised on the optimization path, where an active bound is expected. |
| [`CheckFailure`](@ref) | a `@check` constraint did not hold at the solution. Carries each failing check and the gap it missed by. |
| [`SubSystemFailure`](@ref) | a subsystem failed during a [`BlockTriangular`](@ref) solve. Names which one and what it was solving for; everything before it succeeded, so the dataset holds those results. |
| [`ConvergenceFailure`](@ref) | soft-linked models did not settle. Carries the history, which says whether they were diverging or merely slow. |
| `ArgumentError` | the request itself does not make sense — an exogenous variable with no value, an empty bound interval, a block declared square that is not. |

The first four are the package refusing to hand back a plausible wrong answer. That is the thing it is
most careful about: a solver reporting success on a problem that is not the one you asked about is
worse than an interruption.

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
