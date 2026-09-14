@testset "residuals.jl" begin
    function setup()
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        J = 1:2
        @variable(m, L[J])
        @variable(m, N[J])
        @variable(m, rho[J])
        b = @block m begin
            @square
            L[j ∈ J], L[j] == rho[j] * N[j]
        end
        d = Dataset(m)
        d[N] = [100.0, 200.0]
        d[rho] = [1.0, 2.0]
        return m, b, d, L, N, rho, J
    end

    @testset "residuals are not created unless asked for" begin
        m, b, d, L, _, _, _ = setup()
        @test !has_residuals(b)
        @test isempty(residuals(b))
        @test residual(L[1]) === nothing
    end

    @testset "with_residuals adds one per paired constraint" begin
        m, b, d, L, _, _, _ = setup()
        before = num_variables(m)
        rb = with_residuals(b, d)
        @test has_residuals(rb)
        @test length(residuals(rb)) == 2
        @test num_variables(m) == before + 2
        @test residual(L[1]) !== nothing
        @test occursin("_J", name(residual(L[1])))
        @test !has_residuals(b)                  # the original block is untouched
    end

    @testset "a zero residual changes nothing" begin
        m, b, d, L, _, _, _ = setup()
        plain = solve(b, d; replace_nothing = 1.0)
        rb = with_residuals(b, d)
        withres = solve(rb, d; replace_nothing = 1.0)
        @test withres[L] ≈ plain[L]
        @test d[residual(L[1])] == 0.0
    end

    @testset "the datasets passed get zeros; others do not" begin
        m, b, d, L, _, _, _ = setup()
        other = Dataset(m)
        rb = with_residuals(b, d)
        @test d[residual(L[1])] == 0.0
        @test other[residual(L[1])] === nothing
        # and a solve against the un-zeroed dataset says exactly what is missing
        err = try; solve(rb, other; replace_nothing = 1.0); catch e; e; end
        @test err isa ArgumentError
        @test occursin("no value for exogenous variable", err.msg)
    end

    @testset "a residual locates inconsistent data" begin
        # The workflow residuals exist for: hold the observed value, let the residual absorb the gap.
        m, b, d, L, N, rho, J = setup()
        rb = with_residuals(b, d)

        d[L] = [150.0, 400.0]                    # observed; the equation implies 100 and 400
        check = swap(rb, residual(L[1]) => L[1])
        solve!(check, d; replace_nothing = 1.0)

        # L[1] == rho*N + ... written as L - rho*N + r == 0, so r = rho*N - L = 100 - 150
        @test d[residual(L[1])] ≈ -50.0 atol = 1e-6
        @test d[L[1]] == 150.0                   # held at the observation
    end

    @testset "a consistent observation leaves the residual at zero" begin
        m, b, d, L, N, rho, J = setup()
        rb = with_residuals(b, d)
        d[L] = [100.0, 400.0]                    # exactly what the equations imply
        check = swap(rb, residual(L[1]) => L[1])
        solve!(check, d; replace_nothing = 1.0)
        @test abs(d[residual(L[1])]) < 1e-6
    end

    @testset "calling with_residuals twice does not double the slack" begin
        m, b, d, L, _, _, _ = setup()
        rb = with_residuals(b, d)
        again = with_residuals(rb, d)
        @test length(residuals(again)) == 2
        @test num_variables(m) == num_variables(m)       # no new variables the second time
        d[L] = [150.0, 400.0]
        check = swap(again, residual(L[1]) => L[1])
        solve!(check, d; replace_nothing = 1.0)
        @test d[residual(L[1])] ≈ -50.0 atol = 1e-6      # still one residual's worth
    end

    @testset "unpaired constraints get no residual" begin
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @unknowns x, y
            x + y == 10
            x - y == 2
        end
        before = num_variables(m)
        rb = with_residuals(b)
        @test isempty(residuals(rb))
        @test num_variables(m) == before          # nothing created
    end

    @testset "residuals survive a swap and keep the block square" begin
        m, b, d, L, _, _, _ = setup()
        rb = with_residuals(b, d)
        @test issquare(rb)
        check = swap(rb, residual(L[1]) => L[1])
        @test issquare(check)
        @test length(check) == length(rb)
    end
end
