@testset "optimization path" begin
    function testmodel()
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        return m
    end

    @testset "minimise a quadratic subject to an equality" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @unknowns x, y
            x + y == 10
            @objective Min (x - 3)^2
        end
        @test !issquare(b)
        @test degrees_of_freedom(b) == 1

        d = Dataset(m)
        out = solve(b, d; replace_nothing = 1.0)
        @test out[x] ≈ 3.0 atol = 1e-6
        @test out[y] ≈ 7.0 atol = 1e-6
        @test out.meta.objective_value ≈ 0.0 atol = 1e-6
    end

    @testset "Max sense" begin
        m = testmodel()
        @variable(m, x)
        b = @block m begin
            @unknowns x
            x <= 4
            @objective Max x
        end
        d = Dataset(m)
        out = solve(b, d; replace_nothing = 0.0)
        @test out[x] ≈ 4.0 atol = 1e-6
        @test out.meta.objective_value ≈ 4.0 atol = 1e-6
    end

    @testset "the objective is substituted from the dataset like any other expression" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, target)
        b = @block m begin
            @unknowns x
            x >= 0
            @objective Min (x - target)^2
        end
        d = Dataset(m)
        d[target] = 7.0
        out = solve(b, d; replace_nothing = 1.0)
        @test out[x] ≈ 7.0 atol = 1e-6
        @test out[target] == 7.0          # exogenous, not rewritten
    end

    @testset "no objective means no objective value" begin
        m = testmodel()
        @variable(m, x)
        b = @block m begin
            @square
            x, x == 2
        end
        out = solve(b, Dataset(m); replace_nothing = 1.0)
        @test out.meta.objective_value === nothing
    end

    @testset "a binding bound is reported, not raised, on an optimization solve" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @unknowns x, y
            x + y == 10
            @objective Min x
        end
        d = Dataset(m)
        set_bounds!(d, x; lower = 2.0)    # the objective drives x onto its bound
        out = solve(b, d; replace_nothing = 5.0)
        @test out[x] ≈ 2.0 atol = 1e-6
        @test length(out.meta.binding_bounds) == 1
        @test out.meta.binding_bounds[1][1] == x
        @test out.meta.binding_bounds[1][2] ≈ 2.0
    end

    @testset "the bound tolerance is looser than the solver's bound relaxation" begin
        # Regression for notes/crossCuttingFindings.md #1: Ipopt relaxes bounds and stops slightly
        # OUTSIDE them — about 1.7e-8 below a
        # lower bound in this case. A tolerance at solver precision detects nothing at all, so the
        # default must stay looser than the relaxation. Tightening it silently disables the check.
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @unknowns x, y
            x + y == 10
            @objective Min x
        end
        d = Dataset(m)
        set_bounds!(d, x; lower = 2.0)

        loose = solve(b, d; replace_nothing = 5.0, bound_tolerance = 1e-6)
        @test length(loose.meta.binding_bounds) == 1

        tight = solve(b, d; replace_nothing = 5.0, bound_tolerance = 1e-12)
        @test isempty(tight.meta.binding_bounds)        # not because the bound is inactive
        @test abs(tight[x] - 2.0) < 1e-6                # it is active; the tolerance simply missed it
    end

    @testset "a square solve records binding bounds too, before raising" begin
        m = testmodel()
        @variable(m, x)
        b = @block m begin
            @square
            x, x == 5
        end
        d = Dataset(m)
        set_bounds!(d, x; lower = 5.0)
        out = solve(b, d; replace_nothing = 1.0, check_binding_bounds = false)
        @test length(out.meta.binding_bounds) == 1
    end

    @testset "an objective over a fully paired block still optimises" begin
        # Pairings are inert when an objective is present: the block is not square, and the pairing
        # is only documentation. The equation still holds.
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            x, x == 2
            @unknowns x, y
            @objective Min (y - 6)^2
        end
        @test !issquare(b)
        d = Dataset(m)
        out = solve(b, d; replace_nothing = 1.0)
        @test out[x] ≈ 2.0 atol = 1e-6
        @test out[y] ≈ 6.0 atol = 1e-6
    end

    @testset "checks run on the optimization path too" begin
        m = testmodel()
        @variable(m, x)
        b = @block m begin
            @unknowns x
            x >= 3
            @objective Min x
            @check x <= 1  "deliberately wrong"
        end
        d = Dataset(m)
        @test_throws CheckFailure solve(b, d; replace_nothing = 5.0)
    end

    @testset "minimum-distance estimation" begin
        # The case the optimization path exists for: structural equations plus a parameter chosen to
        # fit observed data. Same block machinery, different unknown set and an objective.
        m = testmodel()
        J = 1:2
        @variable(m, L[J])
        @variable(m, N[J])
        @variable(m, rho)                 # one productivity shared by both types
        @variable(m, Lhat[J])             # observations

        estimation = @block m begin
            @unknowns rho, L
            [j ∈ J], L[j] == rho * N[j]
            @objective Min sum((L[j] - Lhat[j])^2 for j ∈ J)
        end

        d = Dataset(m)
        d[N] = [100.0, 200.0]
        d[Lhat] = [110.0, 190.0]
        out = solve(estimation, d; replace_nothing = 1.0)

        # Least squares through the origin: rho = sum(N .* Lhat) / sum(N .^ 2)
        expected = (100 * 110 + 200 * 190) / (100^2 + 200^2)
        @test out[rho] ≈ expected atol = 1e-6
        @test out.meta.objective_value > 0
    end
end
