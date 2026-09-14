"""
    ModularSystems

Modular square systems of equations: equation blocks paired to the endogenous variables they
determine, composed into a model, and solved.

Built on JuMP: a model's state is a `JuMP.Model`, and blocks are a layer over its variables and
constraints. See `docs/src/design.md` for the decisions behind this and `notes/TODO.md` for what is
still open.

So far this is [`Dataset`](@ref) and the model layout it sits on; blocks and solving are not written
yet.
"""
module ModularSystems

using JuMP
const MOI = JuMP.MOI

include("layout.jl")
include("dataset.jl")
include("group.jl")
include("block.jl")
include("solve.jl")
include("macro.jl")

export ModularSystemsVersion
export Dataset, SolveMetadata, set_bounds!, bounds, clear_bounds!
export VariableGroup
export Block, Constraint, add_constraint!, set_unknowns!, set_objective!
export unknowns, pairings, issquare, degrees_of_freedom, validate
export solved_constraints, checked_constraints
export solve, solve!, set_optimizer_factory!, BindingBoundError
export add_check!, assert_checks, CheckFailure
export @block, @group

"""
    ModularSystemsVersion() -> VersionNumber

The version recorded in `Project.toml`. Exists so the package has one callable symbol before the
real API lands; delete it once `Block` and friends exist.

# Examples
```jldoctest
julia> ModularSystemsVersion()
v"0.1.0-DEV"
```
"""
function ModularSystemsVersion()
    project = joinpath(dirname(@__DIR__), "Project.toml")
    for line in eachline(project)
        m = match(r"^version\s*=\s*\"(.*)\"", line)
        m === nothing || return VersionNumber(m.captures[1])
    end
    error("no version field in $project")
end

end # module
