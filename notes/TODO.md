# TODO

The **one** open list. Closed work is not here: it is in `RESEARCH_LOG.md`. A second to-do file always
drifts out of step with this one.

Items are labelled so they can cite each other and be cited from a log entry: `C` code and design, `D`
documentation, `T` tests and infrastructure. Keep a label once assigned, even after the item closes.

## Implementation order

The first milestone is the narrowest slice that exercises every closed decision end to end: declare
variables, build a `Dataset`, construct a square `Block`, solve, write back, read the answer. Nothing
else. Everything deferred below is additive to it.

**I1. ~~`Dataset` and the model layout.~~** Closed 2026-09-14. `src/layout.jl`, `src/dataset.jl`,
56 tests. Slots come from JuMP's own `MOI.VariableIndex`, so there is no id map — but deletion leaves
a permanent gap, so storage is sized by the highest slot and never by `num_variables`. A `Dataset` is
a broadcast scalar, which is what makes `scenario ./ baseline .- 1` one pass and one allocation
rather than cell-by-cell.

**I2. ~~`VariableGroup`.~~** Closed 2026-09-14. `src/group.jl`.

**I3. ~~`Constraint` and `Block` as plain types.~~** Closed 2026-09-14. `src/block.jl`. Constraints are
unregistered `JuMP.ScalarConstraint`s, so building a block costs no MOI work.

**I4. ~~`solve` for the square path.~~** Closed 2026-09-14. `src/solve.jl`. Includes bound application
and the binding-bound check, which were listed as deferred — silently ignoring the bounds layer built
in I1 would have been a wrong-answer hazard.

**I5. ~~`@block`.~~** Closed 2026-09-14. `src/macro.jl`, plus `@group` sharing its index parser.
`@check` and its post-solve evaluation came with it, for the same reason as the bounds.

**I7. ~~Implement the optimization path.~~** Closed 2026-09-14. The objective is substituted like any
other expression and attached to the same intermediate model, so the two paths differ only at the
tail, as the C3 decision predicted. A binding bound is recorded rather than raised here. The bound
tolerance had to be loosened to 1e-6: an interior-point solver stops slightly outside a bound, so a
tolerance at solver precision detects nothing — pinned by a regression test.

**I6. ~~Implement tags.~~** Closed 2026-09-14. `src/tags.jl`: `tag!` / `untag!` / `tags` / `has_tag`
/ `tagged`, and `describe!` / `description`, in `model.ext` and keyed on `VariableRef` so a tag
applies to a cell and `tagged` can return a genuine `VariableGroup`. `JuMP.@variables` is untouched,
and a test asserts it still accepts every declaration form.

**I8. ~~Implement `IndexSet`.~~** Closed 2026-09-14. `src/indexset.jl`, with `select_axes` and
`group_by`. Tests confirm it works as a JuMP axis with no scan, and that `group_by` replaces summing
over one index of a sparse variable.

I4 before I5 was the right call: two macro bugs (a pre-escaped body handed to
`JuMP.@build_constraint`, and `_parse_head(nothing)`) were easy to localise because everything under
them was already tested.

Still not implemented: residuals (C7), which is the last open code item.

## Code and design

**C1. ~~Decide what the package sits on.~~** Closed 2026-09-14: JuMP, with solvers and plotting
reserved for package extensions. Reasoning in `docs/src/design.md`.

**C2. ~~Settle the block abstraction.~~** Closed 2026-09-14: one `Block` type — a collection of
constraints, each optionally paired with a variable and marked *solve* or *check*, plus a declared
set of unknowns and an optional objective. Squareness is a predicate, not a constructor invariant.
Reasoning in `docs/src/design.md`.

**C3. ~~Settle the swap interface.~~** Closed 2026-09-14: non-mutating `endogenize` / `exogenize` over
a variable group, with `swap(block, new => old)` re-pointing the pairing on top. Named for the domain
rather than `fix`/`free`, which JuMP exports. Cells are selected with `@group`, so there is no third
index syntax. Reasoning in `docs/src/design.md`.

**C4. ~~Decide the naming convention.~~** Closed 2026-09-14, written into `CLAUDE.md`: `CamelCase`
types, `SCREAMING_CASE` enum values, lowercase functions with predicates run together and everything
else underscore-separated, `!` for mutation, leading underscore for internals.

**C5. ~~Design the `@block` grammar.~~** Closed 2026-09-14: a comma-separated head pairs a constraint
with a variable, `[i ∈ I], expr` is the unpaired indexed form, `@check` takes its constraint as an
argument, and `@unknowns` / `@objective` / `@square` are block-level declarations. Table, worked
examples and reasoning in `docs/src/design.md`.

**C6. ~~State the composition rules.~~** Closed 2026-09-14: constraints concatenate, pairings must stay
distinct, at most one objective, unknowns union (and stay derivable if neither part declared any), and
the result is never marked square — `assert_square!` re-asserts. Reasoning in `docs/src/design.md`.
Building a block is no longer quadratic in its size: duplicate pairings are detected with a `Set`.

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

**C11. ~~Name constraints that have no pairing.~~** Closed 2026-09-14: `constraint[n]` by position in
the solver, plus a `file:line` source recorded by `@block` on every entry, which is what `diagnose`
and a failed `@check` report. Reasoning in `docs/src/design.md`.

**C12. ~~Decide whether slices return views.~~** Deferred deliberately 2026-09-14. Plain reads and
broadcast assignment are enough so far; `Window`, `prepare_selection` and a model-layout cache are a
large surface to add on a guess. Reopen when a measurement shows slice access is hot.

**C13. ~~Decide whether to add a sparse notation layer.~~** Deferred deliberately 2026-09-14.
`IndexSet` plus coordinate axes covers the capability; whether `x[p, i, t]` with gaps returning zero
is worth a wrapper array is ergonomics, and better judged against two or three real models. The C10
constraints keep it addable as a package extension.

## Documentation

**D1. ~~Fill in the manual.~~** Closed 2026-09-14: `docs/src/index.md` has a doctested quickstart,
composition, bounds, the optimization path, and a `Reference` section carrying the `@block` grammar
table. `docs/src/design.md` keeps only the reasoning.

**D2. ~~First example script.~~** Closed 2026-09-14: `examples/labourMarket.jl` calibrates, solves a
baseline and runs a scenario, showing that calibration is the same equations with a different unknown
set.

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
