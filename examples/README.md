# examples

Runnable scripts, each self-contained and each cheap enough that a reader will actually run it. An
example that takes minutes is a benchmark, and belongs in `test/` behind a flag or in `logs/` as a
detached run.

Run one against the package environment:

```
julia --project=. examples/<name>.jl
```

An example that appears in the manual is better written as a `jldoctest` block in `docs/`, where it is
executed on every docs build and cannot drift. Keep here what is too long for a doc page.

*(Empty — see `notes/TODO.md` item D2.)*
