# Research log

What happened and why, one entry per session, newest first, at most ~10 lines — **what changed, why,
where to look**. Not a transcript.

A lesson that would recur goes to `notes/crossCuttingFindings.md` once, cited by number, not here. A
design decision goes to `docs/src/design.md`, not here; the log entry says a decision was taken and
points at it. When this file passes a few hundred lines, move the old entries to
`archive/sessionLogs/` and index them in `archive/INDEX.md`.

Entries are written at the *end* of a session, not during it.

## 2026-09-15 (second session) — The manual stops destructuring, and the package is registered

RKB asked why SquareModels' `@variables` needs no `X, Y = ` line and ours seemed to. It does not:
`JuMP.@variable` binds each named row in the caller's scope, SquareModels expands to one such call per
row, and `@declare` inherits the same behaviour through `JuMP.@variables`. The assignment was habit,
taught by our own docs. Removed from the quickstart, the tag section, the `@declare` docstring and
`examples/labourMarket.jl`, with the point stated once — values are read and written through a
`Dataset`, the container is only the key. One new testset in `test/declare.jl` holds the binding,
which nothing checked before. 712 tests.

T2 closed: `version = "0.1.0"`, `TagBot.yml`, `CompatHelper.yml`, and `workflow_dispatch` on the docs
workflow because a TagBot tag does not trigger one. `CLAUDE.md` said T2 was all that was left, which
was wrong — C17, C12 and C13 are deferred behind triggers, not closed; fixed. Registered as
JuliaRegistries/General#168334, in the three-day waiting period for a new package.

MEE is the first use case and is now dev-linked to this working copy. The rules for the pair are in
`CLAUDE.md` here and in MEE's, in the same words; the only automation is the new `Examples` CI job,
because `examples/*.jl` ran nowhere — doctests do not cover them and `Pkg.test` does not include them,
so a harvested example could rot silently.

## 2026-09-15 — A declaration shorthand, and the data–model link compared

RKB asked whether variables could be declared many at a time with a description, as SquareModels'
`@variables` does. They can: `@declare` (C23, `src/declare.jl`) hands each row to `JuMP.@variables`
untouched, turns a trailing string into a `describe!`, and applies tags written after `::` to every
variable the block declares. It is sugar over the C8 functions, not a second mechanism, and the name
avoids JuMP's export — which is the part that made it a decision. 709 tests; the quickstart and
`examples/labourMarket.jl` now use it, so the trailing comments became real metadata.

The implementation lesson is that descriptions attach by **tuple position**, not by parsing names out
of declaration heads: `JuMP.@variables` returns one container per row, so `0 <= x <= 1` and anonymous
rows need no special case. Two hygiene traps are commented in the source; the second — hygiene
descending into a nested macrocall's arguments and resolving `J` as `ModularSystems.J` — has a
regression test.

Also compared our data–model link with theirs, at RKB's question. Same direction (data holds the
model) and both cache a layout in `model.ext`; we differ in keying on the MOI slot rather than the
variable name, which is why we need no revision counter and they get `d.σ` and name-keyed IO.

## 2026-09-14 — Structure for naming what a model can be solved as, and three things that needed nothing

RKB asked whether combinations of block, variables and data that are known to be solvable should be a
type, and whether the states a model can be solved in should be a settings structure. Both, roughly:
`SolveOptions` (C15), `Problem` and `ModelSpec` (C16). 670 tests. Branch `structure-exploration`,
revert tag `pre-structure-2026-09-14`.

The most useful finding is that the pairing is also a **perfect matching**, so `decompose` gets a
Dulmage–Mendelsohn split for free (C14). `diagnose` now names contested equations and undetermined
unknowns — a block can have zero degrees of freedom and still be structurally singular. But
`BlockTriangular` as a *solver* was measured at 2×–110× **slower**: entering an interior-point solver
costs more than a one-variable subsystem can amortise (250× on Ipopt's own time), and on a long
recursive chain it accumulates relative error where the path passes near zero (C18). Kept as a
convergence fallback only. Tables in `archive/decompositionMeasurements.md`.

Three things turned out to need no code at all, each settled by writing the case out by hand first:
cross-model transfer for soft links (C19), composing modes over orthogonal axes (C20, function
composition — eight modes from six ingredients in five lines), and index-restricted modes
(C21, a window is `compose(periods[a:b])`). What soft-linking *did* need was the loop, because every
individual solve in a diverging link reports success.

Two wrong-answer bugs, both found by review and both now pinned. `BlockTriangular` silently dropped
solved inequalities and returned the wrong root of x²=9 under x≤0. And `fixed_point!` measured its
convergence on the *damped* iterate, making the effective tolerance `tol/(1-damping)` — unbounded —
so it reported "converged after 1 pass" on a link that grows without bound. That second one is
findings #3; #4 records that `+` on blocks was quadratic in bulk, which `compose` fixes.

Open: C17 (small subsystems avoiding the solver) and the API trims a design review recommended —
`modes`/`keys` duplication, `overdetermined`/`underdetermined` reading as predicates.

## 2026-09-14 — Everything designed is now implemented

Closed the last code items: the swap interface (C3) as non-mutating `endogenize` / `exogenize` with
`swap` on top, and residuals (C7) as opt-in and paired-only. 391 tests. Only T2, registration,
remains open, and it is on hold pending RKB's review.

Two naming decisions worth remembering, both forced by JuMP's exports rather than by taste. `fix` and
`unfix` are JuMP exports, so the swap primitives are `endogenize` / `exogenize` — taking JuMP's names
would have forced every user of both packages to qualify the call, the same cost that ruled out
shadowing `@variables`. Check `names(JuMP)` before choosing an exported name.

The residual workflow turned out to need no machinery of its own: holding a variable at its observed
value and letting its residual absorb the gap is a `swap`. That is the clearest evidence so far that
building the primitive before the feature was right.

Descriptions rewritten throughout, including the GitHub repo description, which still advertised
*square* systems — a claim the C2 decision contradicted several commits earlier. Worth a habit: the
repo description is not in the working tree, so no amount of grepping the repo catches it.

Process note: a doc-update script aborted on its first failed assertion twice, silently skipping the
record updates after it and leaving C6 and then C7 reading as open while the code was already
committed. The helper now reports misses rather than stopping.

## 2026-09-14 — Cleared the open list down to three decisions

Implemented the optimization path, composition (C6), `diagnose` and source tracking (C11), tags (I6),
`IndexSet` (I8), and wrote the naming convention (C4). C12 (slice views) and C13 (sparse notation) are
deferred deliberately, each recorded with what would reopen it. 325 tests, docs building with the
manual now carrying the `@block` grammar reference.

Two defects found by measuring rather than reasoning. The binding-bound check had a tolerance of
1e-8, which could never fire: an interior-point solver relaxes bounds and stops slightly *outside*
them — Ipopt by 1.7e-8 in the case measured. Every earlier square-path test used an equality that
pins the variable exactly, so none of them caught it. And `add_constraint!` detected duplicate
pairings by scanning every existing constraint, making block construction quadratic; noticed while
designing composition, since that is what makes large blocks likely.

The grammar also gained fixed indices (`K[t0]`, `x[s ∈ S, :Equity, t ∈ T]`), which the parser had
rejected outright — surfaced by a composition test, not by design review.

Still open, all three waiting on RKB: the swap interface (C3), whether residuals stay (C7), and
whether to register (T2). C7 is coupled to C3, since the residual workflow is expressed through a
swap.

## 2026-09-14 — Square systems solve end to end

Implemented I1–I5: `Dataset` and the model layout, `VariableGroup`, `Block`, the square solve path,
and the `@block`/`@group` macros. 186 tests, docs building with a doctested quickstart, and
`examples/labourMarket.jl` running calibration → baseline → scenario.

Two places the plan was deliberately exceeded, both for the same reason — the alternative was a
silently wrong answer rather than a missing feature. I4 applies dataset bounds and runs the
binding-bound check, because the bounds layer built in I1 would otherwise have been accepted and
ignored. I5 evaluates `@check` constraints, because parsing them and never testing them is worse
than not having them.

Three bugs worth remembering, all caught by tests written alongside the code: `_ensure!` measured the
value vector *after* resizing and would have erased every stored value on growth; `VariableGroup`'s
generated three-field constructor claimed any three-argument call; and `JuMP.@build_constraint`
cannot take a pre-escaped body, so `@block` builds `ScalarConstraint`s directly. The last is recorded
in `src/macro.jl` because it is the kind of thing that gets "simplified" back.

Design confirmed by use: keying the solve on the unknown set rather than the pairing means the
calibration block reuses the behavioural equations unchanged. See `docs/src/design.md`.

## 2026-09-14 — Repository set up

Created the package skeleton and the working-notes layer, adapting the AI context management from
`projectTemplate` (CLAUDE.md conventions, RESEARCH_LOG, `notes/`, `archive/` + `.rgignore`, `/wrapup`)
and dropping everything paper-shaped — no `data/`, `results/`, `writing/`, Overleaf sync or
three-stage pipeline. Standard Julia layout on top: `Project.toml` with a fresh UUID, `src/`, `test/`,
a Documenter site in `docs/`, and CI + docs workflows.

Three deviations from the template, all deliberate and argued in `CLAUDE.md`: tests use the Julia
`Test.jl`/`Pkg.test()` idiom rather than the standalone PASS/FAIL scripts, `Manifest.toml` is
gitignored rather than committed, and there is no `juliaenv.md` — for a package the environment is
`Project.toml`.

Decided: clean-room implementation, no code from SquareModels.jl; and the package sits on **JuMP**
(TODO C1 closed, reasoning in `docs/src/design.md`), with solvers and plotting reserved for `ext/`
as SquareModels does. Still open: what a block is (C2) and how endo-exo swapping works (C3).
