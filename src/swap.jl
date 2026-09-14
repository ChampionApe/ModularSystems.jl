# Moving variables between the unknown set and the fixed set.
#
# The primitive is membership of the unknown set, which means the same thing whether the block is a
# square system or an optimization problem. Re-pointing a pairing is the square-case extra, not the
# operation itself — which is why `swap` is built on `exogenize`/`endogenize` rather than beside them.
#
# These are `exogenize`/`endogenize` rather than `fix`/`free` because JuMP exports `fix` and `unfix`.
# Taking those names would force every user of both packages to qualify the call, and these are the
# words this literature already uses.

_rebuild(b::Block, constraints, paired, declared, assert_square) =
    Block(b.model, constraints, paired, declared, b.objective, assert_square)

"""
    endogenize(b::Block, items...) -> Block

A copy of the block with those variables added to its unknown set. Accepts anything
[`VariableGroup`](@ref) accepts — variables, containers, groups.

Non-mutating: the original is untouched, so a calibration variant is a value rather than a copy that
must be made before editing.

The result is **not** marked square, since adding an unknown changes the shape. Re-assert with
[`assert_square!`](@ref) if it still holds.
"""
function endogenize(b::Block, items...)
    g = VariableGroup(b.model, items...)
    return _rebuild(b, copy(b.constraints), copy(b.paired), unknowns(b) ∪ g, false)
end

"""
    exogenize(b::Block, items...) -> Block

A copy of the block with those variables removed from its unknown set. They are then substituted from
the dataset at solve time like any other exogenous variable.

Raises if a variable is determined by a constraint in this block: removing it would leave an equation
determining something that is no longer solved for. Use [`swap`](@ref) to re-point that constraint at
a different variable instead.

The result is not marked square; see [`endogenize`](@ref).
"""
function exogenize(b::Block, items...)
    g = VariableGroup(b.model, items...)
    for v in g
        v in b.paired && throw(ArgumentError(
            "$(JuMP.name(v)) is determined by a constraint in this block, so it cannot simply be " *
            "exogenised; use swap to re-point that constraint at another variable"))
    end
    return _rebuild(b, copy(b.constraints), copy(b.paired), setdiff(unknowns(b), g), false)
end

"""
    swap(b::Block, pairs::Pair...) -> Block

A copy of the block with each `new => old` pair exchanged: `new` becomes an unknown, `old` becomes
exogenous, and the constraint that determined `old` now determines `new`.

This is calibration. The equations do not change — only which variable each one is understood to
determine, and which variables are solved for:

```julia
calibration = swap(behavioural, mu => L, rho => w)
```

Either side may be a variable, a container or a group. Group sides are paired **in iteration order**
and must have equal length, which is why a [`VariableGroup`](@ref) is ordered. Use `@group` when the
cells need selecting:

```julia
calibration = swap(behavioural, @group(mu[j in J]) => @group(L[j in J]))
```

Unlike [`endogenize`](@ref) and [`exogenize`](@ref), a swap preserves the shape of the system — one
pairing is re-pointed, the counts do not move — so a block declared square stays declared square and
is re-checked here.
"""
function swap(b::Block, pairs::Pair...)
    constraints = copy(b.constraints)
    paired = copy(b.paired)
    news = VariableRef[]
    olds = VariableRef[]

    for (lhs, rhs) in pairs
        new_side = VariableGroup(b.model, lhs)
        old_side = VariableGroup(b.model, rhs)
        length(new_side) == length(old_side) || throw(DimensionMismatch(
            "swap pairs $(length(new_side)) variables with $(length(old_side)); " *
            "each side of a swap must select the same number of cells"))

        for (newvar, oldvar) in zip(new_side, old_side)
            oldvar in paired || throw(ArgumentError(
                "$(JuMP.name(oldvar)) is not determined by any constraint in this block, so there " *
                "is no equation to re-point at $(JuMP.name(newvar))"))
            newvar in paired && throw(ArgumentError(
                "$(JuMP.name(newvar)) is already determined by a constraint in this block"))

            i = findfirst(c -> is_solved(c) && c.determines === oldvar, constraints)
            c = constraints[i]
            constraints[i] = Constraint(c.con, newvar, c.role, c.message, c.source)

            delete!(paired, oldvar)
            push!(paired, newvar)
            push!(news, newvar)
            push!(olds, oldvar)
        end
    end

    # A fully paired block derives its unknowns from its pairings, which the re-pointing has already
    # updated — so leaving the declaration empty keeps it derivable rather than freezing it here.
    declared = b.declared_unknowns === nothing ? nothing :
        setdiff(b.declared_unknowns, VariableGroup(b.model, olds)) ∪ VariableGroup(b.model, news)

    return validate(_rebuild(b, constraints, paired, declared, b.assert_square))
end
