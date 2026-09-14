# ModularSystems.jl

A Julia package for **modular systems of equations**: constraints collected into composable blocks,
each constraint optionally paired with the variable it determines. Square systems — as many equations
as unknowns — are the common case and get a dedicated solver, but they are not a requirement: a block
may carry an objective and be solved as an optimization problem instead.

!!! warning "Early days"
    The package is a skeleton. It is built on [JuMP](https://jump.dev), and the rest of the design is
    being settled first — see [Design](@ref) for what has been decided and what has not. Nothing in
    the API is stable.

## Installation

```julia
julia> using Pkg; Pkg.develop(url = "https://github.com/ChampionApe/ModularSystems.jl")
```

## Blocks, pairings and squareness

A **block** is a composable collection of constraints over a JuMP model, together with the set of
variables being solved for and, optionally, an objective. Blocks are developed, tested and documented
one at a time, then summed into the system you actually solve.

Each constraint may be **paired** with the variable it is understood to determine. The pairing is
documentation and a precondition: it names constraints in solver output and diagnostics, and it is
what the square solver checks before it runs. It does not order the system or drive the solution
write-back, and in a block with an objective it is inert.

A system is **square** when it has no objective and every solved constraint is an equality paired
with a distinct variable, together covering the unknowns. That is the common case in macroeconomic
modelling and it gets a dedicated solve path. It is not a requirement — the number that generalises
is the degrees of freedom, which is defined either way.

Calibration is then not a special mode: it is the same block with a different partition of variables
into unknown and fixed.

## Relation to SquareModels.jl

[SquareModels.jl](https://github.com/MartinBonde/SquareModels.jl) by Martin Bonde solves the same
class of problem and is where these ideas come from. ModularSystems.jl is an independent
implementation with different interface preferences; it shares no code and is not a fork.
