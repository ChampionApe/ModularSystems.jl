# examples

Runnable scripts, each self-contained and each cheap enough that a reader will actually run it. An
example that takes minutes is a benchmark, and belongs in `test/` behind a flag or in `logs/` as a
detached run.

Examples need a solver, which the package environment deliberately does not carry. Run them against
the docs environment, which has both the package and Ipopt:

```
julia --project=docs examples/<name>.jl
```

Do **not** add the solver to `test/Project.toml` to run an example — see `CLAUDE.md`.

An example that appears in the manual is better written as a `jldoctest` block in `docs/`, where it is
executed on every docs build and cannot drift. Keep here what is too long for a doc page.

| | |
|---|---|
| `labourMarket.jl` | calibrate to observed data, solve a baseline, run a scenario. Shows that calibration is the same equations with a different unknown set |
