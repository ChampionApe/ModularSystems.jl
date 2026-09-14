"""
    ModularSystems

Modular square systems of equations: equation blocks paired to the endogenous variables they
determine, composed into a model, and solved.

Built on JuMP: a model's state is a `JuMP.Model`, and blocks are a layer over its variables and
constraints. See `docs/src/design.md` for why, and `notes/TODO.md` (C2, C3) for what is still open.
Nothing here is load-bearing yet.
"""
module ModularSystems

using JuMP

export ModularSystemsVersion

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
