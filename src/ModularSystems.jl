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

include("layout.jl")
include("dataset.jl")

export ModularSystemsVersion
export Dataset, SolveMetadata, set_bounds!, bounds, clear_bounds!

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
