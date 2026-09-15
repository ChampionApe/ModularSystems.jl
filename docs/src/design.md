# Design

The record of what has been decided and what has not. Decisions are appended here with their
reasoning, so a later reader can see what a change would cost. Open questions live in
`notes/TODO.md`; this page carries only what is settled.

## Scope

One package, no sibling packages. Optional dependencies are reached through package extensions in
`ext/`, which live in this repository and load only when the optional package is present.

The priorities, in the order that breaks ties: speed and efficiency; modularity and flexibility; and
being easy to read, write and adjust while a model is being developed. Decisions below are argued
against these, and a measurement beats an argument from elegance.

## Settled

### Clean-room implementation

The package borrows concepts from SquareModels.jl — equation blocks,
endo-exo swapping, a model-level data dictionary — and no code. This costs re-derivation and buys
freedom in the interface, which is the reason the package exists at all.

### The package sits on JuMP

*Decided 2026-09-14 — `notes/TODO.md` C1.*

The three candidates were JuMP,
MathOptInterface alone, and a solver-agnostic core with JuMP as a package extension.

JuMP wins on the thing that matters for a small package: it already supplies the expression macros,
the variable and constraint containers, and the solver interfaces, and its users arrive fluent in
them. MathOptInterface alone would mean rebuilding that surface to no clear benefit, and a
solver-agnostic core would mean maintaining two interfaces before we know what the first one should
look like. SquareModels.jl made the same choice, which is also a compatibility argument: a model
written against one is recognisable to a reader of the other.

What this commits us to: the JuMP model is the state, and JuMP's `@variable`/`@constraint` idiom
shapes ours. The cost, if it turns out to be wrong, is an interface rewrite rather than a rewrite of
the solving logic — acceptable at this stage. `MathOptInterface` is not a direct dependency yet; add
it when a solver attribute actually needs reaching for, not pre-emptively.

### Solvers and plotting go in `ext/`

Weak dependencies with package extensions, the
pattern SquareModels.jl uses for GAMS, GDXInterface and Makie. A user who only wants to build and
solve a model should not pay for a plotting stack. Nothing here yet — this is the shape to follow
when the first integration arrives.

### One `Block` type, with the pairing optional

*Decided 2026-09-14 — `notes/TODO.md` C2.*

A block is a
collection of constraints over a JuMP model, not a square map. Each constraint carries two
independent pieces of metadata: which variable it is paired with, if any, and whether it is *solved*
(enters the system) or *checked* (evaluated after a solve). A block also carries an explicitly
declared set of unknowns and an optional objective.

Squareness is therefore a **predicate, not an invariant**: `issquare` asks whether there is no
objective, every solved constraint is an equality with a distinct paired variable, and those
pairings cover the unknowns. The number that generalises is the degrees of freedom, which is defined
whether or not the system is square.

The alternative was two types — a square block and an optimization block — with a shared interface.
Rejected because composing a square behavioural block with an estimation objective is the case that
motivates the flexibility, and two types make that a conversion rather than a sum.

What this buys, beyond admitting NLP problems: inequality constraints become ordinary solved
constraints instead of being confined to test constraints, and a "test constraint" stops being a
special form — it is a constraint whose role is *check*.

What it costs: SquareModels raises a non-square error at block construction, naming that block,
before assembly. A predicate defers that to solve time, about the whole system. The mitigation is to
let a block declare its own intent — a block written to be square says so and is checked
immediately — so the local error is available without being compulsory. This has to be cheap and
visible in the `@block` grammar, not a keyword nobody remembers.

### The pairing is documentation plus a precondition

*Decided 2026-09-14 — `notes/TODO.md` C3.*

It records which equation is understood to determine which variable, it names constraints in solver
output and diagnostics, and it is what the square solver checks before running. It does **not** order
the system, drive the write-back, or seed starting values. In a block with an objective it is inert.

This was checked against SquareModels.jl rather than assumed, because the opposite choice — a pairing
that is semantic everywhere — would have been the more ambitious package. Its solve path keys
everything on the unknown set: `transform_expr` branches on whether a variable is an unknown (map it
to the intermediate model) or not (substitute its data value), and the write-back iterates the
unknown map in dictionary order. The pairing appears only in the constructor check, in
`set_name(con, name(endogenous[i]))`, in the positional alignment of residual variables, and in the
diagnostics. So the substitution-and-write-back spine is shared between a square solve and an
optimization solve, and the two differ only at the tail.

A consequence for endo-exo swapping: the primitive is moving a variable between the unknown set and
the fixed set — `fix` and `free` over a variable group — which means the same thing in both kinds of
system. Re-pointing a pairing is the square-case extra, not the operation itself.

### Variable groups are a core type

*Decided 2026-09-14.*

Composable collections of variables, assembled after declaration and passed to `fix`,
`free`, `solve` and bound-setting. Once the unknowns are declared rather than derived from pairings,
naming a set of variables is something the interface does constantly. The type is specified below
under [Variable groups, and index sets as their coordinate twin](@ref); note that the "named" in the
original form of this decision did **not** survive — groups carry no name field.

### Problem bounds live in the dataset

*Decided 2026-09-14 —
`notes/TODO.md` C9.*

Two different things were being called "bounds":

*Intrinsic* bounds — `K ≥ 0`, `share ∈ [0, 1]` — are properties of the variable, true in every
problem it appears in. They stay on the JuMP variable declaration, where JuMP validates them and
where they are visible next to the variable.

*Problem* bounds — "in this calibration keep `σ ∈ [0.1, 10]`", "`K ≥ 0.5 · K_baseline`" — are
properties of the problem instance, are often derived from data, and differ across scenarios. They
live in the dataset.

The objection to putting them in the dataset is that a calibration block and a behavioural block are
solved against the same data with different unknowns, so bounds look like they should be per-block.
They should not, because **a bound only ever bites on a variable that is unknown in that solve, and
the unknown set is a block property**. A variable that a block treats as exogenous is substituted as
a number and never enters the solve model, so its dataset bound is irrelevant rather than
conflicting. Dataset bounds therefore specialise per block on their own, with no merge rule and no
second home. The rare case of two blocks wanting different ranges for the same unknown is handled by
copying the dataset.

Putting them on the block was rejected for a second reason: data-derived bounds would make a block
carry numbers, and the point of a block is that it is the equations.

Storage is **layers over one key space** — a dense value vector, sparse lower and upper maps, and
per-dataset solve metadata, all keyed on the variable id the layout already assigns:

```julia
struct Dataset{T}
    layout::ModelLayout                # shared across datasets
    values::Vector{Union{T,Nothing}}   # dense: a value for nearly every variable
    lower::Dict{Int,Float64}           # sparse: bounds are genuinely rare
    upper::Dict{Int,Float64}
    meta::SolveMetadata                # termination status, objective value, solve time
end
```

Bounds are sparse because most variables have none, and sharing the key space means there is no
second lookup mechanism to keep in sync with the model layout. The rejected alternative was one
`(value, lower, upper)` record per cell: it triples memory for a field absent on most cells, and it
makes dataset arithmetic ambiguous.

### Arithmetic returns a value-only dataset

`scenario ./ baseline .- 1` must
give multipliers; bounds do not divide, and a ratio of two scenarios is not a scenario, so bounds and
solve metadata are dropped from an arithmetic result. `copy` preserves every layer. Any data I/O that
is added later must state which layers round-trip.

Starting values stay a separate dataset rather than becoming a layer. `start_values = baseline`
— start the scenario from the baseline solution — is the common idiom and it genuinely is another
dataset.

`fix`/`free` stays strictly about membership of the unknown set. A degenerate bound `[v, v]` is a
second way to express the same intent, slower and harder to diagnose, so it warns rather than acting
as a fix.

### A binding bound on a square solve is an error

*Decided 2026-09-14.*

The effective bound on an unknown is
the intersection of its intrinsic and dataset bounds; an empty intersection is a named error rather
than a mysterious infeasibility. If a bound is active at the solution of a *square* system, the
answer is not the solution of that system — the problem has silently become a complementarity
problem, and the solver reports success. That is a wrong answer delivered quietly, which is worse
than an interruption, so it raises. On the optimization path a binding bound is normal and is
reported in the dataset's solve metadata, not raised. An opt-out keyword follows
`presolve_diagnostics`.

One thing this cost in practice, recorded because it would silently disable the check: **the
tolerance must be looser than the solver's own bound relaxation.** An interior-point solver does not
land on a bound — Ipopt relaxes bounds and stops slightly *outside*, measured at about 1.7e-8 below a
lower bound. A tolerance at solver precision therefore detects nothing at all. The default is 1e-6,
scaled by the magnitude of the bound, and `test/optimize.jl` pins the behaviour so tightening it
cannot pass unnoticed.

This diagnostic is the strongest argument for the split above: it has to distinguish a bound imposed
for this problem from a bound intrinsic to the variable, which is only possible if the two are stored
separately. SquareModels.jl cannot perform this check — `solve.jl` has no dual or binding-bound
logic, and bounds exist only as model state.

### Continuous variables only

*Decided 2026-09-14.*

No integer or binary variables; mixed-integer problems
are out of scope. `diagnose` may treat integrality as an illegal shape and say so. The layer design
would extend to per-variable integrality exactly as it extends to bounds, so this can be revisited
without rework if it ever needs to be.

### The `@block` grammar

*Decided 2026-09-14 — `notes/TODO.md` C5.*

One macro covers both kinds of system. The grammar itself is documented in the manual under
**Reference: the `@block` grammar**; what follows is why it has that shape.

```julia
production = @block data begin
    @square

    L[j ∈ J],  L[j] == μ[j] * (w[j] / p)^-σ * Y
    w[j ∈ J],  L[j] == ρ[j] * N[j]
    Y,         p * Y == ∑(w[j] * L[j] for j ∈ J)
    p,         p == 1

    @check C == ∑(Cj[j] for j ∈ J)  "consumption aggregation"
end

estimation = @block data begin
    @unknowns σ, μ[j ∈ J]
    @objective Min ∑((w[j] - ŵ[j])^2 for j ∈ J)

    [j ∈ J],  L[j] == μ[j] * (w[j] / p)^-σ * Y
    p == 1
end
```

Why this shape:

*Pairing is optional by syntax, not by a flag.* A comma-separated head means the constraint
determines that variable; no head means it does not. A square block therefore reads exactly as it
does in SquareModels.jl — the common case did not get worse to buy the optimization case.

*The unpaired indexed form is JuMP's own.* `@constraint(model, [i = 1:3], x[i] >= 0)` is how JuMP
writes an anonymous indexed constraint, so the form we had to invent is one a JuMP user already
knows, and paired versus unpaired is exactly whether a name precedes the brackets.

*`@check` takes its constraint as an argument.* SquareModels' `@test_constraint` is a bare statement
that modifies the following line, which is why its documentation has to say the macro call must be a
separate statement directly before the entry. Taking the constraint as an argument makes the
association syntactic, so a blank line, a reorder or a stray comment cannot break it. The shape
`@check expr "message"` deliberately mirrors `@assert`. Tolerances ride as keywords:
`@check(expr, "msg"; atol = 1e-8)`.

*`@`-prefixed lines are declarations; bare lines are constraints.* One visual rule covers
`@unknowns`, `@objective` and `@square`. `@check` is the deliberate exception and announces itself by
taking a constraint rather than standing alone.

*`@square` is the mitigation this page promised.* Moving squareness from invariant to predicate costs
the construction-time error; one line at the top of a block restores it for blocks that want it,
without forcing it on blocks that do not.

None of these need to exist as macros — `@block` walks its body and matches on
`Expr(:macrocall, Symbol("@check"), …)`. Define them anyway, erroring with "only valid inside
`@block`", so a misplaced one fails with a sentence rather than an `UndefVarError`.

The known cost: `a[t ∈ T], …` and `[t ∈ T], …` differ by one token, so a dropped variable name
silently converts a paired constraint into an unpaired one. Under `@square` that is an immediate
error. Otherwise the safety net is that `@unknowns` is mandatory once anything is unpaired, so the
mistake surfaces as a degrees-of-freedom mismatch against a declared set instead of passing quietly.
That is the reason `@unknowns` is required rather than inferred.

A documentation obligation, not a grammar one: `σ >= 0.1` is a legal inequality *constraint* but it
is not a bound. Bounds are dataset state set with `set_bounds!`, and only bounds get the
binding-bound diagnostic. Same mathematics, different machinery, and users will write the constraint
and wonder why the diagnostic stayed quiet.

### Variable groups, and index sets as their coordinate twin

*Decided 2026-09-14 — `notes/TODO.md` C8.*

```julia
struct VariableGroup
    model::JuMP.AbstractModel
    vars::Vector{VariableRef}   # ordered, unique
    set::Set{VariableRef}       # O(1) membership
end
```

Elements are variable *cells* (`μ[1]`, `K[2030]`), not containers, because every call site —
`@unknowns`, `set_bounds!`, `fix`/`free` — selects cells. Built with `@group`, which shares the
index-spec parser with `@block` so `μ[j ∈ J]` means the same thing everywhere, or with
`VariableGroup(itr)` for programmatic construction; the split mirrors JuMP's own `@variable` /
`add_variable`.

Ordered, with a membership set beside it — the same vector-plus-set pattern `Block` uses. Order is
not needed to solve, since the solve map is a `Dict`, but it is needed for deterministic diagnostics
and for the swap, which pairs two selections in iteration order. A group is a **value frozen at
construction**, not a query re-evaluated against the model: membership that could change between
declaring unknowns and solving is a wrong answer rather than an error. It validates that all its
variables share one model. It implements iteration, `length`, `in` and `getindex` but does **not**
subtype `AbstractVector`, which would invite `push!`, `similar` and array broadcasting semantics that
would then have to be supported or explained away.

**No name field.** The Julia binding is the name; a name field can disagree with it. The cost is
that `diagnose` cannot say "3 unknowns in `elasticities` never appear in a constraint" — it lists
variables instead. Accepted deliberately.

There are no constraint groups: `Block` already is the collection of equations, with `+` as its
composition. Groups complete that symmetry rather than duplicating it.

**Tags are kept, but attached by function rather than by shadowing `JuMP.@variables`.**

```julia
tag!(model, GrowthAdjusted, qGDP, vGDP)
tag!(model, FlatForecast, K[t ∈ T; t > t₀])
tagged(model, GrowthAdjusted)                # -> VariableGroup
```

Storage goes in `model.ext`, which is JuMP's sanctioned extension point, so the tag machinery itself
costs about 120 lines and requires no macro. What requires shadowing is the *declaration-site* `::`
syntax, not tags — these are separable, and SquareModels.jl conflates them because sparse container
construction, which genuinely does need to own the declaration site, lives in the same macro.

Two further reasons for the function form. SquareModels keys metadata on the **base variable symbol**
(`Dict{Symbol, VariableMetadata}`), so its tags are per *container*: `X[2020]` returns the tags of
`X`, and a single cell cannot be tagged. Keying on `VariableRef` puts tags at the same granularity as
groups, which is what lets `tagged` return a genuine group. And a macro named `@variables` would
collide with JuMP's export, forcing every user to qualify — SquareModels' own README never writes
`using JuMP`, only `import JuMP` plus a selective `using JuMP: Model, set_silent`, which is that
collision being worked around. That particular cost is avoidable by choosing a different name and
should not be counted against shadowing in general.

What is given up: attaching a tag at the declaration site. It goes on a following line instead.
Descriptions are the same story, and get the same treatment — `describe!(model, qGDP, "Real GDP")`,
same store, no macro.

**`IndexSet` is the coordinate-level twin of `VariableGroup`** — an ordered set of coordinate tuples
with named axes, carrying the same `∪` / `∩` / `setdiff`, plus projection and grouping by axis, which
only make sense at the coordinate level. A `VariableGroup` is what you get by applying an `IndexSet`
to a container. Its role in sparsity is the next decision.

### Sparsity is handled by coordinate axes

*Decided 2026-09-14 —
`notes/TODO.md` C10.*

Declaring a sparse variable with a filter makes JuMP evaluate the predicate
over the full product of the axes. Measured, at 50 periods with a tridiagonal pattern:

| I × J × T | combinations | variables | filtered `@variable` | coordinate axis |
|---|---|---|---|---|
| 50×50×50 | 125,000 | 7,400 | 46.7 ms | 8.3 ms |
| 100×100×50 | 500,000 | 14,900 | 109.5 ms | 14.4 ms |
| 400×400×50 | 8,000,000 | 59,900 | 1306.6 ms | 94.8 ms |

The script is kept at `archive/sparseDeclarationBenchmark.jl`, so the table can be rerun rather than
believed. Filtered declaration scales with the product of the axes; declaring over a coordinate axis
(`@variable(model, use[pairs, t = years])`) scales with the number of variables. That is plain JuMP —
no macro, no custom container.

It also removes the second half of the problem. A coordinate-keyed container is *dense over its own
axes*, so there are no absent cells to raise `KeyError` and nothing for a `Zero()` sentinel to paper
over. Equations iterate patterns instead of guarding products:

```julia
∑(use[k, t] * price[k, t] for k in patternA ∩ patternB)
```

which is also clearer than the sentinel: the coordinates being summed are visible. `Zero()` makes a
sum over the dense product silently correct, which is convenient until the pattern is not what was
assumed and the sum quietly omits terms.

What is given up is notation: `x[p, i, t]` on a sparse variable becomes `x[k, t]` with `k` a
coordinate. That is the entire cost, and it is the only thing SquareModels' ~710 lines of sparse
machinery buys that this does not.

Two implementation constraints follow, cheap now and expensive later. `@block` must ask a container
for its stored keys through a **generic interface**, never by dispatching on a concrete sparse type —
SquareModels' core names `SparseZeroArray` in `_variable_refs`, `_key_of`, `_all_keys` and `_ndims`,
which is what makes its sparse layer non-optional in practice. And the expression walkers should
tolerate an additive-identity sentinel they do not define, so a notation layer could be added later
by a package extension rather than a rewrite.

### Composition

*Decided 2026-09-14 — `notes/TODO.md` C6.*

`a + b` concatenates constraints over one model. A variable determined in both blocks raises, so an
equation cannot be silently dropped.

*At most one objective across a sum.* Two objectives raise rather than being summed: adding
objectives contributed by different modules is a wrong answer with no symptom.

*Unknowns are unioned.* If neither block declares a set, the result declares none either and keeps
deriving its unknowns from its pairings, so composing does not freeze a block that was still
derivable.

*The result is never marked square*, whatever its parts claimed. Two blocks can each be square alone
and not compose to a square system — they may share a pairing, or one may supply constraints the
other's unknowns do not cover — so inheriting the claim would skip the check exactly where it is most
likely to catch something. `assert_square!` re-asserts and checks.

A related change fell out of this: `add_constraint!` checked for a duplicate pairing by scanning
every existing constraint, making block construction quadratic in its size. Blocks now carry a
`Set` of claimed pairings, which matters once a model is assembled from modules.

### Naming and identifying constraints

*Decided 2026-09-14 — `notes/TODO.md` C11.*

A paired constraint is named in the solver after the variable it determines. An unpaired one is named
`constraint[n]` by its position among the solved constraints: a solver name has to be short and
stable, so it cannot carry much.

What actually identifies an unpaired constraint is **where it was written**. `@block` records a
`file:line` on each entry it builds, and `diagnose` and a failed `@check` report it. That is the only
handle an unpaired constraint has, since there is no variable name to call it by. The programmatic
API records no source, and says so rather than inventing one.

### Diagnosis reports rather than raises

*Decided 2026-09-14.*

`diagnose(block, dataset)` returns the shape of the system — unknowns, equalities, inequalities,
checks, objective, degrees of freedom, which solve path applies — together with three structural
problems: constraints containing no unknown (a constant equation once exogenous values are
substituted), unknowns appearing in no constraint, and exogenous variables with no value.

It reports rather than raises, because a diagnosis is something to read while building a model. The
useful summary is the *shape*, not a square/not-square verdict, since degrees of freedom is defined
on both paths.

An orphan means different things on each path, so the test differs: an unknown in no constraint is a
bug in a square system, but legitimate if it appears in an objective, and a variable in the objective
is therefore not reported.

### The swap interface

*Decided 2026-09-14 — `notes/TODO.md` C3.*

Two primitives and one combination, all **non-mutating**:

- `endogenize(block, items...)` adds variables to the unknown set;
- `exogenize(block, items...)` removes them;
- `swap(block, new => old, ...)` does both and re-points the equation that determined `old`.

Non-mutating because a calibration variant is then a value. SquareModels.jl's idiom is
`calibration = copy(block)` followed by a mutating macro, and the copy is a step you can forget; here
the original is untouched by construction.

Functions rather than a macro, and cells are selected with `@group` when they need selecting
(`swap(b, @group(mu[j in J]) => @group(L[j in J]))`). That reuses the one index syntax the package
already has instead of inventing a third, and keeps the macro count down.

**They are `endogenize`/`exogenize`, not `fix`/`free`.** JuMP exports `fix` and `unfix`, so taking
those names would force every user of both packages to qualify the call — the same cost that ruled
out shadowing `@variables`. These are also the words this literature already uses.

The primitive is membership of the unknown set, which means the same thing on both solve paths;
re-pointing a pairing is the square-case extra, which is why `swap` is built on the primitives rather
than beside them. `exogenize` raises on a variable some equation determines, pointing at `swap`:
removing it silently would leave an equation determining something no longer being solved for.

`endogenize` and `exogenize` clear the square claim, since they change the shape of the system. A
swap preserves it — one pairing re-pointed, counts unmoved — so a block declared square stays
declared square and is re-checked.

### Residuals are opt-in and paired-only

*Decided 2026-09-14 — `notes/TODO.md` C7.*

`with_residuals(block, datasets...)` adds a residual variable to every paired solved constraint, added
to the constraint function so `x == rhs` becomes `x + residual(x) == rhs`. Residuals are exogenous and
zero, so they change nothing until asked to.

Never created automatically, which is where SquareModels.jl differs: a residual doubles the variable
count, and most sessions never use one. It is also meaningless for a constraint that determines
nothing, so unpaired constraints get none.

What they buy is locating inconsistent data, and it is expressed as a [`swap`](@ref) rather than as
its own mechanism — exogenise the variable at its observed value, make its residual the unknown, and
solve; the residual reads off how far the data misses the equation. That the debugging workflow falls
out of the swap primitive rather than needing machinery of its own is the argument for having built
the primitive first.

Applying it twice is harmless: a constraint already carrying its residual is skipped, checked by
looking for the residual in the constraint rather than by a flag that could drift.

### Solve settings are a value

*Decided 2026-09-14 — `notes/TODO.md` C15.*

[`SolveOptions`](@ref) holds what had been nine keyword arguments retyped at every call site. Every
field is still accepted as a keyword of [`solve!`](@ref) and overrides the options passed alongside
it, so nothing that worked before means something different now.

Two lines fall out of having drawn it, and both are the useful part.

*Settings, not data.* Starting values are a `Dataset` and stayed a keyword rather than becoming a
field, because a `SolveOptions` that named a dataset would be tied to one model. As it stands one set
of options is reusable across models and scenarios, which is what makes naming a set worth doing.

*The optimizer became a per-solve setting rather than model state.* It had been stored in
`model.ext`, and passing `optimizer = X` to a solve attached `X` to the model as a side effect. A
calibration and the baseline it feeds could not then use different solvers, or the same solver at
different attributes, without mutating something shared. `set_optimizer_factory!` remains, as the
model's default.

*The solve strategy is not a setting, and briefly was.* `SolveOptions` carried a `strategy` field
until review pointed out it is the one field for which the type's own claim is false. Every other
field is a knob that degrades gracefully on any model; a `SolveStrategy` selects an algorithm with
preconditions — `BlockTriangular` raises on an objective, on a deficient system, on a solved
inequality — so a named profile carrying one fails on some of the models it was meant to be reusable
across, which is exactly what naming a profile is for. It is now a keyword of `solve` and a field of
`Problem`. That sharpens both types rather than blurring one: `SolveOptions` is the model-independent
settings, `Problem` is "this block, this data, this way".

### The pairing is also a matching

*Decided 2026-09-14 — `notes/TODO.md` C14.*

The pairing was recorded above as documentation plus a precondition, and that stands. What was
missed is that structurally it is also a **perfect matching on the equation–variable incidence
graph**, which is the input to a Dulmage–Mendelsohn decomposition. The information was already
there; [`decompose`](@ref) only reads it.

Orienting the graph by the matching and running Tarjan gives the smallest subsystems that must be
solved simultaneously, in an order where each one's inputs are already known. Where the pairings are
missing or do not cover the unknowns, a maximum matching is computed instead and the coarse
decomposition names the over- and under-determined parts.

**Kept for diagnosis, and it pays for itself there.** A count cannot distinguish a sound system from
a structurally singular one. A block with two equations determining the same variable and a third
variable determined by nothing has `degrees_of_freedom == 0`; `decompose` names all three. So
`diagnose` now reports `contested` equations and `undetermined` unknowns, kept separate from
`orphans` because "appears in no equation at all" and "appears, but every equation that could
determine it is determining something else" are different bugs with different fixes. The
decomposition costs 2–9 µs per unknown — about three orders of magnitude less than solving — so
this is free.

**Not kept as a speed optimisation, and that was measured rather than assumed.**
`BlockTriangular` is 2× to 110× *slower* than solving monolithically, at every size where both work.
The reason is specific: Ipopt's summed solve time over 400 one- and two-variable subsystems was
0.990 s against 0.004 s for the same system solved at once — 250× worse. An interior-point solver
has a setup cost that is independent of problem size, and a scalar subsystem cannot amortise it.
Building 400 JuMP models, at 1.83 ms each, is the *smaller* half of the overhead. The speedups
reported for block-triangular form elsewhere assume each subsystem is solved by a direct method, not
by re-entering a general-purpose NLP code.

The strategy is kept anyway, on a different claim: over 70 combinations of model shape and starting
point, the monolithic solve converged 58 times and the block-triangular one 62, with five cases it
alone solved against one it alone missed. Each subsystem starts from the results of the ones before
it, where the monolithic solve gets whatever the user supplied for everything at once. So it is
documented as a convergence fallback and not as an optimisation, which is the opposite of what was
expected when it was written.

The gap does narrow with size — 12.3× at 2,150 unknowns, 1.8× at 21,500 — but no crossover was
reached, because the block-triangular path became unreliable at 43,000 unknowns before the
monolithic one did. Tables, and the arithmetic showing that a scalar fast path alone would not close
the gap, are in `archive/decompositionMeasurements.md`.

**`BlockTriangular` refuses a block with a solved inequality**, rather than solving it. An inequality
determines nothing, so it belongs to no subsystem, so nothing would ever add it to a model — and the
solve would return the answer to a different problem while reporting success. Review found this
producing the wrong root of `x² = 9` under `x ≤ 0`. Deciding which subsystem an inequality should
ride along with has no correct answer in general, so refusing is the only honest option, and it is
pinned by a test. The decomposition itself is right to ignore inequalities; the refusal belongs on
the solve path.

`Graphs.jl` is a dependency for this. Tarjan is short enough to write, and its recursive form
overflows the stack on exactly the long chains this feature exists for; the established
implementation is iterative. Call `strongly_connected_components_tarjan` and not the exported
`strongly_connected_components`: the two are the same function today, but the exported name's
docstring states that the order of the components is *not* part of its API contract, and that order
is the entire basis of the solve order. Only the Tarjan name promises it.

### A named configuration, and what it is allowed to promise

*Decided 2026-09-14 — `notes/TODO.md` C16.*

Nothing in the package said which pairings of block and dataset were meaningful. `solve(block, data)`
accepts all of them, so four blocks and five scenarios is twenty calls of which perhaps five mean
anything, and the package had no opinion about which five.

A [`Problem`](@ref) is one of the five: a block, the data it is solved against, where it starts and
how it is solved. A [`ModelSpec`](@ref) is the set of them, in registration order.

**The construction check is on the block, not on the data.** A block is a value and cannot change
underneath the problem, so a structural guarantee made about it holds. A `Dataset` is mutable by
design — a scenario *is* a dataset that gets edited — so a data-dependent guarantee made at
construction would be stale exactly when it mattered. Missing data is caught at solve time, where it
is still exact. [`assert_solvable`](@ref) takes an optional dataset and draws the same line.

That split turned out to be worth more than the type. `diagnose(spec)` reports that `:baseline` is
not ready to run because the parameter it needs is what `:calibration` produces — the ordering
constraint of the whole workflow, visible without running anything and without anyone having
declared it.

**Which is why there is no dependency graph.** An experiment inferred the edges from datasets being
the same object, and `examples/multiModeModel.jl` showed why that cannot work here: `solve` is
non-mutating and returns a *fresh* dataset, so the package's own idiom breaks the identity link the
inference needs. The alternative, declaring the edges, was rejected for a better reason than
difficulty: a declared graph is a second statement of the ordering that can drift from the equations,
whereas readiness is derived from the actual state of the data and cannot. A declaration says what
should be true; the readiness check says what is.

**No accessors are exported for a `Problem`'s fields.** `data` and `options` are names a user will
want for their own variables, and an exported function turns that assignment into an error rather
than a shadow — the same cost recorded as `notes/crossCuttingFindings.md` #2. The fields are public
and read directly.

**Modes are values; there is no current mode.** Nothing holds a "the model is now in calibration
state" flag. That would cut against every other decision here — `swap`, `endogenize` and `solve` are
all non-mutating — and it is the thing that makes a script's behaviour depend on lines that ran
earlier somewhere else.

### Soft-linking needs a loop, not a coupling type

*Decided 2026-09-14 — `notes/TODO.md` C19.*

Two models maintained separately, coupled by a few exchanged quantities and solved in alternation.
The question was what structure this needs, and it was answered by writing one out by hand first
(`examples/softLink.jl`) rather than by designing.

**Cross-model transfer needs nothing.** `energy_data[q[s]] = macro_data[E[s]]` is a read of one
dataset and a write to another, and `Dataset` already refuses a variable belonging to the wrong model
— so a mis-wired coupling raises instead of returning a plausible number. A `Coupling` type holding
pairs of variables was considered and is not worth its own existence: it would buy nothing over an
assignment, and it would have to grow a transform argument the moment a coupling aggregates or
converts units, at which point a plain function is simpler than any signature.

**The loop does need help, because of how it fails.** Every individual solve in a diverging soft link
converges and reports success — each model answers the question it was handed, and the pair never
agrees. There is no symptom anywhere except that the exchanged quantities keep moving. A loop that
runs out of iterations and returns its last values is therefore a wrong answer delivered quietly,
which is the one failure mode this package is consistent about refusing. `fixed_point!` raises, with
`raise = false` for the case where the history is what is wanted.

This is the same lesson as C18 one level up. There, a cascade handed each subsystem's answer to the
next as exact and had no way to revisit it; here, a single pass hands one model's answer to the other
and stopping there is the identical mistake. The convergence test is what makes the difference, so it
is not optional.

**What is converged is the feedback, not everything transferred.** `exchanged` lists the cells whose
value at the *start* of a pass determines that pass. A quantity that a transfer overwrites before
anything reads it carries no state between passes; damping it would be undone immediately, and
including it in the convergence test measures something that was going to be overwritten anyway.

**Convergence is judged on the raw iterate, never on the damped blend.** The first implementation
blended and wrote back before measuring, which made the measured change `(1 - damping)` times the
real one — so the effective tolerance was `tol / (1 - damping)`, unbounded. Review found it reporting
*converged after one pass* on a link with multiplier 1.00002 that grows without bound, and found
accuracy silently degrading like `1 / (1 - damping)` on links that do converge. That is precisely the
false positive this function exists to prevent, arriving through the keyword meant to make it more
reliable. The regression test uses a multiplier just above 1 on purpose: an obviously explosive link
outruns the `(1 - damping)` shrink and hides the bug, which is why the original suite, whose only
expansion case doubled each pass, missed it.

Two consequences worth keeping. A converging pass returns **before** blending, so the datasets hold
values the models actually produced rather than a blend no solve ever saw. And the reported change is
measured in **multiples of the tolerance** rather than in anyone's units, so one number covers cells
of very different magnitude — with the raw magnitudes recorded separately as `scale`, because in
tolerance units a geometrically diverging link looks flat: its tolerance grows with it.

**Damping fixes overshoot, not expansion**, and the docstring says so because the distinction is not
obvious and the failure is silent. If a pass multiplies the error by `m`, damping makes it
`(1 - damping)·m + damping`. For `m < -1` — the models leapfrogging, the change alternating in sign —
some damping brings it inside `(-1, 1)`. For `m > 1` it does not, for any admissible value: a link
that walks away in one direction is miscoupled rather than under-damped. Both cases are pinned by
tests, the second precisely because a user will otherwise reach for damping and conclude the package
is at fault.

### Composing modes is function composition

*Decided 2026-09-14 — `notes/TODO.md` C20.*

The registry holds a handful of named modes well. A model whose states are a *product* — static or
dynamic closure, times calibration or baseline, times linked or unlinked — would need eight
registrations repeating six ingredients between them, which is where a registry of finished
`Problem`s stops paying.

It needs nothing. A mode is a `Block -> Block` function and functions already compose, so the eight
states are a loop over three axes with `identity` as each axis's "leave it alone" option. Measured on
the example model: eight modes from six ingredients in five lines, with `ready` reporting which of
them the data can support yet.

A `Mode` type carrying a block transformation, a data transformation and an options overlay was
considered. It would wrap `∘` in a name, and it would have to decide an application order that
Julia's own composition already fixes. The registry stays a registry of `Problem`s; what varies is
how the `Problem` was built, which is the caller's business.

Two properties make the idiom safe enough to recommend, both checked rather than assumed. Where a
`swap` and a `+` both apply they **commute** — the swap re-points one constraint, the sum unions the
unknowns — so composing in either order gives the same block, constraint for constraint and pairing
for pairing. And where they cannot commute, because the equation being re-pointed is in a block not
yet added, `swap` raises and names the variable rather than silently building something adjacent.

### A window of periods is a composition, not a restriction

*Decided 2026-09-14 — `notes/TODO.md` C21.*

Solving part of a horizon — periods 1 to 10 of fifty, one region of a multi-region model — needs the
equations *outside* the window gone, not merely their variables exogenised: an equation left in with
no unknown in it is a constant equation, true or false by accident of the data.

Nothing new is needed, provided the block is built as a composition in the first place. A block per
period, and a window is `compose(periods[a:b])`. Everything outside is exogenous and read from the
dataset by the ordinary substitution path, so a rolling horizon is a loop over windows sharing one
dataset — each window reads the previous one's answer with no mechanism of its own, the same way a
subsystem does in a block-triangular solve. Checked against solving the whole horizon at once: worst
disagreement 2.4e-10 over twenty periods in five windows (`archive/windowedSolve.jl`).

A window is a `Block -> Block` function, so it composes with the mode idiom above like any other axis.

**`restrict(block, group)` — keeping the constraints that determine a given set of variables — was
considered and deliberately not built.** It would serve someone who already has a whole-horizon block
written as one `@block` and wants to cut it down, which is a real position to be in. But it needs
three judgement calls with no obviously right answer: what to do with a solved constraint that is
unpaired and so cannot be attributed to any variable, what to do with `@check` constraints written
over the whole horizon, and whether a dropped equation should be an error or a silent omission.
Reopen it when a model exists that cannot reasonably be written per period — not before, because the
composition route has none of those questions.

### Combining many blocks is one pass, not a fold

*Decided 2026-09-14 — `notes/TODO.md` C22.*

`+` is non-mutating, which is right: a composed block is a value and neither part is disturbed. The
cost is that it copies both constraint vectors every time, so folding it over `n` blocks copies
`O(n²)` constraints. Measured at 0.32 s for 2,000 two-equation blocks, against 1.25 ms for a single
pass — and building a model out of many small blocks, one per period or per sector, is precisely the
idiom this package exists to support, so the quadratic path was on the main road rather than off it.

`compose(blocks)` applies the same rules in one pass, and `sum` over a `Vector` or `Tuple` of blocks
routes to it. `sum` over a **generator** cannot be intercepted without claiming a method far too
broad, so it still folds; `compose`'s docstring says so rather than leaving it to be discovered.

This is the second time non-mutating composition has cost something quadratic — `add_constraint!`
scanned every existing constraint for a duplicate pairing until C6 replaced it with a `Set`. The
pattern is worth naming: an operation that is cheap for two and used for two thousand.

### A declaration shorthand, under a name JuMP does not own

*Decided 2026-09-15 — `notes/TODO.md` C23.*

`@declare model begin ... end` is `JuMP.@variables` with a description as the last positional entry of
a row, and tags after `::` applying to every variable the block declares.

This does not reopen C8. Two things were conflated there and are separable: *what* metadata is
attached, and *where* it is written. C8 settled the first — metadata is keyed on `VariableRef`,
attached by function, never at a shadowed `@variables` — and this changes none of it, because the
macro expands to exactly the `describe!` and `tag!` calls a user would write by hand. What it changes
is the second, and only as sugar: the rows go to `JuMP.@variables` untouched and the return value is
JuMP's own tuple, so there is no second declaration mechanism to keep in step, and a model written
with `@variable` behaves identically.

The name is the whole reason this is a decision rather than a patch. `@variables` is a JuMP export, so
taking it would force every user of both packages to qualify — the same cost that ruled out `fix`. The
description slot is safe to claim because JuMP *rejects* a bare positional string today
("Unrecognized positional arguments"), which is a slot it cannot later want.

Descriptions attach **by tuple position**, not by parsing the name out of the row. `JuMP.@variables`
returns one element per row in row order, so the container is already in hand: there is nothing to
guess about which side of `0 <= x <= 1` is the variable, and anonymous rows — which have no name at
all — get their description and tags like any other. A parser over declaration heads would have been
a second, weaker copy of JuMP's own.

Tags are block-level only. Per-row tags are a `tag!` line, on the grounds that the exported surface is
the product: `::` inside a row would be a third place where a tag can be written, buying a line.

Two hygiene traps are recorded in the source because both are silent and neither is guessable: the
macro hands `JuMP.@variables` a **gensym escaped into the caller's scope**, since that macro escapes
its own arguments; and the whole nested macrocall is escaped, because hygiene otherwise descends into
its arguments and resolves the user's index sets in `ModularSystems` — `J` became `ModularSystems.J`.

## Open

**Whether slices return views** (C12) and **a sparse notation layer** (C13) are both deferred
deliberately rather than forgotten, each with the thing that would reopen it. C12 waits for a
measurement showing that slice reads or writes are actually hot — `Window`, `prepare_selection` and a
model-layout cache are a large surface to add on a guess. C13 waits for two or three real models: it
is a pure ergonomics question, whether `x[p, i, t]` with gaps returning zero is worth a wrapper array
when `x[k, t]` over an `IndexSet` already works.
