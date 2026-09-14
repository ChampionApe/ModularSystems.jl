using ModularSystems
using Test

# One @testset per source file, named after it, so a failure names its own file. Checks are written
# straight into the file that will keep them -- see CLAUDE.md.
@testset "ModularSystems.jl" begin
    @testset "scaffolding" begin
        @test ModularSystemsVersion() == v"0.1.0-DEV"
    end
end
