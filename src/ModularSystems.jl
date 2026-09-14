"""
    ModularSystems

Economic models assembled from composable blocks of constraints, solved as square systems or as
optimization problems.

A [`Block`](@ref) is a collection of constraints over a JuMP model, each optionally paired with the
variable it determines, together with the variables being solved for and an optional objective.
Blocks compose with `+`; [`swap`](@ref) exchanges which variable an equation is understood to
determine, which is how calibration reuses the behavioural equations unchanged. Data lives in a
[`Dataset`](@ref), and [`solve`](@ref) applies one to the other.

Built on JuMP: a model's state is a `JuMP.Model`, and blocks are a layer over its variables and
constraints. See `docs/src/design.md` for the decisions behind this and `notes/TODO.md` for what is
still open.
"""
module ModularSystems

using JuMP
const MOI = JuMP.MOI

include("layout.jl")
include("dataset.jl")
include("options.jl")
include("group.jl")
include("block.jl")
include("decompose.jl")
include("solve.jl")
include("macro.jl")
include("diagnose.jl")
include("tags.jl")
include("indexset.jl")
include("swap.jl")
include("residuals.jl")

export ModularSystemsVersion
export Dataset, SolveMetadata, set_bounds!, bounds, clear_bounds!
export VariableGroup
export Block, Constraint, add_constraint!, set_unknowns!, set_objective!
export unknowns, pairings, issquare, degrees_of_freedom, validate, assert_square!
export solved_constraints, checked_constraints
export solve, solve!, set_optimizer_factory!, BindingBoundError, SolveOptions
export SolveStrategy, Monolithic, BlockTriangular, SubSystemFailure
export add_check!, assert_checks, CheckFailure
export @block, @group
export diagnose, Diagnosis, isclean, variables_in
export decompose, Decomposition, SubSystem, subsystems, overdetermined,
       underdetermined, iswelldetermined, largest_subsystem
export Tag, tag!, untag!, tags, has_tag, tagged, describe!, description
export IndexSet, axisnames, select_axes, group_by
export swap, endogenize, exogenize
export with_residuals, residual, residuals, has_residuals

"""
    ModularSystemsVersion() -> VersionNumber

The version recorded in `Project.toml`, read from the file rather than baked in, so it cannot drift
from what the package manager sees.

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
