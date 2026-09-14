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

Everything on the implementation list is done.

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

**C7. ~~Decide whether residuals stay.~~** Closed 2026-09-14: kept, but opt-in via `with_residuals`
and paired-only — never automatic. The debugging workflow is expressed as a `swap`, so it needed no
machinery of its own. Reasoning in `docs/src/design.md`.

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

**C14. ~~Decide whether the pairing should drive a decomposition.~~** Closed 2026-09-14: yes for
diagnosis, no for speed. The pairing is a perfect matching, so `decompose` gets the
Dulmage–Mendelsohn split for the cost of reading it; `diagnose` now names contested equations and
undetermined unknowns, which a degrees-of-freedom count cannot see. `BlockTriangular` is kept as a
**convergence fallback and not an optimisation** — measured at 2× to 110× slower, because entering an
interior-point solver costs more than a scalar subsystem can amortise. Reasoning in
`docs/src/design.md`, tables in `archive/decompositionMeasurements.md`.

**C15. ~~Make the solve settings a value.~~** Closed 2026-09-14: `SolveOptions`, with every field
still accepted as a keyword override. The optimizer became a per-solve setting rather than model
state. Reasoning in `docs/src/design.md`.

**C16. ~~Decide how the states a model can be solved in are named and held.~~** Closed 2026-09-14:
`Problem` for one checked configuration, `ModelSpec` for the set. The construction check is on the
block, never on the data; readiness against the data replaces a dependency graph, and an inferred one
was tried and rejected with the reason recorded. Reasoning in `docs/src/design.md`.

**C17. Decide whether small subsystems should avoid the solver entirely.** Open. A scalar subsystem
that is affine in its unknown after substitution has a closed-form answer, and three of every four
subsystems in the measured model are scalar. This is the only route by which `BlockTriangular` could
become a speed win rather than a convergence one. It does **not** obviously pay: the arithmetic in
`archive/decompositionMeasurements.md` §5 shows that removing the scalar solves alone still leaves
the block-triangular path an order of magnitude behind on the model measured. Reopen with a model
large enough to reach the region where the two were converging (past ~21,500 unknowns), not before.

**C18. ~~Find out why `BlockTriangular` fails at 43,000 unknowns when monolithic does not.~~**
Closed 2026-09-14. It is accumulated **relative** error, not an unstable root — the first hypothesis
was measured and refuted. A cascade solves each subsystem to an absolute tolerance and hands the
answer on as exact; where the path passes near zero that is a large relative error, carried for the
rest of the chain with nothing able to correct it. Worst residual 2,700× monolithic at 700 periods,
infeasible at 1,000. A residual check does **not** catch it, because both answers are valid to
absolute tolerance. Reasoning and tables in `archive/decompositionMeasurements.md` §7; the
consequence is in `BlockTriangular`'s docstring.

**C19. ~~Soft-linked models: iterative coupling between separate models.~~** Closed 2026-09-14,
raised by RKB the same day. Answered by writing one out by hand first (`examples/softLink.jl`):
cross-model transfer needs **nothing** — it is `dest[v] = src[w]`, and `Dataset` already refuses a
foreign variable — and a `Coupling` type would buy nothing over an assignment. What needed building
was the loop, because every individual solve in a diverging link succeeds and reports success, so a
loop that runs out of passes and returns its last values is a wrong answer with no symptom.
`fixed_point!` raises. Reasoning in `docs/src/design.md`.

**C20. ~~Composable modes across orthogonal axes.~~** Closed 2026-09-14: nothing to build. A mode is
a `Block -> Block` function and functions already compose, so a three-axis product is a loop with
`identity` as each axis's no-op — measured at eight modes from six ingredients in five lines. `swap`
and `+` commute where both apply, and `swap` raises where they cannot, both checked. Reasoning in
`docs/src/design.md`; the idiom is in the manual under *Modes over several axes*.

**C22. ~~Combining many blocks was quadratic.~~** Closed 2026-09-14: `compose(blocks)` does it in
one pass and `sum` over a vector or tuple routes to it. Folding `+` copied `O(n²)` constraints —
0.32 s for 2,000 two-equation blocks, 1.25 ms now. Found while testing whether C21 could be handled
by composing per-period blocks, which it can. Reasoning in `docs/src/design.md`.

**C21. Index-restricted modes.** Open. "Solve periods 1–10 only", or one region of a multi-region
model, is a real modelling need with no answer in the package. `examples/multiModeModel.jl` sidesteps
it by writing two different closure blocks (`accumulation` and `steady`), which works but does not
generalise: it cannot express *the same* block over a subset of its index set. `IndexSet` is the
obvious raw material. Related to C20, since a horizon is another orthogonal axis.

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
