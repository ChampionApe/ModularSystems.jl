# Block-triangular decomposition: what the pairing is, structurally, once you look at it as a graph.
#
# A square block pairs each solved equality with the variable it determines, which is a perfect
# matching on the equation-variable incidence graph. Orienting the graph by that matching and taking
# strongly connected components splits the system into the smallest subsystems that must be solved
# simultaneously, in an order where each one's inputs are already known.
#
# When the pairing is absent or does not cover the unknowns, a maximum matching is computed instead,
# and the Dulmage-Mendelsohn coarse decomposition names the over- and under-determined parts. That is
# what turns "degrees of freedom: 3" into three variables and the equations they are missing from.

# `strongly_connected_components_tarjan` rather than the exported `strongly_connected_components`.
# The two are the same function today, but the exported name's docstring says in terms that the order
# of the components is *not* part of its API contract, while Tarjan's promises reverse-topological
# order — which is the whole basis of the solve order below. Depending on the promised one turns an
# accident into a contract.
using Graphs: SimpleDiGraph, strongly_connected_components_tarjan, add_edge!

"""
    SubSystem

One group of equations that must be solved together, with the variables they determine.

`constraints` indexes into the block's own `constraints` vector, so a subsystem can be read back
against the block it came from. `variables` are the cells that subsystem solves for.
"""
struct SubSystem
    constraints::Vector{Int}
    variables::Vector{VariableRef}
end

Base.length(s::SubSystem) = length(s.variables)
Base.isempty(s::SubSystem) = isempty(s.constraints) && isempty(s.variables)

function Base.show(io::IO, s::SubSystem)
    print(io, "SubSystem(", length(s.constraints), " equation",
          length(s.constraints) == 1 ? "" : "s", ", ", length(s.variables), " variable",
          length(s.variables) == 1 ? "" : "s")
    if 0 < length(s.variables) <= 4
        print(io, ": ", join((JuMP.name(v) for v in s.variables), ", "))
    end
    print(io, ")")
end

"""
    Decomposition

What [`decompose`](@ref) found: the block split into subsystems, in an order where each one's inputs
are determined by the ones before it.

- `subsystems` — the well-determined part, in **solve order**. Every entry is square.
- `overdetermined` — equations with no variable left to determine, and the variables they share.
  Non-empty means the block asks more of those variables than they can satisfy.
- `underdetermined` — variables no equation is left to determine, with the equations that could have
  determined them. Non-empty means the block does not pin them down.

A block is solvable subsystem by subsystem exactly when both deficient parts are empty, which is what
[`iswelldetermined`](@ref) asks. This is a **structural** statement: it says the incidence pattern
admits a solution order, not that the numbers do. A structurally sound system can still be
numerically singular.
"""
struct Decomposition
    block::Block
    subsystems::Vector{SubSystem}
    overdetermined::SubSystem
    underdetermined::SubSystem
end

"""
    subsystems(d::Decomposition) -> Vector{SubSystem}

The well-determined part of a decomposition, in **solve order**: each subsystem's inputs are
determined by the ones before it. Every entry is square.
"""
subsystems(d::Decomposition) = d.subsystems

"""
    overdetermined(d::Decomposition) -> SubSystem

The equations left with no variable to determine, and the variables they compete for. Non-empty means
the block asks more of those variables than they can satisfy — the usual cause is an equation written
twice, or a variable that should have been an unknown and was not.
"""
overdetermined(d::Decomposition) = d.overdetermined

"""
    underdetermined(d::Decomposition) -> SubSystem

The variables no equation is left to determine, and the equations that could have determined them.
Non-empty means the block does not pin those variables down.
"""
underdetermined(d::Decomposition) = d.underdetermined

"""
    iswelldetermined(d::Decomposition) -> Bool

Whether the decomposition found neither an over- nor an under-determined part, so the whole block can
be solved subsystem by subsystem.
"""
iswelldetermined(d::Decomposition) = isempty(d.overdetermined) && isempty(d.underdetermined)

"""
    largest_subsystem(d::Decomposition) -> Int

The size of the biggest simultaneous subsystem — the one number that says how much a block-triangular
solve can save. A chain of scalar assignments decomposes to 1; a block that is irreducibly
simultaneous decomposes to its own size and gains nothing.
"""
largest_subsystem(d::Decomposition) = isempty(d.subsystems) ? 0 : maximum(length, d.subsystems)

function Base.show(io::IO, d::Decomposition)
    n = length(d.subsystems)
    print(io, "Decomposition(", n, " subsystem", n == 1 ? "" : "s",
          ", largest ", largest_subsystem(d))
    isempty(d.overdetermined) ||
        print(io, ", ", length(d.overdetermined.constraints), " overdetermined equations")
    isempty(d.underdetermined) ||
        print(io, ", ", length(d.underdetermined.variables), " underdetermined variables")
    print(io, ")")
end

# ---------------------------------------------------------------------------------------------
# Incidence
# ---------------------------------------------------------------------------------------------

# Rows are the solved equality constraints; columns are the unknowns. `rows[i]` lists the column
# positions equation `i` touches, sorted so everything downstream is deterministic — the expression
# walkers hand back a Set, whose order is not.
function _incidence(b::Block)
    unk = collect(unknowns(b))
    pos = Dict{VariableRef,Int}(v => i for (i, v) in enumerate(unk))
    conidx = Int[]
    rows = Vector{Vector{Int}}()
    for (i, c) in enumerate(b.constraints)
        (is_solved(c) && is_equality(c)) || continue
        r = Int[]
        for v in variables_in(c)
            p = get(pos, v, 0)
            p == 0 || push!(r, p)
        end
        sort!(r)
        push!(conidx, i)
        push!(rows, r)
    end
    return unk, pos, conidx, rows
end

# ---------------------------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------------------------

# One augmenting path by breadth-first search. Deliberately iterative: the recursive form of Kuhn's
# algorithm recurses once per matched edge along the path, and the models this decomposition exists
# for are exactly the ones long enough to overflow the stack.
#
# `seen` is an epoch stamp rather than a flag vector, and that is not a micro-optimisation. Clearing
# it per call costs O(columns) whether the search touches two columns or all of them, which makes the
# whole matching pass quadratic: measured at 14.1 s for an unmatched chain of 200,000, against
# 0.033 s stamped. `came_from` needs no clearing at all, since it is only read for columns this
# call has stamped.
function _augment!(row_match, col_match, rows, start, seen, came_from, epoch)
    queue = [start]
    head = 1
    while head <= length(queue)
        i = queue[head]
        head += 1
        for j in rows[i]
            seen[j] == epoch && continue
            seen[j] = epoch
            came_from[j] = i
            if col_match[j] == 0
                # Walk the path back, re-matching each row to the column that reached it and freeing
                # the column it held for the row before.
                while j != 0
                    r = came_from[j]
                    nextj = row_match[r]
                    row_match[r] = j
                    col_match[j] = r
                    j = nextj
                end
                return true
            end
            push!(queue, col_match[j])
        end
    end
    return false
end

# The declared pairings seed the matching, so a well-formed square block costs one pass and no search
# — the answer it already carries is checked and used. A pairing naming a variable its own equation
# does not contain is not an edge of the graph, so it is skipped rather than trusted.
function _matching(b::Block, pos, conidx, rows, nvars)
    nrows = length(rows)
    row_match = zeros(Int, nrows)
    col_match = zeros(Int, nvars)
    for (i, ci) in enumerate(conidx)
        v = b.constraints[ci].determines
        v === nothing && continue
        j = get(pos, v, 0)
        j == 0 && continue                  # paired with something this block does not solve for
        col_match[j] == 0 || continue
        insorted(j, rows[i]) || continue    # pairing is not an edge: the equation lacks the variable
        row_match[i] = j
        col_match[j] = i
    end

    seen = zeros(Int, nvars)        # epoch stamps; 0 is "never seen", and no epoch is ever 0
    came_from = Vector{Int}(undef, nvars)
    epoch = 0
    for i in 1:nrows
        row_match[i] == 0 || continue
        epoch += 1
        _augment!(row_match, col_match, rows, i, seen, came_from, epoch)
    end
    return row_match, col_match
end

# ---------------------------------------------------------------------------------------------
# Dulmage-Mendelsohn coarse parts
# ---------------------------------------------------------------------------------------------

# Alternating-path reachability from the unmatched rows. From equation r, every variable it touches
# leads to that variable's own equation, so the rows reached are those competing for the same
# variables as an equation that got none: together they ask more than is available.
function _reach_rows(rows, col_match, row_match, nrows)
    hit = falses(nrows)
    queue = Int[]
    for i in 1:nrows
        if row_match[i] == 0
            hit[i] = true
            push!(queue, i)
        end
    end
    head = 1
    while head <= length(queue)
        i = queue[head]
        head += 1
        for j in rows[i]
            r = col_match[j]
            (r == 0 || hit[r]) && continue
            hit[r] = true
            push!(queue, r)
        end
    end
    return hit
end

# The mirror image, from the unmatched columns: an equation touching a free variable could have
# determined it instead of what it did determine, so its own variable is free too.
function _reach_cols(rows, col_match, row_match, nvars)
    hit = falses(nvars)
    queue = Int[]
    for j in 1:nvars
        if col_match[j] == 0
            hit[j] = true
            push!(queue, j)
        end
    end
    cols = [Int[] for _ in 1:nvars]
    for (i, r) in enumerate(rows), j in r
        push!(cols[j], i)
    end
    head = 1
    while head <= length(queue)
        j = queue[head]
        head += 1
        for i in cols[j]
            k = row_match[i]
            (k == 0 || hit[k]) && continue
            hit[k] = true
            push!(queue, k)
        end
    end
    return hit
end

# ---------------------------------------------------------------------------------------------
# decompose
# ---------------------------------------------------------------------------------------------

"""
    decompose(b::Block) -> Decomposition

Split a block into the smallest subsystems that must be solved simultaneously, ordered so each one's
inputs are determined by the ones before it, and name whatever is over- or under-determined.

Only solved **equality** constraints and the block's unknowns take part: an inequality determines
nothing, a check is evaluated after the fact, and an exogenous variable is a number by the time the
solver sees it. A block carrying an objective has no pairing to decompose and raises.

The declared pairings seed the matching, so a well-formed square block costs one pass over the
constraints and no search. Where they are missing or do not cover the unknowns a maximum matching is
computed instead, which is what lets a block that is *not* square still be reported on usefully.

# Examples
```jldoctest
julia> using JuMP

julia> model = Model();

julia> @variable(model, x); @variable(model, y); @variable(model, z);

julia> b = @block model begin
           @square
           x, x == 1
           z, z == y + x
           y, y == x + 1
       end;

julia> d = decompose(b)
Decomposition(3 subsystems, largest 1)

julia> [JuMP.name(only(s.variables)) for s in subsystems(d)]
3-element Vector{String}:
 "x"
 "y"
 "z"

julia> iswelldetermined(d)
true
```
"""
function decompose(b::Block)
    b.objective === nothing || throw(ArgumentError(
        "cannot decompose a block with an objective: there is no equation-to-variable pairing to " *
        "decompose, and an optimization problem is not solved subsystem by subsystem"))

    unk, pos, conidx, rows = _incidence(b)
    nvars = length(unk)
    nrows = length(rows)
    row_match, col_match = _matching(b, pos, conidx, rows, nvars)

    over_rows = _reach_rows(rows, col_match, row_match, nrows)
    under_cols = _reach_cols(rows, col_match, row_match, nvars)

    # An overdetermined row takes its matched column with it; a free column drags its matched row
    # along. Whatever is in neither is the well-determined core.
    over = SubSystem(
        [conidx[i] for i in 1:nrows if over_rows[i]],
        [unk[row_match[i]] for i in 1:nrows if over_rows[i] && row_match[i] != 0])
    under = SubSystem(
        [conidx[col_match[j]] for j in 1:nvars if under_cols[j] && col_match[j] != 0],
        [unk[j] for j in 1:nvars if under_cols[j]])

    core = [i for i in 1:nrows if !over_rows[i] && (row_match[i] == 0 || !under_cols[row_match[i]])]

    return Decomposition(b, _order(core, rows, col_match, row_match, unk, conidx), over, under)
end

# Tarjan over the core, on the digraph where equation i points at the equation determining each
# variable i needs. `strongly_connected_components` emits a component only once everything it can
# reach has been emitted, so its output is already in dependency order and the first subsystem is the
# one needing nothing. `test/decompose.jl` pins that, since it is a property of Graphs.jl rather than
# of this code.
function _order(core, rows, col_match, row_match, unk, conidx)
    local_of = Dict{Int,Int}(r => k for (k, r) in enumerate(core))
    g = SimpleDiGraph(length(core))
    for (k, i) in enumerate(core)
        for j in rows[i]
            r = col_match[j]
            r == 0 && continue
            k2 = get(local_of, r, 0)
            (k2 == 0 || k2 == k) && continue
            add_edge!(g, k, k2)
        end
    end
    out = SubSystem[]
    for comp in strongly_connected_components_tarjan(g)
        eqs = sort!([core[k] for k in comp])
        push!(out, SubSystem(
            [conidx[i] for i in eqs],
            [unk[row_match[i]] for i in eqs if row_match[i] != 0]))
    end
    return out
end
