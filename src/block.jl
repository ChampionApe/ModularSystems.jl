# Constraint and Block: a collection of constraints over a model, squareness optional.

"""
    ConstraintRole

Whether a constraint enters the system being solved (`SOLVED`) or is evaluated after a solve
(`CHECKED`). Independent of whether the constraint is paired with a variable.
"""
@enum ConstraintRole SOLVED CHECKED

"""
    Constraint

One constraint of a [`Block`](@ref): a JuMP function and set, the variable it is paired with if any,
and its role.

The function and set are held as an unregistered `JuMP.AbstractConstraint` — built with
`JuMP.@build_constraint`, never added to the model — so a block stays a cheap value that can be
copied and recombined, and nothing reaches MOI until a solve builds the intermediate model.

`determines` is documentation and a square-solver precondition. It names the constraint in solver
output and diagnostics and is what squareness is checked against; it does not order the system or
drive the solution write-back.
"""
struct Constraint
    con::JuMP.AbstractConstraint
    determines::Union{Nothing,VariableRef}
    role::ConstraintRole
    message::String
end

jump_func(c::Constraint) = JuMP.jump_function(c.con)
moi_set(c::Constraint) = JuMP.moi_set(c.con)

is_equality(c::Constraint) = moi_set(c) isa MOI.EqualTo
is_paired(c::Constraint) = c.determines !== nothing
is_solved(c::Constraint) = c.role == SOLVED

"""
    Block(model; square = false)

A collection of constraints over a JuMP model, with the variables being solved for and an optional
objective. Blocks are built one at a time and combined.

Squareness is a **predicate, not an invariant**: a block need not pair every constraint with a
variable, and a block carrying an objective is an optimization problem rather than a square system.
Pass `square = true` to assert that this block is square, which [`validate`](@ref) then checks — that
recovers a construction-time error for blocks that want one, without forcing it on blocks that do
not.

Unknowns are derived from the pairings when every solved constraint is paired, and must be declared
with [`set_unknowns!`](@ref) otherwise. Requiring the declaration is what turns a dropped pairing
into a degrees-of-freedom mismatch rather than a silent change of problem.
"""
mutable struct Block
    model::JuMP.AbstractModel
    constraints::Vector{Constraint}
    declared_unknowns::Union{Nothing,VariableGroup}
    objective::Union{Nothing,Tuple{MOI.OptimizationSense,Any}}
    assert_square::Bool
end

Block(model::JuMP.AbstractModel; square::Bool = false) =
    Block(model, Constraint[], nothing, nothing, square)

JuMP.owner_model(b::Block) = b.model
Base.length(b::Block) = length(b.constraints)

Base.copy(b::Block) = Block(
    b.model, copy(b.constraints), b.declared_unknowns, b.objective, b.assert_square)

"""
    solved_constraints(b::Block)
    checked_constraints(b::Block)

The constraints of a block by role.
"""
solved_constraints(b::Block) = filter(is_solved, b.constraints)
checked_constraints(b::Block) = filter(c -> !is_solved(c), b.constraints)

"""
    add_constraint!(b::Block, con; determines = nothing) -> Block

Add a solved constraint, optionally paired with the variable it determines. Build `con` with
`JuMP.@build_constraint`, which produces a function and set without touching the model.

Raises if `determines` names a variable another constraint in the block already determines, or if it
is given for an inequality — an inequality determines nothing.

```julia
b = Block(model)
add_constraint!(b, @build_constraint(x == a + b), determines = x)
```
"""
function add_constraint!(b::Block, con::JuMP.AbstractConstraint; determines = nothing)
    c = Constraint(con, determines, SOLVED, "")
    if determines !== nothing
        JuMP.owner_model(determines) === b.model || throw(ArgumentError(
            "$(JuMP.name(determines)) belongs to a different model than this block"))
        is_equality(c) || throw(ArgumentError(
            "cannot pair $(JuMP.name(determines)) with an inequality: an inequality determines nothing"))
        for other in b.constraints
            other.determines === determines && throw(ArgumentError(
                "$(JuMP.name(determines)) is already determined by another constraint in this block"))
        end
    end
    push!(b.constraints, c)
    return b
end

"""
    add_check!(b::Block, con, message = "") -> Block

Add a constraint that must hold but determines nothing. Checks never enter the system being solved;
[`solve`](@ref) evaluates them against the solution and raises [`CheckFailure`](@ref) if one fails.

A check is not a special form — it is a constraint whose role is `CHECKED` — so it may be an
equality or an inequality, and it is never paired with a variable.
"""
function add_check!(b::Block, con::JuMP.AbstractConstraint, message::AbstractString = "")
    push!(b.constraints, Constraint(con, nothing, CHECKED, String(message)))
    return b
end

"""
    set_unknowns!(b::Block, g) -> Block

Declare the variables the block solves for. Required once any solved constraint is unpaired;
otherwise the unknowns are derived from the pairings.
"""
function set_unknowns!(b::Block, g::VariableGroup)
    g.model === b.model || throw(ArgumentError("group belongs to a different model than this block"))
    b.declared_unknowns = g
    return b
end

set_unknowns!(b::Block, items...) = set_unknowns!(b, VariableGroup(b.model, items...))

"""
    set_objective!(b::Block, sense, func) -> Block

Attach an objective, making the block an optimization problem rather than a square system.
`sense` is `MOI.MIN_SENSE` or `MOI.MAX_SENSE`.
"""
function set_objective!(b::Block, sense::MOI.OptimizationSense, func)
    b.objective = (sense, func)
    return b
end

"""
    pairings(b::Block) -> VariableGroup

The variables paired with a solved constraint, in constraint order.
"""
pairings(b::Block) = VariableGroup(
    b.model, VariableRef[c.determines for c in b.constraints if is_solved(c) && is_paired(c)])

"""
    unknowns(b::Block) -> VariableGroup

The variables the block solves for: the declared set if there is one, otherwise the pairings.

Raises when some solved constraint is unpaired and no set has been declared — the block cannot then
say what it is solving for, and guessing would silently change the problem.
"""
function unknowns(b::Block)
    b.declared_unknowns === nothing || return b.declared_unknowns
    for c in b.constraints
        is_solved(c) && !is_paired(c) && throw(ArgumentError(
            "this block has unpaired constraints, so its unknowns must be declared with set_unknowns!"))
    end
    return pairings(b)
end

"""
    issquare(b::Block) -> Bool

Whether the block is a square system: no objective, and every solved constraint an equality paired
with a distinct variable, together covering the unknowns.
"""
function issquare(b::Block)
    b.objective === nothing || return false
    solved = solved_constraints(b)
    all(c -> is_paired(c) && is_equality(c), solved) || return false
    p = pairings(b)
    length(p) == length(solved) || return false
    b.declared_unknowns === nothing && return true
    return length(b.declared_unknowns) == length(p) && all(v -> v in p, b.declared_unknowns)
end

"""
    degrees_of_freedom(b::Block) -> Int

Unknowns minus solved equality constraints. Zero for a square system; the number that generalises to
a block with an objective, where squareness does not apply.
"""
degrees_of_freedom(b::Block) =
    length(unknowns(b)) - count(c -> is_solved(c) && is_equality(c), b.constraints)

"""
    validate(b::Block) -> Block

Check a block is well formed, and that it is square if it was built with `square = true`. Called by
[`solve`](@ref); call it directly when building a block programmatically and you want the error where
the block is defined rather than where it is solved.
"""
function validate(b::Block)
    if b.assert_square && !issquare(b)
        n = length(solved_constraints(b))
        unpaired = count(c -> is_solved(c) && !is_paired(c), b.constraints)
        inequalities = count(c -> is_solved(c) && !is_equality(c), b.constraints)
        msg = "block was declared square but is not: $n solved constraints"
        unpaired > 0 && (msg *= ", $unpaired unpaired")
        inequalities > 0 && (msg *= ", $inequalities not equalities")
        b.objective === nothing || (msg *= ", and it carries an objective")
        throw(ArgumentError(msg))
    end
    return b
end

function Base.show(io::IO, b::Block)
    solved = length(solved_constraints(b))
    print(io, "Block(", solved, " constraint", solved == 1 ? "" : "s")
    b.objective === nothing || print(io, ", objective")
    if b.declared_unknowns !== nothing || all(c -> !is_solved(c) || is_paired(c), b.constraints)
        print(io, ", ", length(unknowns(b)), " unknowns")
        issquare(b) && print(io, ", square")
    end
    print(io, ")")
end
