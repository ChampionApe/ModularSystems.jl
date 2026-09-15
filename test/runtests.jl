using ModularSystems
using JuMP
using JuMP: MOI
using Ipopt
using Test

# One file per source file, each with a @testset named after it — a failure names its own file.
@testset "ModularSystems.jl" begin
    @testset "scaffolding" begin
        # Against `pkgversion`, not a literal: a version bump should not fail the suite, and what
        # the docstring promises is that the file and the package manager agree.
        @test ModularSystemsVersion() == pkgversion(ModularSystems)
    end

    include("layout.jl")
    include("dataset.jl")
    include("options.jl")
    include("group.jl")
    include("block.jl")
    include("solve.jl")
    include("macro.jl")
    include("optimize.jl")
    include("compose.jl")
    include("diagnose.jl")
    include("decompose.jl")
    include("tags.jl")
    include("declare.jl")
    include("indexset.jl")
    include("swap.jl")
    include("residuals.jl")
    include("problem.jl")
    include("fixedpoint.jl")
end
