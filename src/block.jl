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

`source` records where a `@block` entry was written. It is what makes an unpaired constraint
identifiable in a diagnosis or a failed check, since there is no variable name to call it by.

`determines` is documentation and a square-solver precondition. It names the constraint in solver
output and diagnostics and is what squareness is checked against; it does not order the system or
drive the solution write-back.
"""
struct Constraint
    con::JuMP.AbstractConstraint
    determines::Union{Nothing,VariableRef}
    role::ConstraintRole
    message::String
    source::Union{Nothing,String}    # "file:line" when built by @block, nothing when programmatic
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
    paired::Set{VariableRef}     # claimed pairings, for O(1) duplicate detection
    declared_unknowns::Union{Nothing,VariableGroup}
    objective::Union{Nothing,Tuple{MOI.OptimizationSense,Any}}
    assert_square::Bool
end

Block(model::JuMP.AbstractModel; square::Bool = false) =
    Block(model, Constraint[], Set{VariableRef}(), nothing, nothing, square)

JuMP.owner_model(b::Block) = b.model
Base.length(b::Block) = length(b.constraints)

Base.copy(b::Block) = Block(
    b.model, copy(b.constraints), copy(b.paired), b.declared_unknowns, b.objective, b.assert_square)

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
function add_constraint!(b::Block, con::JuMP.AbstractConstraint; determines = nothing, source = nothing)
    c = Constraint(con, determines, SOLVED, "", source)
    if determines !== nothing
        JuMP.owner_model(determines) === b.model || throw(ArgumentError(
            "$(JuMP.name(determines)) belongs to a different model than this block"))
        is_equality(c) || throw(ArgumentError(
            "cannot pair $(JuMP.name(determines)) with an inequality: an inequality determines nothing"))
        # Set membership rather than a scan of every existing constraint: the scan made building a
        # block quadratic in its size, which matters once blocks are composed from modules.
        determines in b.paired && throw(ArgumentError(
            "$(JuMP.name(determines)) is already determined by another constraint in this block"))
        push!(b.paired, determines)
    end
    push!(b.constraints, c)
    return b
end

"""
    a::Block + b::Block -> Block

Compose two blocks over the same model. Constraints concatenate and pairings must stay distinct, so a
variable determined in both blocks is an error rather than a silently dropped equation.

For **many** blocks use [`compose`](@ref), which does it in one pass. `+` is non-mutating, so folding
it over `n` blocks is quadratic in the number of blocks.

- **Objectives.** At most one across a sum. Two objectives raise rather than being added together:
  summing objectives contributed by different modules is a wrong answer with no symptom.
- **Unknowns.** Unioned. If neither block declares a set, the result declares none either and keeps
  deriving its unknowns from its pairings.
- **Squareness.** The result is **never** marked square, whatever its parts claimed. Two square blocks
  can each be square alone and not compose to a square system, so inheriting the claim would skip the
  check exactly where it is most likely to catch something. Re-assert with [`assert_square!`](@ref).
"""
function Base.:+(a::Block, b::Block)
    a.model === b.model || throw(ArgumentError("blocks belong to different models"))
    a.objective === nothing || b.objective === nothing || throw(ArgumentError(
        "both blocks carry an objective; a composed block may have at most one"))

    clash = intersect(a.paired, b.paired)
    isempty(clash) || throw(ArgumentError(
        "both blocks determine " * join((JuMP.name(v) for v in clash), ", ") *
        "; a variable may be determined only once in a composed block"))

    unk = (a.declared_unknowns === nothing && b.declared_unknowns === nothing) ?
        nothing : unknowns(a) ∪ unknowns(b)

    return Block(
        a.model,
        vcat(a.constraints, b.constraints),
        union(a.paired, b.paired),
        unk,
        a.objective === nothing ? b.objective : a.objective,
        false,
    )
end

"""
    compose(blocks) -> Block

Combine many blocks in one pass, with the same rules as `+`.

Use this rather than `sum` or a fold over `+` when there are many. `+` is non-mutating, so it copies
both constraint vectors every time, and folding it over `n` blocks copies `O(n²)` constraints —
measured at 0.32 s for 2,000 two-equation blocks, against 1.25 ms here. That matters because building a
model out of many small blocks, one per period or per sector, is the idiom this package is for.

`sum` over a `Vector` or `Tuple` of blocks calls this. `sum` over a *generator* cannot, and falls back
to the quadratic fold, so `collect` it first or call `compose` directly.
"""
function compose(blocks)
    isempty(blocks) && throw(ArgumentError(
        "cannot compose an empty collection of blocks: there is no model to attach the result to"))

    model = first(blocks).model
    constraints = sizehint!(Constraint[], sum(length(b.constraints) for b in blocks))
    paired = Set{VariableRef}()
    objective = nothing
    declared = false

    for b in blocks
        b.model === model || throw(ArgumentError("blocks belong to different models"))
        if b.objective !== nothing
            objective === nothing || throw(ArgumentError(
                "more than one block carries an objective; a composed block may have at most one"))
            objective = b.objective
        end
        for v in b.paired
            v in paired && throw(ArgumentError(
                "$(JuMP.name(v)) is determined in more than one of these blocks; a variable may be " *
                "determined only once in a composed block"))
            push!(paired, v)
        end
        append!(constraints, b.constraints)
        b.declared_unknowns === nothing || (declared = true)
    end

    # Same rule as `+`: if no part declared a set, the result declares none either and keeps deriving
    # its unknowns from its pairings. Built from one flat vector rather than by folding `∪`, which
    # would reintroduce the quadratic copying this function exists to avoid.
    unk = nothing
    if declared
        raw = VariableRef[]
        for b in blocks
            append!(raw, unknowns(b).vars)
        end
        unk = VariableGroup(model, raw)
    end

    return Block(model, constraints, paired, unk, objective, false)
end

# `sum` on a vector or tuple folds `+` pairwise, which is quadratic. These are the two cases that can
# be intercepted; a generator cannot, and `compose`'s docstring says so.
Base.sum(blocks::AbstractVector{Block}) = compose(blocks)
Base.sum(blocks::Tuple{Block,Vararg{Block}}) = compose(blocks)

"""
    assert_square!(b::Block) -> Block

Mark a block square and check it immediately. This is how a composed block re-asserts squareness,
which `+` deliberately does not carry over.
"""
function assert_square!(b::Block)
    b.assert_square = true
    return validate(b)
end

"""
    add_check!(b::Block, con, message = "") -> Block

Add a constraint that must hold but determines nothing. Checks never enter the system being solved;
[`solve`](@ref) evaluates them against the solution and raises [`CheckFailure`](@ref) if one fails.

A check is not a special form — it is a constraint whose role is `CHECKED` — so it may be an
equality or an inequality, and it is never paired with a variable.
"""
function add_check!(b::Block, con::JuMP.AbstractConstraint, message::AbstractString = "";
                    source = nothing)
    push!(b.constraints, Constraint(con, nothing, CHECKED, String(message), source))
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
