# ModularSystems.jl

[![CI](https://github.com/ChampionApe/ModularSystems.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/ChampionApe/ModularSystems.jl/actions/workflows/CI.yml)
[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://championape.github.io/ModularSystems.jl/)

Modular framework for building, calibrating and solving economic models in Julia.

Models are assembled from composable **blocks** of constraints. Each constraint may be paired with the
variable it determines — square systems get a dedicated solver — but a block may equally carry an
objective and be solved as an optimization problem.

`CLAUDE.md` holds the working conventions; this file is a map.

**Status: both solve paths work.** `Dataset`, `VariableGroup`, `Block`, the `@block` macro, the
square solve path and the optimization path are tested end to end — calibration, baseline, scenario
and minimum-distance estimation. Blocks compose with `+`, and `diagnose` reports a system's shape and its structural problems before
a solver runs. Tags, `IndexSet`, sparse patterns and endo-exo swapping (`swap` / `endogenize` / `exogenize`) work.
Residuals are available opt-in for locating inconsistent data. Nothing in the API is stable.

`docs/src/design.md` has what is decided and why; `notes/TODO.md` has the open questions and the
implementation order.

## Layout

| | |
|---|---|
| `src/` | the package; one file per concept, included from `src/ModularSystems.jl` |
| `test/` | the suite, run by `Pkg.test()`; one `@testset` per source file |
| `docs/` | the Documenter site — `make.jl`, its own `Project.toml`, and the manual in `src/` |
| `examples/` | runnable scripts, each self-contained |
| `notes/` | the live working notes |
| `logs/` | detached-run scripts and their output (gitignored except its README) |
| `archive/` | history, indexed in `archive/INDEX.md`; kept out of searches by `.rgignore` |

`notes/` holds three files: `TODO.md` (the one open list), `crossCuttingFindings.md` (lessons that
recurred, cited **by number** from code — never renumbered), and `detachedRuns.md` (how a long run is
launched so it survives the session).

`RESEARCH_LOG.md` is the session log: what happened and why, written at the **end** of a session.

## How to run

```
julia --project=. -e "using Pkg; Pkg.instantiate()"
julia --project=. -e "using Pkg; Pkg.test()"
```

To build the documentation locally (first run installs Documenter into `docs/`):

```
julia --project=docs -e "using Pkg; Pkg.develop(PackageSpec(path = pwd())); Pkg.instantiate()"
julia --project=docs docs/make.jl
```

The site lands in `docs/build/`, which is gitignored — CI builds and deploys the published copy.

`--project` is not optional in either command: without it Julia uses the global environment and a
dependency missing from `Project.toml` still resolves, so the package appears to work here and fails
for everyone else.

## Relation to SquareModels.jl

Very similar to [SquareModels.jl](https://github.com/MartinBonde/SquareModels.jl) at its core, with
different approaches to inequalities, variable bounds and a number of other things. An independent
implementation: no shared code, not a fork, and no dependency on it.
