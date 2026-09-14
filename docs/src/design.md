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
reported, not raised. An opt-out keyword follows `presolve_diagnostics`.

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

One macro covers both kinds of system:

| Form | Meaning |
|---|---|
| `x, expr` | constraint paired with `x` |
| `x[i ∈ I], expr` | indexed, paired with `x[i]` |
| `[i ∈ I], expr` | indexed, unpaired |
| `expr` | scalar, unpaired |
| `@check expr "msg"` | role = check; evaluated after a solve, never solved |
| `@unknowns ...` | declares the unknown set |
| `@objective Min expr` | attaches an objective |
| `@square` | asserts squareness, checked at construction |

A pairing on an inequality is an error, since an inequality determines nothing. `@unknowns` is
required exactly when some solved constraint is unpaired; in a fully paired block the unknowns are
derivable.

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

## Open

**The swap interface** (`notes/TODO.md` C3, narrowed). The semantics are settled; the surface is not — mutating or
returning a new block, macro or function, and how cells are selected on each side.

**Composition rules** (C6). At most one objective across a sum; paired variables stay distinct;
unpaired constraints concatenate. Needs stating properly, including what happens to declared
unknowns and to the square-intent marker.

**Whether residuals stay** (C7). Auto-creating a residual per endogenous variable is a GAMS habit
that buys real debugging power and doubles the variable count. It is meaningless for an unpaired
constraint, so at most it is opt-in and paired-only.
