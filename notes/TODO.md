# TODO

The **one** open list. Closed work is not here: it is in `RESEARCH_LOG.md`. A second to-do file always
drifts out of step with this one.

Items are labelled so they can cite each other and be cited from a log entry: `C` code and design, `D`
documentation, `T` tests and infrastructure. Keep a label once assigned, even after the item closes.

## Code and design

**C1. ~~Decide what the package sits on.~~** Closed 2026-09-14: JuMP, with solvers and plotting
reserved for package extensions. Reasoning in `docs/src/design.md`.

**C2. Settle the block abstraction.** What a block *is* — equations plus the endogenous variables they
determine — and what the constructor takes. The open sub-questions: are variables referred to by
symbol or by object; is squareness checked at construction or at assembly; does a block own its data
or reference the model's. Unblocked by C1.

**C3. Settle endo-exo swapping.** Whether a swap mutates a block, returns a new one, or is a solve-time
argument. RKB's preference here is one of the main reasons for a separate package from SquareModels.jl
— write down what the preference actually is before implementing. Depends on C2.

**C4. Decide the naming convention** for exported symbols, and write it into `CLAUDE.md` once. Cheap
now, expensive after the API has users.

## Documentation

**D1. Fill in the manual** once C1–C3 land: `docs/src/index.md` needs a worked example that runs as a
doctest, not a description.

**D2. First example script** in `examples/` — small enough to run in seconds, real enough to show why
the block abstraction earns its place.

## Tests and infrastructure

**T1. Create the GitHub repository** at `ChampionApe/ModularSystems.jl`, push, and check both
workflows go green. The docs workflow deploys via `contents: write` and needs GitHub Pages enabled
for the repository (Settings → Pages → source: GitHub Actions or the `gh-pages` branch).

**T2. Decide whether to register the package.** If yes, add `TagBot.yml` and `CompatHelper.yml`
workflows and a `[compat]` entry for every dependency — General registry rejects a package without
them. Deliberately deferred, not forgotten.

## Traps

Things that have bitten this project, short enough to read before every long run. Anything that recurs
graduates to `notes/crossCuttingFindings.md` with a number.
