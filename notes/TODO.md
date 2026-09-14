# TODO

The **one** open list. Closed work is not here: it is in `RESEARCH_LOG.md`. A second to-do file always
drifts out of step with this one.

Items are labelled so they can cite each other and be cited from a log entry: `C` code and design, `D`
documentation, `T` tests and infrastructure. Keep a label once assigned, even after the item closes.

## Implementation order

The first milestone is the narrowest slice that exercises every closed decision end to end: declare
variables, build a `Dataset`, construct a square `Block`, solve, write back, read the answer. Nothing
else. Everything deferred below is additive to it.

**I1. `Dataset` and the model layout.** Variable-id assignment, dense value vector, sparse lower/upper
maps, `copy`, elementwise arithmetic under the value-only rule. Everything sits on this, and it is
where the speed priority bites first.

**I2. `VariableGroup`.** Small and self-contained; needed by I4.

**I3. `Constraint` and `Block` as plain types**, with a programmatic constructor — no macro.

**I4. `solve` for the square path only.** Substitution, intermediate model, write-back.

**I5. `@block`**, as sugar over the tested core.

I4 comes before I5 deliberately. A macro over an untested core gives every failure two possible
causes, and macro errors are the hardest to make good. Building the programmatic API first also
leaves a non-macro path permanently available, which is what modularity looks like when someone wants
to assemble blocks in a loop.

Not in the first milestone: the objective path, bound enforcement, `@check`, residuals, swapping,
`IndexSet`, `diagnose`.

## Code and design

**C1. ~~Decide what the package sits on.~~** Closed 2026-09-14: JuMP, with solvers and plotting
reserved for package extensions. Reasoning in `docs/src/design.md`.

**C2. ~~Settle the block abstraction.~~** Closed 2026-09-14: one `Block` type — a collection of
constraints, each optionally paired with a variable and marked *solve* or *check*, plus a declared
set of unknowns and an optional objective. Squareness is a predicate, not a constructor invariant.
Reasoning in `docs/src/design.md`.

**C3. Settle the swap interface.** Semantics closed 2026-09-14 (the pairing is documentation plus a
square-solver precondition, so the primitive is `fix`/`free` over a variable group). Still open: is a
swap mutating or does it return a new block; macro or function; how cells are selected on each side.
Done looks like: the signature written into `docs/src/design.md` with a worked calibration example.

**C4. Decide the naming convention** for exported symbols, and write it into `CLAUDE.md` once. Cheap
now, expensive after the API has users. Includes what replaces `square_model` — the model
constructor can no longer be named for squareness.

**C5. ~~Design the `@block` grammar.~~** Closed 2026-09-14: a comma-separated head pairs a constraint
with a variable, `[i ∈ I], expr` is the unpaired indexed form, `@check` takes its constraint as an
argument, and `@unknowns` / `@objective` / `@square` are block-level declarations. Table, worked
examples and reasoning in `docs/src/design.md`.

**C6. State the composition rules** for `+` and `sum`: at most one objective, paired variables stay
distinct, unpaired constraints concatenate, and what happens to declared unknowns and the
square-intent marker.

**C7. Decide whether residuals stay.** Auto-creating a residual per endogenous variable buys real
debugging power (unfix the residual, fix the endogenous, solve, read the inconsistency) and doubles
the variable count. Meaningless for an unpaired constraint. At most opt-in and paired-only.

**C8. ~~Design the variable-group type.~~** Closed 2026-09-14: `VariableGroup`, an ordered set of
variable cells with a membership set, frozen at construction, no name field, not an `AbstractVector`.
Tags kept but attached by function (`tag!` / `tagged`) into `model.ext`, keyed on `VariableRef` so
they share the group's per-cell granularity — no shadowing of `JuMP.@variables`. `IndexSet` is the
coordinate-level twin. Reasoning in `docs/src/design.md`.

**C9. ~~Decide the data layer.~~** Closed 2026-09-14: a `Dataset` of layers over one key space — a
dense value vector, sparse lower/upper bound maps, and per-dataset solve metadata — with model
metadata shared across datasets. Problem bounds live here, intrinsic bounds stay on the JuMP
variable, arithmetic returns a value-only dataset, and a binding bound on a square solve raises.
Continuous variables only. Reasoning in `docs/src/design.md`.

**C10. ~~Decide whether sparse handling is in scope.~~** Closed 2026-09-14: yes, via coordinate
axes and `IndexSet`, not via a custom array type. Declaring over a coordinate axis is plain JuMP,
scales with variable count rather than the product of the axes (measured), and leaves no absent cells
for a `Zero()` sentinel to cover. Two implementation constraints fall out and are binding on C5:
`@block` must query containers for stored keys generically, and the expression walkers must tolerate
an additive-identity sentinel they do not define.

**C11. Name constraints that have no pairing.** `set_name(con, name(endogenous[i]))` is what makes
solver output and diagnostics readable, and it assumes a pairing. Unpaired constraints need a
fallback scheme. Small, easy to forget, and its absence shows up only when debugging a bad solve.
Depends on C5.

**C12. Decide whether slices return views.** SquareModels' `Window` makes `data[x[2025:2060]]` a view
that keeps model indices, which is what makes slices usable for printing and plotting, and it brings
`prepare_selection`, `refresh_model_layout!` and a caching layer with it. The recommendation stands:
refuse it until something demands it, and work with plain reads and broadcast assignment first. Open
so that it is refused deliberately rather than forgotten.

**C13. Decide whether to add a sparse *notation* layer.** All that remains of the old C10: whether
`x[p, i, t]` with gaps returning zero is worth a wrapper array on top of coordinate axes, given that
`x[k, t]` already works. Pure ergonomics, and better judged with two or three real models in hand.
Deferred deliberately; the C10 constraints keep it addable as a package extension.

## Documentation

**D1. Fill in the manual** once there is an implementation: `docs/src/index.md` needs a worked
example that runs as a doctest, not a description. The `@block` grammar table currently lives in
`docs/src/design.md`; it is user documentation and moves to the manual once the macro exists, leaving
only the reasoning behind on the design page.

**D2. First example script** in `examples/` — small enough to run in seconds, real enough to show why
the block abstraction earns its place.

## Tests and infrastructure

**T1. ~~Create the GitHub repository.~~** Closed 2026-09-14: `ChampionApe/ModularSystems.jl`, public,
both workflows green, Pages serving from `gh-pages` at
<https://championape.github.io/ModularSystems.jl/>.

**T2. Decide whether to register the package.** If yes, add `TagBot.yml` and `CompatHelper.yml`
workflows and a `[compat]` entry for every dependency — General registry rejects a package without
them. Deliberately deferred, not forgotten.

## Traps

Things that have bitten this project, short enough to read before every long run. Anything that recurs
graduates to `notes/crossCuttingFindings.md` with a number.
