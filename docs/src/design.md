# Design

The record of what has been decided and what has not. Decisions are appended here with their
reasoning, so a later reader can see what a change would cost. Open questions live in
`notes/TODO.md`; this page carries only what is settled.

## Settled

**Clean-room implementation.** The package borrows concepts from SquareModels.jl — equation blocks,
endo-exo swapping, a model-level data dictionary — and no code. This costs re-derivation and buys
freedom in the interface, which is the reason the package exists at all.

**The package sits on JuMP** (2026-09-14, `notes/TODO.md` C1). The three candidates were JuMP,
MathOptInterface alone, and a solver-agnostic core with JuMP as a package extension.

JuMP wins on the thing that matters for a small package: it already supplies the expression macros,
the variable and constraint containers, and the solver interfaces, and its users arrive fluent in
them. MathOptInterface alone would mean rebuilding that surface to no clear benefit, and a
solver-agnostic core would mean maintaining two interfaces before we know what the first one should
look like. SquareModels.jl made the same choice, which is also a compatibility argument: a model
written against one is recognisable to a reader of the other.

What this commits us to: the JuMP model is the state, and JuMP's `@variable`/`@constraint` idiom
shapes ours. The cost, if it turns out to be wrong, is an interface rewrite rather than a rewrite of
the solving logic — acceptable at this stage. `MathOptInterface` is not a direct dependency yet; add
it when a solver attribute actually needs reaching for, not pre-emptively.

**Solvers and plotting go in `ext/`, not `[deps]`.** Weak dependencies with package extensions, the
pattern SquareModels.jl uses for GAMS, GDXInterface and Makie. A user who only wants to build and
solve a model should not pay for a plotting stack. Nothing here yet — this is the shape to follow
when the first integration arrives.

## Open

**What a block is** (`notes/TODO.md` C2) and **how endo-exo swapping works** (C3). C3 is one of the
main reasons for a separate package from SquareModels.jl, so the preference it encodes should be
written down before anything is implemented.
