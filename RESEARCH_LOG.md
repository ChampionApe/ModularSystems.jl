# Research log

What happened and why, one entry per session, newest first, at most ~10 lines — **what changed, why,
where to look**. Not a transcript.

A lesson that would recur goes to `notes/crossCuttingFindings.md` once, cited by number, not here. A
design decision goes to `docs/src/design.md`, not here; the log entry says a decision was taken and
points at it. When this file passes a few hundred lines, move the old entries to
`archive/sessionLogs/` and index them in `archive/INDEX.md`.

Entries are written at the *end* of a session, not during it.

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
