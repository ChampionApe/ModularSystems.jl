@testset "macro.jl" begin
    function testmodel()
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        return m
    end

    @testset "paired scalar entries" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        @variable(m, a)
        b = @block m begin
            @square
            x, x == 2
            y, y == a + x
        end
        @test b isa Block
        @test length(b) == 2
        @test issquare(b)
        @test collect(unknowns(b)) == [x, y]
    end

    @testset "a dataset may stand in for its model" begin
        m = testmodel()
        @variable(m, x)
        d = Dataset(m)
        b = @block d begin
            x, x == 1
        end
        @test owner_model(b) === m
    end

    @testset "indexed paired entries" begin
        m = testmodel()
        J = 1:3
        @variable(m, L[J])
        @variable(m, n[J])
        b = @block m begin
            @square
            L[j ∈ J], L[j] == 2 * n[j]
        end
        @test length(b) == 3
        @test collect(unknowns(b)) == [L[1], L[2], L[3]]
        @test issquare(b)
    end

    @testset "`i = I` and `i ∈ I` are the same" begin
        m = testmodel()
        J = 1:2
        @variable(m, L[J])
        a = @block m begin
            L[j = J], L[j] == 1
        end
        c = @block m begin
            L[j ∈ J], L[j] == 1
        end
        @test length(a) == length(c) == 2
    end

    @testset "multiple indices" begin
        m = testmodel()
        J, T = 1:2, 1:3
        @variable(m, L[J, T])
        b = @block m begin
            L[j ∈ J, t ∈ T], L[j, t] == j + t
        end
        @test length(b) == 6
        @test length(unknowns(b)) == 6
    end

    @testset "filters" begin
        m = testmodel()
        T = 1:5
        @variable(m, K[T])
        b = @block m begin
            K[t ∈ T; t > 3], K[t] == t
        end
        @test length(b) == 2                     # t = 4, 5 only
        @test collect(unknowns(b)) == [K[4], K[5]]
    end

    @testset "unpaired entries" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @unknowns x, y
            x + y == 10
            x - y == 2
        end
        @test length(b) == 2
        @test !issquare(b)
        @test degrees_of_freedom(b) == 0         # two unknowns, two equalities, but unpaired
        @test collect(unknowns(b)) == [x, y]
    end

    @testset "unpaired indexed entries" begin
        m = testmodel()
        I = 1:3
        @variable(m, x[I])
        b = @block m begin
            @unknowns x
            [i ∈ I], x[i] == i
        end
        @test length(b) == 3
        @test length(unknowns(b)) == 3
    end

    @testset "a dropped variable name shows up as a degrees-of-freedom mismatch" begin
        # The one-token cost of the grammar: `[i ∈ I], ...` instead of `x[i ∈ I], ...`. @unknowns is
        # mandatory once anything is unpaired, so the mistake surfaces rather than passing quietly.
        m = testmodel()
        I = 1:3
        @variable(m, x[I])
        b = @block m begin
            @unknowns x
            [i ∈ I], x[i] == i
        end
        @test !issquare(b)
        @test_throws ArgumentError @block m begin
            @square
            [i ∈ I], x[i] == i
        end
    end

    @testset "@square is checked as the block is built" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        err = try
            @block m begin
                @square
                x + y == 1
            end
        catch e
            e
        end
        @test err isa ArgumentError
    end

    @testset "@objective" begin
        m = testmodel()
        @variable(m, x)
        b = @block m begin
            @unknowns x
            x >= 1
            @objective Min x
        end
        @test b.objective !== nothing
        @test b.objective[1] == MOI.MIN_SENSE
        @test !issquare(b)
    end

    @testset "inequalities are ordinary unpaired constraints" begin
        m = testmodel()
        @variable(m, x)
        b = @block m begin
            @unknowns x
            x >= 1
        end
        @test length(b) == 1
        @test !ModularSystems.is_equality(only(b.constraints))
    end

    @testset "@check does not enter the solve" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @square
            x, x == 2
            y, y == 3
            @check x + y == 5  "sum"
        end
        @test length(solved_constraints(b)) == 2
        @test length(checked_constraints(b)) == 1
        @test issquare(b)                        # a check does not break squareness

        d = Dataset(m)
        out = solve(b, d; replace_nothing = 1.0)
        @test out[x] ≈ 2.0 && out[y] ≈ 3.0
    end

    @testset "a failing check raises and names itself" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @square
            x, x == 2
            y, y == 3
            @check x + y == 99  "deliberately wrong"
        end
        d = Dataset(m)
        err = try; solve(b, d; replace_nothing = 1.0); catch e; e; end
        @test err isa CheckFailure
        @test occursin("deliberately wrong", sprint(showerror, err))
    end

    @testset "checks can be inequalities, and can be skipped" begin
        m = testmodel()
        @variable(m, x)
        b = @block m begin
            @square
            x, x == 2
            @check x <= 1  "upper limit"
        end
        d = Dataset(m)
        @test_throws CheckFailure solve(b, d; replace_nothing = 1.0)
        out = solve(b, d; replace_nothing = 1.0, run_checks = false)
        @test out[x] ≈ 2.0
    end

    @testset "@group shares the index syntax" begin
        m = testmodel()
        J = 1:4
        @variable(m, x)
        @variable(m, mu[J])
        @test length(@group(x, mu)) == 5
        @test collect(@group(mu[j ∈ J; j > 2])) == [mu[3], mu[4]]
        @test length(@group(mu[j ∈ J])) == 4
    end

    @testset "@unknowns takes the same index syntax" begin
        m = testmodel()
        J = 1:4
        @variable(m, x[J])
        b = @block m begin
            @unknowns x[j ∈ J; j <= 2]
            [j ∈ J; j <= 2], x[j] == j
        end
        @test length(unknowns(b)) == 2
    end

    @testset "declarations are rejected outside @block" begin
        @test_throws Exception (@eval @square)
        @test_throws Exception (@eval @unknowns x)
    end

    @testset "end to end: a macro-built square system solves" begin
        m = testmodel()
        J = 1:2
        @variable(m, L[J])
        @variable(m, w[J])
        @variable(m, N[J])
        @variable(m, rho[J])

        b = @block m begin
            @square
            L[j ∈ J], L[j] == rho[j] * N[j]
            w[j ∈ J], w[j] == L[j] / 100
        end

        d = Dataset(m)
        d[N] = [3200.0, 500.0]
        d[rho] = [1.0, 2.0]
        out = solve(b, d; replace_nothing = 1.0)
        @test out[L] ≈ [3200.0, 1000.0]
        @test out[w] ≈ [32.0, 10.0]
    end
end
