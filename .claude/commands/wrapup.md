---
description: End-of-session pass — write the log entry, promote findings, update the docs that drifted
---

Close out this working session. Do these in order, and do them from what actually happened in the
session rather than from what was planned:

1. **Write the log entry in `RESEARCH_LOG.md`: at most ~10 lines.** What changed, why, and where to
   look — a file, a note, a manual page. Not a transcript, not a list of every command run. Newest
   entry first, dated.

2. **Record any decision in `docs/src/design.md`**, not in the log. The log entry says a decision was
   taken and points at it; the design page carries the reasoning and what the decision rules out. A
   decision that only lives in a log entry will be re-litigated in three months.

3. **Promote anything that will recur.** A lesson that cost time and would cost it again goes to
   `notes/crossCuttingFindings.md` as statement / tell / habit, with the **next** number — never
   renumber, the numbers are cited from code. Its long form, with the measurements, goes to
   `archive/findings_longform.md` under the same number. Cite the number from the code or README that
   prompted it.

4. **Update what drifted.** Only what materially changed: `README.md`'s status or file map;
   `notes/TODO.md` (open items only — closed work moves to the log, it is not ticked off in place);
   `CLAUDE.md` if a convention changed; the manual if the API did.

5. **Check the package still builds clean.** `Pkg.test()` passes, and the docs build has no
   `checkdocs` or doctest failure — an export added this session without a docstring breaks the docs
   workflow, and it is cheaper to find now than in CI.

6. **Check the size caps.** A README over ~100 lines or a live note that has become a long-form
   investigation goes to `archive/` with a pointer left behind — `git mv`, and index it in
   `archive/INDEX.md`.

7. **Report** what you wrote and what you deliberately did not, then stop. Do not commit unless asked.
