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

## 3. Measure the quantity you are asserting about, not a smoothed version of it

A convergence or tolerance check must read the raw quantity. Applying a transformation first —
damping, relaxation, averaging, normalisation — scales the measured residual, and therefore scales
the tolerance by the same factor, without anything saying so. `fixed_point!` blended its damped
iterate before measuring the change, which made the effective tolerance `tol / (1 - damping)`:
unbounded, so a heavily damped run reported convergence on a link that grows without bound.

This is finding #1 one level up. There the tolerance was wrong against the solver's own slop; here
the *measurement* was wrong and the tolerance was fine. Both end the same way — a check that looks
like it is passing.

**Tell.** A smoothing or relaxation parameter that makes something converge *faster* as it is turned
up. Real damping costs passes; it does not save them. Accuracy that quietly worsens as a stabilising
knob is turned up is the same signal.

**Habit.** In any loop that both transforms a value and tests it, measure before transforming, and
write the regression test with the transformation at its most aggressive setting. Choose the test
case near the stability boundary: a violently diverging case outruns the smoothing and hides the bug,
which is exactly how the first version of this suite missed it.

## 4. An operation that is cheap for two gets used for two thousand

Non-mutating composition is right for values and quadratic in bulk. `+` on a `Block` copies both
constraint vectors, which is correct and irrelevant for two blocks; folding it over 2,000 one-period
blocks copied `O(n²)` constraints and took 0.32 s against 1.25 ms for a single pass. `add_constraint!`
had the same shape earlier, scanning every existing constraint for a duplicate pairing.

The trap is that the modular idiom the package *recommends* — a block per period, a block per sector —
is exactly what turns the pairwise operation into a bulk one. The quadratic path is on the main road,
not off it.

**Tell.** A binary operator whose docstring also advertises `sum`, `reduce` or `foldl` over it. That
sentence is the bulk use case being documented without being implemented.

**Habit.** When a binary combiner copies its inputs, provide the n-ary form beside it and route
`sum` to it. Where the fallback cannot be intercepted — `sum` over a generator dispatches too
generically to claim — say so in the docstring rather than leaving it to be discovered by timing.
