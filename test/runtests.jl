using ModularSystems
using JuMP
using JuMP: MOI
using Ipopt
using Test

# One file per source file, each with a @testset named after it — a failure names its own file.
@testset "ModularSystems.jl" begin
    @testset "scaffolding" begin
        @test ModularSystemsVersion() == v"0.1.0-DEV"
    end

    include("layout.jl")
    include("dataset.jl")
    include("group.jl")
    include("block.jl")
    include("solve.jl")
    include("macro.jl")
    include("optimize.jl")
    include("compose.jl")
end
