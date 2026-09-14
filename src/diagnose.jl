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
end

"""
    diagnose(b::Block, d::Dataset) -> Diagnosis

Report the shape of a block and the structural problems in it, without running a solver.

Reports rather than raises: a diagnosis is something to read while building a model. The shape —
unknowns, equalities, inequalities, objective, degrees of freedom — is defined whether or not the
system is square, which is why it is the useful summary for both kinds of block.

An orphan means something different on each path. In a square system an unknown in no constraint is
a bug. With an objective it may be legitimate, so a variable appearing in the objective is not
reported.
"""
function diagnose(b::Block, d::Dataset)
    unk = unknowns(b)
    unkset = unk.set

    equalities = inequalities = checks = 0
    trivial = Tuple{Int,Union{Nothing,String}}[]
    used = Set{VariableRef}()
    missing_values = VariableRef[]
    seen_exogenous = Set{VariableRef}()

    n = 0
    for c in b.constraints
        if !is_solved(c)
            checks += 1
            continue
        end
        n += 1
        is_equality(c) ? (equalities += 1) : (inequalities += 1)

        vars = variables_in(c)
        touched = intersect(vars, unkset)
        isempty(touched) && push!(trivial, (n, c.source))
        union!(used, touched)

        for v in vars
            v in unkset && continue
            v in seen_exogenous && continue
            push!(seen_exogenous, v)
            d[v] === nothing && push!(missing_values, v)
        end
    end

    objective_vars = b.objective === nothing ? Set{VariableRef}() : variables_in(b.objective[2])
    orphans = VariableRef[v for v in unk if !(v in used) && !(v in objective_vars)]

    return Diagnosis(
        length(unk), equalities, inequalities, checks, b.objective !== nothing,
        length(unk) - equalities, issquare(b), trivial, orphans, missing_values,
    )
end

"""
    isclean(x::Diagnosis) -> Bool

Whether a diagnosis found no structural problem. A non-zero degrees of freedom is not a problem —
that is the shape of an optimization block.
"""
isclean(x::Diagnosis) = isempty(x.trivial) && isempty(x.orphans) && isempty(x.missing_values)

function Base.show(io::IO, x::Diagnosis)
    println(io, "Diagnosis")
    println(io, "  unknowns            ", x.unknowns)
    println(io, "  equalities          ", x.equalities)
    println(io, "  inequalities        ", x.inequalities)
    println(io, "  checks              ", x.checks)
    println(io, "  objective           ", x.has_objective ? "yes" : "none")
    println(io, "  degrees of freedom  ", x.degrees_of_freedom)
    println(io, "  square              ", x.square ? "yes" : "no")
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
    if !isempty(x.missing_values)
        print(io, "\n  exogenous variables with no value:")
        for v in x.missing_values
            print(io, "\n    ", JuMP.name(v))
        end
    end
    return nothing
end
