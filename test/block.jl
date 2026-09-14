@testset "block.jl" begin
    function testmodel()
        m = Model()
        @variable(m, x)
        @variable(m, y)
        @variable(m, a)
        return m, x, y, a
    end

    @testset "a paired block derives its unknowns" begin
        m, x, y, a = testmodel()
        b = Block(m)
        add_constraint!(b, @build_constraint(x == 2), determines = x)
        add_constraint!(b, @build_constraint(y == a + x), determines = y)

        @test length(b) == 2
        @test collect(unknowns(b)) == [x, y]
        @test issquare(b)
        @test degrees_of_freedom(b) == 0
    end

    @testset "nothing reaches the model" begin
        # A block holds unregistered constraints: the point is that building one costs no MOI work.
        m, x, _, _ = testmodel()
        b = Block(m)
        add_constraint!(b, @build_constraint(x == 2), determines = x)
        @test num_constraints(m; count_variable_in_set_constraints = true) == 0
    end

    @testset "an unpaired block must declare its unknowns" begin
        m, x, y, a = testmodel()
        b = Block(m)
        add_constraint!(b, @build_constraint(x + y == a))
        @test_throws ArgumentError unknowns(b)

        set_unknowns!(b, x, y)
        @test collect(unknowns(b)) == [x, y]
        @test !issquare(b)                       # unpaired
        @test degrees_of_freedom(b) == 1         # two unknowns, one equality
    end

    @testset "a pairing may not be claimed twice" begin
        m, x, y, _ = testmodel()
        b = Block(m)
        add_constraint!(b, @build_constraint(x == 2), determines = x)
        @test_throws ArgumentError add_constraint!(b, @build_constraint(x == y), determines = x)
    end

    @testset "an inequality determines nothing" begin
        m, x, _, _ = testmodel()
        b = Block(m)
        @test_throws ArgumentError add_constraint!(b, @build_constraint(x >= 0), determines = x)
        add_constraint!(b, @build_constraint(x >= 0))     # fine unpaired
        @test length(b) == 1
    end

    @testset "variables from another model are rejected" begin
        m, x, _, _ = testmodel()
        other = Model()
        @variable(other, w)
        b = Block(m)
        @test_throws ArgumentError add_constraint!(b, @build_constraint(x == 1), determines = w)
        @test_throws ArgumentError set_unknowns!(b, VariableGroup(w))
    end

    @testset "square = true is checked by validate" begin
        m, x, y, a = testmodel()
        b = Block(m; square = true)
        add_constraint!(b, @build_constraint(x == 2), determines = x)
        @test validate(b) === b

        add_constraint!(b, @build_constraint(y >= a))     # unpaired inequality
        @test !issquare(b)
        err = try; validate(b); catch e; e; end
        @test err isa ArgumentError
        @test occursin("declared square but is not", err.msg)
        @test occursin("unpaired", err.msg)
    end

    @testset "a block without square = true is not checked" begin
        m, x, y, a = testmodel()
        b = Block(m)
        add_constraint!(b, @build_constraint(x + y == a))
        set_unknowns!(b, x, y)
        @test validate(b) === b                  # not square, but never claimed to be
    end

    @testset "an objective makes a block non-square" begin
        m, x, y, a = testmodel()
        b = Block(m)
        add_constraint!(b, @build_constraint(x == 2), determines = x)
        set_objective!(b, MOI.MIN_SENSE, y)
        set_unknowns!(b, x, y)
        @test !issquare(b)
    end

    @testset "declared unknowns that disagree with the pairings are not square" begin
        m, x, y, a = testmodel()
        b = Block(m)
        add_constraint!(b, @build_constraint(x == 2), determines = x)
        set_unknowns!(b, x, y)                   # y is not determined by anything
        @test !issquare(b)
        @test degrees_of_freedom(b) == 1
    end

    @testset "copy is independent" begin
        m, x, y, _ = testmodel()
        b = Block(m)
        add_constraint!(b, @build_constraint(x == 2), determines = x)
        c = copy(b)
        add_constraint!(c, @build_constraint(y == 3), determines = y)
        @test length(b) == 1
        @test length(c) == 2
    end

    @testset "show" begin
        m, x, _, _ = testmodel()
        b = Block(m)
        add_constraint!(b, @build_constraint(x == 2), determines = x)
        s = sprint(show, b)
        @test occursin("1 constraint", s)
        @test occursin("square", s)
    end
end
