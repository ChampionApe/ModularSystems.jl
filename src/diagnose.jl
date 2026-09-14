# Structural diagnosis of a block against a dataset, before any solver runs.

_variables_in!(s::Set{VariableRef}, ::Number) = s
_variables_in!(s::Set{VariableRef}, v::VariableRef) = (push!(s, v); s)

function _variables_in!(s::Set{VariableRef}, e::JuMP.GenericAffExpr)
    for (v, _) in e.terms
        push!(s, v)
    end
    return s
end

function _variables_in!(s::Set{VariableRef}, e::JuMP.GenericQuadExpr)
    _variables_in!(s, e.aff)
    for (pair, _) in e.terms
        push!(s, pair.a)
        push!(s, pair.b)
    end
    return s
end

function _variables_in!(s::Set{VariableRef}, e::JuMP.GenericNonlinearExpr)
    for arg in e.args
        _variables_in!(s, arg)
    end
    return s
end

"""
    variables_in(x) -> Set{VariableRef}

Every variable appearing in a JuMP expression, a [`Constraint`](@ref) or a [`Block`](@ref). For a
block this includes checks and the objective, not only the solved constraints.
"""
variables_in(x) = _variables_in!(Set{VariableRef}(), x)
variables_in(c::Constraint) = _variables_in!(Set{VariableRef}(), jump_func(c))

function variables_in(b::Block)
    s = Set{VariableRef}()
    for c in b.constraints
        _variables_in!(s, jump_func(c))
    end
    b.objective === nothing || _variables_in!(s, b.objective[2])
    return s
end

"""
    Diagnosis

What [`diagnose`](@ref) found: the shape of the system, and the structural problems that would
otherwise surface as an unexplained solver failure.

`trivial` lists solved constraints containing no unknown — after exogenous values are substituted
they become a constant equation, which is either always true or always false. `orphans` lists
unknowns appearing in no solved constraint and in no objective, so nothing determines them.
`missing_values` lists exogenous variables with no value in the dataset, which is what the solve
would raise on first.

The remaining three come from [`decompose`](@ref) and are what counting cannot see. `contested`
lists equations left with no variable to determine, because the variables they could have determined
are spoken for; `undetermined` lists unknowns that *do* appear in equations but that nothing is left
to determine. A block can have zero degrees of freedom and still have both, which is the case a
count of unknowns against equations cannot distinguish from a sound system. `largest` is the size of
the biggest simultaneous subsystem, and says how much [`BlockTriangular`](@ref) would save.

All three are empty for a block carrying an objective, where there is no pairing to decompose.
"""
struct Diagnosis
    unknowns::Int
    equalities::Int
    inequalities::Int
    checks::Int
    has_objective::Bool
    degrees_of_freedom::Int
    square::Bool
    trivial::Vector{Tuple{Int,Union{Nothing,String}}}
    orphans::Vector{VariableRef}
    missing_values::Vector{VariableRef}
    contested::Vector{Tuple{Int,Union{Nothing,String}}}
    undetermined::Vector{VariableRef}
    largest::Int
end

"""
    diagnose(b::Block, d::Dataset) -> Diagnosis
    diagnose(b::Block) -> Diagnosis

Report the shape of a block and the structural problems in it, without running a solver.

Without a dataset, everything is reported except `missing_values`, which is the one check that needs
data. That form is what [`assert_solvable`](@ref) uses, since a block's structure is a property of
the block alone and cannot go stale the way a dataset can.

Reports rather than raises: a diagnosis is something to read while building a model. The shape —
unknowns, equalities, inequalities, objective, degrees of freedom — is defined whether or not the
system is square, which is why it is the useful summary for both kinds of block.

An orphan means something different on each path. In a square system an unknown in no constraint is
a bug. With an objective it may be legitimate, so a variable appearing in the objective is not
reported.
"""
function diagnose(b::Block, d::Union{Nothing,Dataset} = nothing)
    unk = unknowns(b)
    unkset = unk.set

    equalities = inequalities = checks = 0
    trivial = Tuple{Int,Union{Nothing,String}}[]
    used = Set{VariableRef}()
    missing_values = VariableRef[]
    seen_exogenous = Set{VariableRef}()

    n = 0
    solved_position = Dict{Int,Int}()   # constraint index -> position among solved constraints
    for (idx, c) in enumerate(b.constraints)
        if !is_solved(c)
            checks += 1
            continue
        end
        n += 1
        solved_position[idx] = n
        is_equality(c) ? (equalities += 1) : (inequalities += 1)

        vars = variables_in(c)
        touched = intersect(vars, unkset)
        isempty(touched) && push!(trivial, (n, c.source))
        union!(used, touched)

        for v in vars
            v in unkset && continue
            v in seen_exogenous && continue
            push!(seen_exogenous, v)
            d === nothing && continue
            d[v] === nothing && push!(missing_values, v)
        end
    end

    objective_vars = b.objective === nothing ? Set{VariableRef}() : variables_in(b.objective[2])
    orphans = VariableRef[v for v in unk if !(v in used) && !(v in objective_vars)]

    # An orphan is already the sharper statement — nothing mentions the variable at all — so it is
    # subtracted out here rather than reported twice under a vaguer heading. What is left is the
    # case that only the decomposition can see: a variable every one of its equations has had to
    # give up in favour of something else.
    contested = Tuple{Int,Union{Nothing,String}}[]
    undetermined = VariableRef[]
    largest = 0
    if b.objective === nothing
        dec = decompose(b)
        largest = largest_subsystem(dec)
        orphanset = Set(orphans)
        # Numbered by position among the solved constraints, the same way `trivial` is and the same
        # way the solver names an unpaired constraint, so one number means one thing throughout.
        for i in overdetermined(dec).constraints
            push!(contested, (solved_position[i], b.constraints[i].source))
        end
        for v in underdetermined(dec).variables
            v in orphanset || push!(undetermined, v)
        end
    end

    return Diagnosis(
        length(unk), equalities, inequalities, checks, b.objective !== nothing,
        length(unk) - equalities, issquare(b), trivial, orphans, missing_values,
        contested, undetermined, largest,
    )
end

"""
    isclean(x::Diagnosis) -> Bool

Whether a diagnosis found no structural problem. A non-zero degrees of freedom is not a problem —
that is the shape of an optimization block — but a contested equation or an undetermined unknown is,
whatever the counts say.
"""
isclean(x::Diagnosis) =
    isempty(x.trivial) && isempty(x.orphans) && isempty(x.missing_values) &&
    isempty(x.contested) && isempty(x.undetermined)

function Base.show(io::IO, x::Diagnosis)
    println(io, "Diagnosis")
    println(io, "  unknowns            ", x.unknowns)
    println(io, "  equalities          ", x.equalities)
    println(io, "  inequalities        ", x.inequalities)
    println(io, "  checks              ", x.checks)
    println(io, "  objective           ", x.has_objective ? "yes" : "none")
    println(io, "  degrees of freedom  ", x.degrees_of_freedom)
    println(io, "  square              ", x.square ? "yes" : "no")
    x.has_objective || println(io, "  largest subsystem   ", x.largest)
    print(io, "  solve path          ", x.has_objective ? "optimization" :
                                        x.square ? "square" : "neither — see below")
    if !isempty(x.trivial)
        print(io, "\n  trivial constraints (no unknown left after substitution):")
        for (i, src) in x.trivial
            print(io, "\n    constraint[", i, "]", src === nothing ? "" : " at " * src)
        end
    end
    if !isempty(x.orphans)
        print(io, "\n  orphan unknowns (in no constraint and no objective):")
        for v in x.orphans
            print(io, "\n    ", JuMP.name(v))
        end
    end
    if !isempty(x.contested)
        print(io, "\n  contested equations (nothing left for them to determine):")
        for (i, src) in x.contested
            print(io, "\n    constraint[", i, "]", src === nothing ? "" : " at " * src)
        end
    end
    if !isempty(x.undetermined)
        print(io, "\n  undetermined unknowns (they appear in constraints, but every constraint ",
                  "that could determine them is determining something else):")
        for v in x.undetermined
            print(io, "\n    ", JuMP.name(v))
        end
    end
    if !isempty(x.missing_values)
        print(io, "\n  exogenous variables with no value:")
        for v in x.missing_values
            print(io, "\n    ", JuMP.name(v))
        end
    end
    return nothing
end
