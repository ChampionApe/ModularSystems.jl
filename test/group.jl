@testset "group.jl" begin
    function testmodel()
        m = Model()
        @variable(m, x)
        @variable(m, y[1:3])
        @variable(m, z[1:2])
        return m, x, y, z
    end

    @testset "construction flattens containers and keeps order" begin
        m, x, y, z = testmodel()
        g = VariableGroup(x, y)
        @test length(g) == 4
        @test collect(g) == [x, y[1], y[2], y[3]]
        @test x in g
        @test !(z[1] in g)
        @test owner_model(g) === m
    end

    @testset "duplicates are dropped, first occurrence wins" begin
        _, x, y, _ = testmodel()
        g = VariableGroup(y[2], x, y[2], y[1])
        @test collect(g) == [y[2], x, y[1]]
    end

    @testset "groups nest" begin
        _, x, y, z = testmodel()
        inner = VariableGroup(y)
        g = VariableGroup(x, inner, z)
        @test length(g) == 6
        @test collect(g)[1] == x
    end

    @testset "mixing models is rejected" begin
        _, x, _, _ = testmodel()
        other = Model()
        @variable(other, w)
        @test_throws ArgumentError VariableGroup(x, w)
    end

    @testset "an empty group needs its model stated" begin
        m, _, _, _ = testmodel()
        @test_throws ArgumentError VariableGroup()
        g = VariableGroup(m)
        @test isempty(g)
        @test owner_model(g) === m
    end

    @testset "set operations keep the left operand's order" begin
        _, x, y, _ = testmodel()
        a = VariableGroup(y[3], y[1], x)
        b = VariableGroup(x, y[1])

        @test collect(a ∩ b) == [y[1], x]        # a's order, not b's
        @test collect(setdiff(a, b)) == [y[3]]
        @test collect(a ∪ b) == [y[3], y[1], x]  # union de-duplicates
        @test length(VariableGroup(y) ∪ VariableGroup(x)) == 4
    end

    @testset "set operations across models are rejected" begin
        _, x, _, _ = testmodel()
        other = Model()
        @variable(other, w)
        @test_throws ArgumentError VariableGroup(x) ∩ VariableGroup(w)
    end

    @testset "a group is not an AbstractVector" begin
        _, x, _, _ = testmodel()
        @test !(VariableGroup(x) isa AbstractVector)
    end

    @testset "dataset reads and writes over a group" begin
        m, x, y, _ = testmodel()
        d = Dataset(m)
        g = VariableGroup(x, y)

        d[g] = 1.0
        @test d[g] == [1.0, 1.0, 1.0, 1.0]

        d[g] = [1.0, 2.0, 3.0, 4.0]
        @test d[g] == [1.0, 2.0, 3.0, 4.0]
        @test d[x] == 1.0
        @test d[y[3]] == 4.0

        @test_throws DimensionMismatch (d[g] = [1.0, 2.0])
    end

    @testset "bounds over a group" begin
        m, x, y, z = testmodel()
        d = Dataset(m)
        quantities = VariableGroup(y)

        set_bounds!(d, quantities; lower = 0.0)
        @test bounds(d, y[1]) == (0.0, nothing)
        @test bounds(d, y[3]) == (0.0, nothing)
        @test bounds(d, x) == (nothing, nothing)     # untouched

        clear_bounds!(d, quantities)
        @test bounds(d, y[1]) == (nothing, nothing)
    end

    @testset "show" begin
        _, x, y, _ = testmodel()
        @test occursin("4 variables", sprint(show, VariableGroup(x, y)))
        @test occursin("1 variable:", sprint(show, VariableGroup(x)))
    end
end
