# @declare: JuMP's block declaration form, plus a description column and block-level tags.

# A description is a string literal or an interpolated string. Both are unambiguous: JuMP rejects a
# bare positional string in a declaration ("Unrecognized positional arguments"), so claiming that
# slot cannot collide with anything JuMP does with it.
_isdescription(x) = x isa AbstractString || (x isa Expr && x.head === :string)

# Split `L[j in J], "Labour demand"` into the JuMP declaration and its description. A row is a tuple
# only because of that comma, so the declaration is everything before a trailing string — which is
# what keeps `w[j in J] >= 0, (start = 1.0), "Wage"` intact.
function _split_description(row)
    if row isa Expr && row.head === :tuple && !isempty(row.args) && _isdescription(last(row.args))
        parts = row.args[1:(end - 1)]
        isempty(parts) && error("`$row` is a description with no variable in front of it")
        return (length(parts) == 1 ? parts[1] : Expr(:tuple, parts...), last(row.args))
    end
    return (row, nothing)
end

# `model`, or `model::Tag`, or `model::(Tag1, Tag2)`.
function _declare_target(target)
    if target isa Expr && target.head === :(::)
        tags = target.args[2]
        return (target.args[1], tags isa Expr && tags.head === :tuple ? tags.args : Any[tags])
    end
    return (target, Any[])
end

"""
    @declare model begin ... end
    @declare model::tag begin ... end
    @declare dataset::(tag1, tag2) begin ... end

Declare many variables at once, each with an optional description, and tag every variable the block
declares.

Each row is a `JuMP.@variable` declaration — bounds, `start`, containers and all — optionally
followed by a description:

```julia
@declare model begin
    L[j in J],          "Labour demand"
    w[j in J] >= 0,     "Wage"
    Y,                  "Output"

    N[j in J],          "Labour force (exogenous)"
    sigma,              "Substitution elasticity"
end
```

The rows are handed to `JuMP.@variables` unchanged, so every JuMP declaration form keeps working and
each named row binds its name in the enclosing scope, exactly as `@variable` does — there is nothing
to destructure. The block also evaluates to JuMP's tuple of the declared containers, in row order,
which is what reaches anonymous rows. A description is attached with [`describe!`](@ref) and a tag
with [`tag!`](@ref), which is also how either is added to a variable declared some other way — this
macro is a shorthand, never a second mechanism.

Tags after `::` apply to **every** variable the block declares, including anonymous ones:

```julia
@declare model::Quantity begin
    L[j in J], "Labour demand"
    Y,         "Output"
end
```

Nothing here shadows `JuMP.@variables`, which remains available and unmodified.

# Examples
```jldoctest
julia> using JuMP

julia> model = Model();

julia> const Quantity = Tag(:quantity);

julia> J = 1:2;

julia> @declare model::Quantity begin
           L[j in J],      "Labour demand"
           w[j in J] >= 0, "Wage"
           Y,              "Output"
       end;

julia> description(L[1])
"Labour demand"

julia> has_tag(w[2], Quantity)
true

julia> lower_bound(w[1])
0.0
```
"""
macro declare(target, body)
    (body isa Expr && body.head === :block) ||
        error("@declare expects a `begin ... end` block as its last argument")

    model_expr, tag_exprs = _declare_target(target)

    # Two hygiene traps, both load-bearing. The gensyms are escaped so they live in the caller's
    # scope, because `JuMP.@variables` escapes its own arguments and so must be handed a name that
    # scope can see. And the whole `JuMP.@variables` call is escaped, because hygiene descends into a
    # nested macrocall's arguments and would resolve the user's index sets in this module instead —
    # `J` became `ModularSystems.J`, and the model became invalid `let` syntax.
    model_sym, vars_sym = gensym("model"), gensym("declared")
    m, v = esc(model_sym), esc(vars_sym)

    rows = Any[]
    descriptions = Tuple{Int,Any}[]
    position = 0
    for ex in body.args
        if ex isa LineNumberNode
            push!(rows, ex)                  # kept, so a JuMP error names the user's line
            continue
        end
        declaration, text = _split_description(ex)
        push!(rows, declaration)
        position += 1
        text === nothing || push!(descriptions, (position, text))
    end

    out = Any[
        :($m = _block_model($(esc(model_expr)))),
        :($v = $(esc(Expr(:macrocall, GlobalRef(JuMP, Symbol("@variables")), __source__,
                          model_sym, Expr(:block, rows...))))),
    ]
    for (k, text) in descriptions
        push!(out, :(describe!($m, $v[$k], $(esc(text)))))
    end
    # Tagging the returned tuple rather than the declared names reaches anonymous rows too, and needs
    # no guess about which side of `0 <= x <= 1` is the variable.
    for t in tag_exprs
        push!(out, :(tag!($m, $(esc(t)), $v)))
    end
    push!(out, v)
    return Expr(:block, out...)
end
