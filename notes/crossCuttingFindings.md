# Cross-cutting findings

Findings that recurred, written **once** and cited by number from code and READMEs. Each entry is
three things: the **statement**, the **tell** (how you notice it happening), and the **habit** (what to
do instead). The long-form version, with the measurements behind it, goes in
`archive/findings_longform.md` under the same number.

**Do not renumber.** A number here is a reference from source comments; renumbering silently breaks
every citation. Append; when a finding is superseded, say so in place and keep the number.

A finding earns its place by having cost time twice. One-off bugs belong in a log entry.

## 1. A tolerance that tests solver output must be looser than the solver's own slop

A check on whether a solver landed *on* something — a bound, a target, a threshold — cannot use
solver precision as its tolerance. Interior-point solvers relax bounds and stop slightly outside
them: Ipopt by about 1.7e-8 below a lower bound, measured. A check written at 1e-8 is not merely
strict, it never fires at all, and it looks exactly like a check that is passing.

**Tell.** A safety check that has never once triggered, on a codebase where every test of it uses an
exact-equality case that pins the value independently.

**Habit.** Measure the solver's actual deviation before choosing the tolerance, scale it by the
magnitude of the thing being compared, and write a regression test that asserts the *tight* tolerance
misses while the condition genuinely holds. Tightening such a tolerance disables a check silently
rather than failing, so it needs a test that fails when someone does.

## 2. A name that clashes with a dependency's export costs every user, not just you

Exporting a name the package's own dependency exports makes Julia refuse to resolve it: every user of
both must qualify every call. The cost is paid by users forever, to save one renaming now.

**Tell.** A README that imports a dependency selectively (`import JuMP` plus `using JuMP: Model`)
rather than plainly — that is usually a collision being worked around, not a style choice.

**Habit.** Check `names(Dep)` before choosing an exported name. This ruled out `fix`/`free` for the
swap primitives (JuMP exports `fix` and `unfix`) and was one of the arguments against shadowing
`@variables`.
