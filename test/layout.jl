@testset "layout.jl" begin
    @testset "slots come from JuMP's variable index" begin
        m = Model()
        @variable(m, x)
        @variable(m, y[1:3])
        @test ModularSystems.slot(x) == JuMP.index(x).value
        @test [ModularSystems.slot(v) for v in y] == [2, 3, 4]
        @test ModularSystems.highest_slot(m) == 4
    end

    @testset "one layout per model, cached in model.ext" begin
        m = Model()
        @variable(m, x)
        @test ModularSystems.layout(m) === ModularSystems.layout(m)
        @test ModularSystems.layout(m).model === m
    end

    @testset "deletion leaves a gap, so slots outrun num_variables" begin
        m = Model()
        @variable(m, y[1:3])
        delete(m, y[2])
        @variable(m, w)
        @test num_variables(m) == 3
        @test ModularSystems.highest_slot(m) == 4      # not 3 — the deleted slot is never reused
        @test ModularSystems.slot(w) == 4
    end

    @testset "note_slot! is a high-water mark" begin
        m = Model()
        @variable(m, x)
        l = ModularSystems.layout(m)
        @test ModularSystems.note_slot!(l, 10) == 10
        @test ModularSystems.note_slot!(l, 4) == 10    # only ever grows
    end

    @testset "empty model" begin
        @test ModularSystems.highest_slot(Model()) == 0
    end
end
