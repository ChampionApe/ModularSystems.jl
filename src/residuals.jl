# Residual variables: an opt-in slack on each paired equation, for locating inconsistent data.

const _RESIDUAL_KEY = :ModularSystems_residuals

_residual_map(model::JuMP.AbstractModel) =
    get!(model.ext, _RESIDUAL_KEY) do
        Dict{VariableRef,VariableRef}()
    end::Dict{VariableRef,VariableRef}

"""
    residual(v::VariableRef) -> Union{VariableRef,Nothing}

The residual belonging to a variable, or `nothing` if it has none. Created by
[`with_residuals`](@ref).
"""
residual(v::VariableRef) = get(_residual_map(JuMP.owner_model(v)), v, nothing)

"""
    with_residuals(b::Block, datasets...; suffix = "_J") -> Block

A copy of the block with a **residual** variable added to every paired solved constraint. The
residual is added to the constraint function, so an equation written `x == rhs` becomes
`x + residual(x) == rhs`: the residual is the amount by which the left side falls short.

Residuals are exogenous and normally zero, so they change nothing until you ask them to. Any datasets
passed are given zeros for the new residuals; without that, the first solve raises on an exogenous
variable with no value.

**Opt-in, and paired-only.** A residual doubles the variable count and is meaningless for a constraint
that determines nothing, so it is never created automatically.

What they are for is locating inconsistent data. Exogenise a variable at its observed value, make its
residual the unknown instead, and solve: the residual reads off how far the data misses the equation.
That is a [`swap`](@ref):

```julia
b = with_residuals(behavioural, observed)
check = swap(b, residual(L[1]) => L[1])
solve!(check, observed)      # observed[residual(L[1])] is now the inconsistency
```

Calling it twice is harmless: a constraint that already carries its residual is left alone.
"""
function with_residuals(b::Block, datasets::Dataset...; suffix::AbstractString = "_J")
    map = _residual_map(b.model)
    constraints = copy(b.constraints)
    created = VariableRef[]

    for (i, c) in enumerate(constraints)
        (is_solved(c) && is_paired(c)) || continue
        v = c.determines

        r = get(map, v, nothing)
        if r === nothing
            r = JuMP.@variable(b.model, base_name = JuMP.name(v) * suffix)
            map[v] = r
        end
        # Already carried by this constraint — adding it again would double the slack.
        r in variables_in(c) && continue

        constraints[i] = Constraint(
            JuMP.ScalarConstraint(jump_func(c) + r, moi_set(c)), v, c.role, c.message, c.source)
        push!(created, r)
    end

    for d in datasets
        for r in created
            d[r] === nothing && (d[r] = 0.0)
        end
    end

    return Block(b.model, constraints, copy(b.paired), b.declared_unknowns, b.objective,
                 b.assert_square)
end

"""
    residuals(b::Block) -> VariableGroup

The residuals carried by this block's constraints, in constraint order. Empty for a block that
[`with_residuals`](@ref) has not been applied to.
"""
function residuals(b::Block)
    map = _residual_map(b.model)
    out = VariableRef[]
    for c in b.constraints
        (is_solved(c) && is_paired(c)) || continue
        r = get(map, c.determines, nothing)
        r === nothing && continue
        r in variables_in(c) && push!(out, r)
    end
    return VariableGroup(b.model, out)
end

"""
    has_residuals(b::Block) -> Bool
"""
has_residuals(b::Block) = !isempty(residuals(b))
