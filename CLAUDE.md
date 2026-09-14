# ModularSystems.jl

## Project overview

A Julia package for **modular square systems of equations**: equation blocks paired to the endogenous
variables they determine, composed into a model, and solved. The deliverable is the package itself
plus its documentation — there is no paper and no results pipeline here.

The design borrows concepts from [SquareModels.jl](https://github.com/MartinBonde/SquareModels.jl)
(Martin Bonde) — blocks, endo-exo swapping, a model-level data dictionary — and **no code**. This is
an independent implementation with different interface preferences. Do not copy from it, and do not
assume its API decisions carry over; where this package differs, the difference is the point.

**The package is a skeleton.** It is built on **JuMP** — a model's state is a `JuMP.Model`, and
blocks are a layer over its variables and constraints. Beyond that the design is not settled:
`docs/src/design.md` records what has been decided and why, `notes/TODO.md` holds the open questions
(C2, what a block is; C3, how endo-exo swapping works).

Solver and plotting integrations belong in `ext/` as package extensions with weak dependencies, not
in `[deps]` — someone who only wants to solve a model should not pay for a plotting stack.

## Structure

Standard Julia package layout, plus the working-notes folders:

- `src/` — the package. One file per concept, included from `src/ModularSystems.jl`.
- `test/` — the suite, run by `Pkg.test()`. One `@testset` per source file, named after it.
- `docs/` — the Documenter site: `make.jl`, its own `Project.toml`, and `src/*.md`.
- `examples/` — runnable scripts, each self-contained and each cheap enough to actually run.
- `notes/` — live working notes, and the one open to-do list.
- `logs/` — detached-run scripts and their logs (gitignored except its README).
- `archive/` — history: past session logs, long-form findings, superseded plans. Indexed in
  `archive/INDEX.md`; excluded from default searches by `.rgignore`. Do not read it unless a live file
  points there or you are stuck on something the index names, and never restate its content into a
  live file — link to it.

## The environment

```
julia --project=. -e "using Pkg; Pkg.instantiate()"
julia --project=. -e "using Pkg; Pkg.test()"
julia --project=docs docs/make.jl
```

`--project=.` is not optional. Without it Julia silently uses the global environment, and a
dependency that is missing from `Project.toml` still resolves — so the package appears to work here
and fails for everyone else.

Julia 1.10.5 locally; `[compat]` declares `julia = "1.10"` and CI tests 1.10 and current.

- **`Manifest.toml` is gitignored**, which is the opposite of the research-project template's rule.
  A package must resolve against whatever its dependents already have; pinning a Manifest would hide
  a compat bound that is wrong. Reproducibility here comes from `[compat]`, not from a lockfile.
- **Add dependencies with `Pkg.add`, never by editing `Project.toml`** — a hand-added dep gets no
  `[compat]` entry, and a missing bound is how a package breaks on someone else's upgrade. State the
  reason for the dependency in `docs/src/design.md` when it is a design commitment rather than a
  utility.

## Key conventions

- **Language.** Julia. No Python in this repository.
- **The API is the product.** An exported symbol is a promise. Prefer exporting less and documenting
  it properly over exporting broadly; anything not exported can change freely. `checkdocs = :exports`
  means an export without a docstring fails the docs build — that is deliberate.
- **Documentation is part of the change, not a later pass.** A new concept gets its docstring and,
  if it changes how the package is used, a paragraph in the manual, in the same commit. Examples in
  docstrings go in `jldoctest` blocks so they are executed and cannot drift.
- **Tests.** The Julia idiom — `Test.jl`, `@testset`, run by `Pkg.test()` — not the standalone
  PASS/FAIL scripts used in the research projects. It is what CI, `julia-runtest` and every
  contributor expect. Write checks straight into the file that will keep them; do not build a
  scratch script and promote it later.
- **Discuss before building.** On design questions, lay out the options and what each commits us to
  rather than implementing the first one. Prefer an established package to a hand-rolled algorithm.
  When a question is settled, append the decision and its reasoning to `docs/src/design.md`.
- **Logs, at end of session.** After a full working session, *before shutting it down* — not during
  every interaction — append a short entry to `RESEARCH_LOG.md`.
- **Context budget, so the docs stay cheap to read.** A `README.md` stays under ~100 lines and holds
  orientation only. A log entry is at most ~10 lines: what changed, why, where to look. A lesson that
  recurs goes to `notes/crossCuttingFindings.md` once, as statement/tell/habit, cited by number;
  **its numbering is referenced from code and must not change.** Anything longer — measurements,
  investigations, superseded plans — goes to `archive/` with a pointer from the live file.
- **Docstrings and comments.** Keep only what a future session needs to *use or modify* the code
  correctly: the signature and what it returns, shape and ownership conventions where non-obvious,
  and genuine gotchas (why an argument must be explicit, a numerical trap that must not be
  reintroduced). Do not narrate design history, debugging process, or alternatives considered and
  rejected — that belongs in `RESEARCH_LOG.md` or, if it was a real decision, `docs/src/design.md`.
- **Long runs go detached.** Anything past a few minutes — a solver benchmark, a large sweep — is
  started as a detached job writing to `logs/`, not held inside a session. See `notes/detachedRuns.md`.

## Local gotchas

Things that cost an hour once and would cost it again. All Windows:

- PowerShell's `*>` redirection writes UTF-16, which every downstream reader gets wrong. Use the
  `cmd /c` pattern in `notes/detachedRuns.md`.
- Julia's first call into a large dependency pays a long compile latency. A test run that seems hung
  is usually precompiling; check before killing it, and do not "fix" it by adding a timeout.
- After adding a dependency, the **docs environment is stale**: `docs/Manifest.toml` still predates
  it, and `docs/make.jl` fails on `using ModularSystems` with "does not have X in its dependencies".
  `julia --project=docs -e "using Pkg; Pkg.resolve()"` fixes it. CI never sees this — it builds the
  docs environment from scratch — so it only ever bites locally.
- Documenter shells out to `git rev-parse HEAD`, so `docs/make.jl` fails in a repository with **no
  commits yet** — the error talks about remotes and not about the missing commit. `repo` is pinned
  explicitly in `make.jl`, so a commit is the only thing needed.
- `Pkg.test()` runs in a *separate* environment built from `[extras]`/`[targets]`. A package that the
  tests need but the package does not must be added to `[extras]` and listed in `targets.test`, or
  the suite fails with a bare `ArgumentError: Package X not found` that names no cause.
