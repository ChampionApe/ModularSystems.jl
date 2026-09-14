@testset "swap.jl" begin
    # A behavioural block: L determined by productivity, w by L.
    function setup()
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
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
        return m, b, L, w, N, rho, J
    end

    @testset "swap re-points a pairing and exchanges the unknowns" begin
        m, b, L, w, N, rho, J = setup()
        cal = swap(b, rho => L)
        @test collect(unknowns(cal)) == [rho[1], rho[2], w[1], w[2]]
        @test !(L[1] in unknowns(cal))
        @test issquare(cal)
        @test length(cal) == length(b)            # same equations
    end

    @testset "the original block is untouched" begin
        m, b, L, w, N, rho, J = setup()
        cal = swap(b, rho => L)
        @test collect(unknowns(b)) == [L[1], L[2], w[1], w[2]]
        @test rho[1] in unknowns(cal)
        @test !(rho[1] in unknowns(b))
    end

    @testset "a declared-square block stays declared square through a swap" begin
        m, b, L, w, N, rho, J = setup()
        @test b.assert_square
        cal = swap(b, rho => L)
        @test cal.assert_square                   # a swap preserves the shape
    end

    @testset "calibrate then simulate" begin
        m, b, L, w, N, rho, J = setup()
        cal = swap(b, rho => L)

        observed = Dataset(m)
        observed[N] = [3200.0, 500.0]
        observed[L] = [3200.0, 1000.0]
        calibrated = solve(cal, observed; replace_nothing = 1.0)
        @test calibrated[rho] ≈ [1.0, 2.0]

        # The behavioural block, unchanged, reproduces the observation from those parameters.
        baseline = solve(b, calibrated; replace_nothing = 1.0)
        @test baseline[L] ≈ [3200.0, 1000.0]

        scenario = copy(baseline)
        scenario[N] = [2700.0, 1000.0]
        scenario = solve(b, scenario; replace_nothing = 1.0)
        @test scenario[L] ≈ [2700.0, 2000.0]
    end

    @testset "swapping a single cell" begin
        m, b, L, w, N, rho, J = setup()
        cal = swap(b, rho[1] => L[1])
        @test rho[1] in unknowns(cal)
        @test !(rho[2] in unknowns(cal))
        @test L[2] in unknowns(cal)
        @test issquare(cal)
    end

    @testset "several pairs at once" begin
        m, b, L, w, N, rho, J = setup()
        cal = swap(b, rho => L, N => w)
        @test all(v in unknowns(cal) for v in rho)
        @test all(v in unknowns(cal) for v in N)
        @test issquare(cal)
    end

    @testset "@group selects cells on each side" begin
        m, b, L, w, N, rho, J = setup()
        cal = swap(b, @group(rho[j ∈ J; j == 1]) => @group(L[j ∈ J; j == 1]))
        @test rho[1] in unknowns(cal)
        @test L[2] in unknowns(cal)
    end

    @testset "the two sides must select the same number of cells" begin
        m, b, L, w, N, rho, J = setup()
        @test_throws DimensionMismatch swap(b, rho => L[1])
    end

    @testset "swapping something no equation determines is an error" begin
        m, b, L, w, N, rho, J = setup()
        err = try; swap(b, rho => N); catch e; e; end
        @test err isa ArgumentError
        @test occursin("not determined by any constraint", err.msg)
    end

    @testset "swapping onto an already-determined variable is an error" begin
        m, b, L, w, N, rho, J = setup()
        err = try; swap(b, w => L); catch e; e; end
        @test err isa ArgumentError
        @test occursin("already determined", err.msg)
    end

    @testset "endogenize adds unknowns and drops the square claim" begin
        m, b, L, w, N, rho, J = setup()
        loose = endogenize(b, rho)
        @test all(v in unknowns(loose) for v in rho)
        @test length(unknowns(loose)) == 6
        @test !loose.assert_square                # the shape changed
        @test !issquare(loose)
        @test degrees_of_freedom(loose) == 2
    end

    @testset "exogenize removes unknowns" begin
        m, b, L, w, N, rho, J = setup()
        loose = endogenize(b, rho)
        back = exogenize(loose, rho)
        @test !(rho[1] in unknowns(back))
        @test length(unknowns(back)) == 4
    end

    @testset "exogenizing something an equation determines points at swap" begin
        m, b, L, w, N, rho, J = setup()
        err = try; exogenize(b, L); catch e; e; end
        @test err isa ArgumentError
        @test occursin("use swap", err.msg)
    end

    @testset "endogenize and exogenize leave the original alone" begin
        m, b, L, w, N, rho, J = setup()
        endogenize(b, rho)
        @test length(unknowns(b)) == 4
    end

    @testset "the primitives work on an optimization block too" begin
        # The point of building swap on membership: it means the same thing off the square path.
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @unknowns x
            x + y == 10
            @objective Min (x - 3)^2
        end
        wider = endogenize(b, y)
        @test length(unknowns(wider)) == 2
        @test degrees_of_freedom(wider) == 1
        out = solve(wider, Dataset(m); replace_nothing = 1.0)
        @test out[x] ≈ 3.0 atol = 1e-6
        @test out[y] ≈ 7.0 atol = 1e-6
    end
end
