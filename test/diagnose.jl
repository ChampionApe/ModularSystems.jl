@testset "diagnose.jl" begin
    function testmodel()
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        return m
    end

    @testset "shape of a square block" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        @variable(m, a)
        b = @block m begin
            @square
            x, x == 2
            y, y == a + x
            @check x + y >= 0  "nonneg"
        end
        d = Dataset(m)
        d[a] = 1.0
        r = diagnose(b, d)
        @test r.unknowns == 2
        @test r.equalities == 2
        @test r.inequalities == 0
        @test r.checks == 1
        @test r.has_objective == false
        @test r.degrees_of_freedom == 0
        @test r.square
        @test isclean(r)
    end

    @testset "shape of an optimization block" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @unknowns x, y
            x + y == 10
            x >= 0
            @objective Min (x - 3)^2
        end
        r = diagnose(b, Dataset(m))
        @test r.has_objective
        @test !r.square
        @test r.equalities == 1
        @test r.inequalities == 1
        @test r.degrees_of_freedom == 1
        @test isclean(r)
        @test occursin("optimization", sprint(show, r))
    end

    @testset "an orphan unknown is reported" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @unknowns x, y
            x == 1                       # y appears nowhere
        end
        r = diagnose(b, Dataset(m))
        @test r.orphans == [y]
        @test !isclean(r)
        @test occursin("orphan", sprint(show, r))
    end

    @testset "a variable in the objective is not an orphan" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @unknowns x, y
            x == 1
            @objective Min y^2
        end
        r = diagnose(b, Dataset(m))
        @test isempty(r.orphans)
    end

    @testset "a constraint with no unknown left is reported, with its source" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, a)
        @variable(m, c)
        b = @block m begin
            @unknowns x
            x == 1
            a == c                       # both exogenous: a constant equation after substitution
        end
        d = Dataset(m)
        d[a] = 1.0
        d[c] = 1.0
        r = diagnose(b, d)
        @test length(r.trivial) == 1
        @test r.trivial[1][1] == 2                      # second solved constraint
        @test occursin("diagnose.jl", something(r.trivial[1][2], ""))   # names where it was written
        @test !isclean(r)
    end

    @testset "missing exogenous values are reported before the solver sees them" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, a)
        b = @block m begin
            @square
            x, x == a
        end
        r = diagnose(b, Dataset(m))
        @test r.missing_values == [a]
        @test !isclean(r)
        @test occursin("no value", sprint(show, r))
    end

    @testset "variables_in" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        @variable(m, z)
        b = @block m begin
            @unknowns x
            x == y + 1
            @objective Min z^2
        end
        @test variables_in(b) == Set([x, y, z])
        @test variables_in(first(b.constraints)) == Set([x, y])
    end

    @testset "source locations are recorded by @block and not by the programmatic API" begin
        m = testmodel()
        @variable(m, x)
        macro_built = @block m begin
            x, x == 1
        end
        @test first(macro_built.constraints).source !== nothing
        @test occursin("diagnose.jl", first(macro_built.constraints).source)

        hand_built = Block(m)
        add_constraint!(hand_built, @build_constraint(x == 1), determines = x)
        @test first(hand_built.constraints).source === nothing
    end

    @testset "an unnamed failing check is identified by where it was written" begin
        m = testmodel()
        @variable(m, x)
        b = @block m begin
            @square
            x, x == 2
            @check x <= 1
        end
        err = try; solve(b, Dataset(m); replace_nothing = 1.0); catch e; e; end
        @test err isa CheckFailure
        @test occursin("check at", sprint(showerror, err))
        @test occursin("diagnose.jl", sprint(showerror, err))
    end

    # -----------------------------------------------------------------------------------------
    # What the decomposition adds
    # -----------------------------------------------------------------------------------------

    # u is determined twice over, v and r compete for one equation, q appears nowhere at all.
    # The counts cannot tell these apart; the decomposition can.
    function deficient()
        m = Model()
        @variable(m, k)
        @variable(m, u)
        @variable(m, v)
        @variable(m, w)
        @variable(m, q)
        @variable(m, r)
        b = Block(m)
        add_constraint!(b, @build_constraint(u == k))
        add_constraint!(b, @build_constraint(2 * u == 2 * k))
        add_constraint!(b, @build_constraint(w == u + 1))
        add_constraint!(b, @build_constraint(r + v == w))
        set_unknowns!(b, u, v, w, q, r)
        d = Dataset(m)
        d[k] = 1.0
        return b, d
    end

    @testset "contested equations are reported" begin
        b, d = deficient()
        x = diagnose(b, d)
        @test [i for (i, _) in x.contested] == [1, 2]
        @test !isclean(x)
    end

    @testset "undetermined unknowns are separated from orphans" begin
        b, d = deficient()
        x = diagnose(b, d)
        # q appears in nothing, which is the sharper statement, so it is an orphan and must not be
        # reported a second time under the vaguer heading.
        @test [JuMP.name(v) for v in x.orphans] == ["q"]
        @test sort([JuMP.name(v) for v in x.undetermined]) == ["r", "v"]
        @test isempty(intersect(Set(x.orphans), Set(x.undetermined)))
    end

    @testset "a balanced but structurally singular block is not clean" begin
        # Two equations determine u, and v is determined by nothing: the counts balance exactly.
        m = Model()
        @variable(m, k)
        @variable(m, u)
        @variable(m, v)
        @variable(m, w)
        b = Block(m)
        add_constraint!(b, @build_constraint(u == k))
        add_constraint!(b, @build_constraint(2 * u == 2 * k))
        add_constraint!(b, @build_constraint(w == u + 1))
        set_unknowns!(b, u, v, w)
        d = Dataset(m)
        d[k] = 1.0

        x = diagnose(b, d)
        @test x.degrees_of_freedom == 0      # the count says nothing is wrong
        @test !isclean(x)                    # the decomposition says otherwise
        @test !isempty(x.contested)
    end

    @testset "a sound block reports its largest subsystem and stays clean" begin
        m = Model()
        @variable(m, a)
        @variable(m, x)
        @variable(m, y)
        @variable(m, z)
        b = @block m begin
            @square
            x, x == a
            y, y == x + 1
            z, z == y + x
        end
        d = Dataset(m)
        d[a] = 1.0
        x = diagnose(b, d)
        @test isclean(x)
        @test x.largest == 1
        @test isempty(x.contested)
        @test isempty(x.undetermined)
        @test occursin("largest subsystem   1", sprint(show, x))
    end

    @testset "an objective block skips the decomposition" begin
        m = Model()
        @variable(m, x)
        b = @block m begin
            @unknowns x
            @objective Min (x - 2)^2
            x >= 0
        end
        d = Dataset(m)
        x = diagnose(b, d)
        @test isempty(x.contested)
        @test isempty(x.undetermined)
        @test x.largest == 0
        @test !occursin("largest subsystem", sprint(show, x))
    end
end
