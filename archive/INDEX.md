# Archive index

History. Nothing here is read routinely: `.rgignore` keeps `archive/` out of default searches, so a
plain search will not see it. Read a file by path when a live note points here, or search it
explicitly (`rg --no-ignore`, or a search scoped to `archive/`).

**Never restate archive content into a live file** — link to it. The point of the archive is that the
live files stay small enough to read in full at the start of a session.

## What goes here

- session log entries, once `RESEARCH_LOG.md` passes a few hundred lines (move them to
  `archive/sessionLogs/`);
- the long-form version of a cross-cutting finding, with the measurements behind it
  (`archive/findings_longform.md`, same numbers as `notes/crossCuttingFindings.md`);
- plans that have been executed or abandoned, and closed to-do files;
- an API or a manual page as it stood before being replaced, if the replacement lost something worth
  recovering.

Archive by `git mv`, so the history follows the file.

## Contents

- `sparseDeclarationBenchmark.jl` — the measurement behind the C10 decision that sparsity is handled
  by coordinate axes rather than a custom array type. Cited from `docs/src/design.md`. Frozen
  2026-09-14.
- `decompositionMeasurements.md` — the evidence behind C14: block-triangular solving is 2× to 110×
  *slower* than monolithic, because entering an interior-point solver has a fixed cost a
  one-variable subsystem cannot amortise; it converges from slightly more starting points; and the
  decomposition itself costs microseconds per unknown, which is what makes it worth having as a
  diagnostic. Cited from `docs/src/design.md`. Frozen 2026-09-14.
- `decompositionBenchmark.jl`, `robustnessSweep.jl`, `subsystemFailure.jl`, `cascadeDrift.jl` — the
  scripts behind that file, so its tables can be rerun rather than believed. Frozen 2026-09-14.
- `modeComposition.jl` — the measurement behind C20: eight modes from six ingredients in five lines
  by composing `Block -> Block` functions, and a check that `swap` and `+` commute. Frozen
  2026-09-14.
- `windowedSolve.jl` — the measurement behind C21: a rolling horizon in five windows agrees with the
  whole-horizon solve to 2.4e-10, using only `compose`. Frozen 2026-09-14.
