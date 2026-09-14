# The @block and @group macros, and the index-spec parser they share.

_block_model(m::JuMP.AbstractModel) = m
_block_model(d::Dataset) = d.layout.model

# Stubs so a misplaced declaration fails with a sentence rather than an UndefVarError. @block matches
# on these syntactically and never expands them.
for name in (:check, :unknowns, :square)
    @eval macro $name(args...)
        return :(error($("@" * string($(QuoteNode(name)))) * " is only valid inside @block"))
    end
end

"""
    _parse_head(head) -> (name, specs, filter)

Normalise the head of a block entry into the variable it pairs with (`nothing` when unpaired), its
index specifications as `(name, set)` pairs, and an optional filter.

Julia parses these five ways depending on whether a filter is present and how many indices there are
— `ref`, `vect`, `typed_vcat`, `vcat`, and a `parameters` node for the filter — so every form is
normalised here rather than in the callers.
"""
function _parse_head(head)
    name = nothing
    parts = Any[]
    filter = nothing

    if head === nothing
        return (nothing, Tuple{Any,Any}[], nothing)   # a scalar unpaired entry, or a @check
    elseif head isa Symbol
        return (head, Tuple{Any,Any}[], nothing)
    elseif head isa Expr && head.head === :ref
        name = head.args[1]
        parts = head.args[2:end]
    elseif head isa Expr && head.head === :vect
        parts = head.args
    elseif head isa Expr && head.head === :typed_vcat
        name = head.args[1]
        parts = head.args[2:(end - 1)]
        filter = head.args[end]
    elseif head isa Expr && head.head === :vcat
        parts = head.args[1:(end - 1)]
        filter = head.args[end]
    else
        error("cannot read `$head` as a block entry head; expected a variable, `x[i in I]`, or `[i in I]`")
    end

    specs = Tuple{Any,Any}[]
    for p in parts
        if p isa Expr && p.head === :parameters
            length(p.args) == 1 || error("only one filter is allowed in `$head`")
            filter = p.args[1]
        elseif p isa Expr && (p.head === :kw || p.head === :(=))
            push!(specs, (p.args[1], p.args[2]))
        elseif p isa Expr && p.head === :call && p.args[1] in (:∈, :in)
            push!(specs, (p.args[2], p.args[3]))
        else
            error("cannot read `$p` as an index specification; expected `i in I` or `i = I`")
        end
    end
    return (name, specs, filter)
end

# Wrap `inner` in one loop per index specification, with the filter as a guard.
function _wrap_loops(inner, specs, filter)
    body = filter === nothing ? inner : Expr(:if, esc(filter), inner)
    isempty(specs) && return body
    head = Expr(:block, (Expr(:(=), esc(n), esc(s)) for (n, s) in specs)...)
    return Expr(:for, head, body)
end

# The paired variable for one iteration: `L` for a scalar entry, `L[j, t]` for an indexed one.
function _pair_expr(name, specs)
    name === nothing && return :nothing
    isempty(specs) && return esc(name)
    return Expr(:ref, esc(name), (esc(n) for (n, _) in specs)...)
end

# Build the constraint object directly rather than delegating to `JuMP.@build_constraint`. That macro
# escapes its own argument, so handing it an already-escaped body — which is unavoidable here, since
# the body must share the escaped loop variables — is a hygiene error. Moving `lhs - rhs` to one side
# needs no macro, and `-` on JuMP expressions produces the right affine, quadratic or nonlinear type.
const _COMPARISONS = Dict(
    :(==) => :(MOI.EqualTo(0.0)),
    :(<=) => :(MOI.LessThan(0.0)),
    :(>=) => :(MOI.GreaterThan(0.0)),
    :≤ => :(MOI.LessThan(0.0)),
    :≥ => :(MOI.GreaterThan(0.0)),
)

function _constraint_expr(body)
    (body isa Expr && body.head === :call && length(body.args) == 3 &&
        haskey(_COMPARISONS, body.args[1])) || error(
        "cannot read `$body` as a constraint; expected a comparison with ==, <= or >=")
    _, lhs, rhs = body.args
    set = _COMPARISONS[body.args[1]]
    return :(JuMP.ScalarConstraint($(esc(lhs)) - $(esc(rhs)), $set))
end

function _emit_constraint(blk, head, body, role, message)
    name, specs, filter = _parse_head(head)
    call = if role === :solved
        :(add_constraint!($blk, $(_constraint_expr(body)); determines = $(_pair_expr(name, specs))))
    else
        :(add_check!($blk, $(_constraint_expr(body)), $message))
    end
    return _wrap_loops(call, specs, filter)
end

# `@unknowns σ, μ[j in J]` — a plain item is passed through for VariableGroup to flatten; an indexed
# item becomes a comprehension over its cells, using the same index syntax as a constraint entry.
function _unknown_expr(item)
    if item isa Expr && item.head in (:ref, :vect, :typed_vcat, :vcat)
        name, specs, filter = _parse_head(item)
        if name !== nothing && !isempty(specs)
            iters = [Expr(:(=), esc(n), esc(s)) for (n, s) in specs]
            inner = filter === nothing ? iters : [Expr(:filter, esc(filter), iters...)]
            return Expr(:comprehension, Expr(:generator, _pair_expr(name, specs), inner...))
        end
    end
    return esc(item)
end

"""
    @block model begin ... end
    @block dataset begin ... end

Build a [`Block`](@ref). Each line is one entry:

| Form | Meaning |
|---|---|
| `x, expr` | constraint paired with `x` |
| `x[i in I], expr` | indexed, paired with `x[i]` |
| `[i in I], expr` | indexed, unpaired |
| `expr` | scalar, unpaired |
| `@check expr "msg"` | evaluated after a solve, never solved |
| `@unknowns ...` | declares the unknown set |
| `@objective Min expr` | attaches an objective |
| `@square` | asserts squareness, checked as the block is built |

A comma-separated head names the variable a constraint determines; brackets alone give index sets and
leave the constraint unpaired. `@unknowns` is required once any solved constraint is unpaired — which
is what turns a dropped variable name into a degrees-of-freedom mismatch rather than a silent change
of problem. A filter goes after `;`, as in `x[t in T; t > t0]`.

```julia
production = @block data begin
    @square
    L[j in J], L[j] == mu[j] * (w[j] / p)^-sigma * Y
    Y,        p * Y == sum(w[j] * L[j] for j in J)
    p,        p == 1
    @check C == sum(Cj[j] for j in J)  "consumption aggregation"
end
```
"""
macro block(target, body)
    (body isa Expr && body.head === :block) ||
        error("@block expects a `begin ... end` block as its second argument")

    blk = gensym("block")
    out = Any[:($blk = Block(_block_model($(esc(target)))))]

    for ex in body.args
        ex isa LineNumberNode && continue

        if ex isa Expr && ex.head === :macrocall
            mac = ex.args[1]
            args = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
            if mac === Symbol("@square")
                push!(out, :($blk.assert_square = true))
            elseif mac === Symbol("@unknowns")
                items = length(args) == 1 && args[1] isa Expr && args[1].head === :tuple ?
                    args[1].args : args
                push!(out, :(set_unknowns!($blk, VariableGroup($blk.model,
                    $((_unknown_expr(i) for i in items)...)))))
            elseif mac === Symbol("@objective")
                length(args) == 2 || error("@objective takes a sense and an expression")
                sense = args[1] === :Min ? :(MOI.MIN_SENSE) :
                        args[1] === :Max ? :(MOI.MAX_SENSE) :
                        error("objective sense must be Min or Max, got `$(args[1])`")
                push!(out, :(set_objective!($blk, $sense, $(esc(args[2])))))
            elseif mac === Symbol("@check")
                isempty(args) && error("@check needs a constraint")
                msg = length(args) >= 2 ? esc(args[2]) : ""
                push!(out, _emit_constraint(blk, nothing, args[1], :checked, msg))
            else
                error("`$mac` is not a @block declaration; expected @square, @unknowns, @objective or @check")
            end

        elseif ex isa Expr && ex.head === :tuple && length(ex.args) == 2
            push!(out, _emit_constraint(blk, ex.args[1], ex.args[2], :solved, ""))

        else
            push!(out, _emit_constraint(blk, nothing, ex, :solved, ""))
        end
    end

    push!(out, :(validate($blk)))
    return Expr(:block, out...)
end

"""
    @group items...

Build a [`VariableGroup`](@ref) using the same index syntax as [`@block`](@ref), so `mu[j in J]` and
`K[t in T; t > t0]` mean here what they mean there.

```julia
quantities   = @group L, Y, C
elasticities = @group sigma, mu[j in J]
```
"""
macro group(items...)
    isempty(items) && error("@group needs at least one item")
    return :(VariableGroup($((_unknown_expr(i) for i in items)...)))
end
