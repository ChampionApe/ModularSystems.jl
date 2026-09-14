# ModularSystems.jl

A Julia package for **modular square systems of equations**: equation blocks paired to the
endogenous variables they determine, composed into a model, and solved.

!!! warning "Early days"
    The package is a skeleton. It is built on [JuMP](https://jump.dev), and the rest of the design is
    being settled first — see [Design](@ref) for what has been decided and what has not. Nothing in
    the API is stable.

## Installation

```julia
julia> using Pkg; Pkg.develop(url = "https://github.com/ChampionApe/ModularSystems.jl")
```

## What "square" means here

A square system has as many equations as endogenous variables. Stating the pairing *explicitly* —
this block of equations determines these variables — buys three things that a flat list of
constraints does not:

1. **A dimension check that is local.** A block that is not square is wrong on its own, before the
   model is assembled, and the error names the block rather than the model.
2. **Calibration as a swap.** Turning a parameter endogenous and an outcome exogenous is a
   re-pairing within a block, not a rewrite of the equations.
3. **Composition.** Blocks can be developed, tested and documented one at a time.

## Relation to SquareModels.jl

[SquareModels.jl](https://github.com/MartinBonde/SquareModels.jl) by Martin Bonde solves the same
class of problem and is where these ideas come from. ModularSystems.jl is an independent
implementation with different interface preferences; it shares no code and is not a fork.
