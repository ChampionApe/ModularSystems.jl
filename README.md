# ModularSystems.jl

A Julia package for **modular square systems of equations**: equation blocks paired to the endogenous
variables they determine, composed into a model, and solved. `CLAUDE.md` holds the working
conventions; this file is a map.

**Status: skeleton.** Built on [JuMP](https://jump.dev); beyond that the design is not settled and
nothing in the API is stable. `docs/src/design.md` has what is decided and why; `notes/TODO.md` is
the live list of what is not.

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

[SquareModels.jl](https://github.com/MartinBonde/SquareModels.jl) by Martin Bonde solves the same
class of problem and is where these ideas come from. This package is an independent implementation
with different interface preferences: it shares no code, is not a fork, and does not depend on it.
