@testset "solve.jl" begin
    # A small square system: x == 2, y == a + x, with a exogenous.
    function linear()
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x)
        @variable(m, y)
        @variable(m, a)
        b = Block(m; square = true)
        add_constraint!(b, @build_constraint(x == 2), determines = x)
        add_constraint!(b, @build_constraint(y == a + x), determines = y)
        d = Dataset(m)
        d[a] = 3.0
        return m, b, d, x, y, a
    end

    @testset "a square linear system" begin
        _, b, d, x, y, a = linear()
        out = solve(b, d; replace_nothing = 1.0)
        @test out[x] ≈ 2.0
        @test out[y] ≈ 5.0
        @test d[x] === nothing               # solve leaves the original untouched
        @test out.meta.termination_status == MOI.LOCALLY_SOLVED
    end

    @testset "solve! writes in place" begin
        _, b, d, x, y, _ = linear()
        returned = solve!(b, d; replace_nothing = 1.0)
        @test returned === d
        @test d[x] ≈ 2.0
        @test d[y] ≈ 5.0
    end

    @testset "exogenous values are substituted, so changing one changes the answer" begin
        _, b, d, x, y, a = linear()
        d[a] = 10.0
        out = solve(b, d; replace_nothing = 1.0)
        @test out[y] ≈ 12.0
        @test out[a] == 10.0                 # exogenous variables are not rewritten
    end

    @testset "a missing exogenous value is named" begin
        m, b, d, _, _, a = linear()
        d[a] = nothing
        err = try; solve(b, d; replace_nothing = 1.0); catch e; e; end
        @test err isa ArgumentError
        @test occursin("no value for exogenous variable", err.msg)
        @test occursin("a", err.msg)
    end

    @testset "a nonlinear square system" begin
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x)
        @variable(m, c)
        b = Block(m; square = true)
        add_constraint!(b, @build_constraint(x^2 == c), determines = x)
        d = Dataset(m)
        d[c] = 9.0
        d[x] = 2.0                            # start near the positive root
        out = solve(b, d)
        @test out[x] ≈ 3.0 atol = 1e-6
    end

    @testset "a quadratic term with an exogenous factor" begin
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x)
        @variable(m, y)
        @variable(m, k)
        b = Block(m; square = true)
        add_constraint!(b, @build_constraint(x == 4), determines = x)
        add_constraint!(b, @build_constraint(y == k * x), determines = y)
        d = Dataset(m)
        d[k] = 2.5
        out = solve(b, d; replace_nothing = 1.0)
        @test out[y] ≈ 10.0
    end

    @testset "dataset bounds are applied to the intermediate model" begin
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x)
        @variable(m, y)
        b = Block(m)
        add_constraint!(b, @build_constraint(x + y == 10))
        set_unknowns!(b, x, y)
        d = Dataset(m)
        set_bounds!(d, x; lower = 8.0)
        out = solve(b, d; replace_nothing = 1.0, check_binding_bounds = false)
        @test out[x] >= 8.0 - 1e-6
    end

    @testset "a binding bound on a square solve raises" begin
        # The solution exists and lands exactly on the bound. The equation determined x = 5 and the
        # bound is active there, which on a square system means the bound is doing work it should not.
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x)
        b = Block(m; square = true)
        add_constraint!(b, @build_constraint(x == 5), determines = x)
        d = Dataset(m)
        set_bounds!(d, x; lower = 5.0)
        err = try; solve(b, d; replace_nothing = 1.0); catch e; e; end
        @test err isa BindingBoundError
        @test occursin("did not determine the answer", sprint(showerror, err))
        @test occursin("x", sprint(showerror, err))
    end

    @testset "the binding-bound check can be turned off" begin
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x)
        b = Block(m; square = true)
        add_constraint!(b, @build_constraint(x == 5), determines = x)
        d = Dataset(m)
        set_bounds!(d, x; lower = 5.0)
        out = solve(b, d; replace_nothing = 1.0, check_binding_bounds = false)
        @test out[x] ≈ 5.0
    end

    @testset "a bound that excludes the solution surfaces as an infeasible solve" begin
        # Distinct from a binding bound, and it is the more common failure: the solver reports
        # infeasibility before the binding-bound check is ever reached.
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x)
        b = Block(m; square = true)
        add_constraint!(b, @build_constraint(x == 2), determines = x)
        d = Dataset(m)
        set_bounds!(d, x; lower = 5.0)
        @test_throws Exception solve(b, d; replace_nothing = 1.0)
    end

    @testset "a non-binding bound does not raise" begin
        _, b, d, x, _, _ = linear()
        set_bounds!(d, x; lower = -100.0, upper = 100.0)
        out = solve(b, d; replace_nothing = 1.0)
        @test out[x] ≈ 2.0
    end

    @testset "bounds that cannot overlap are caught before the solver runs" begin
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x >= 5)                 # intrinsic
        b = Block(m; square = true)
        add_constraint!(b, @build_constraint(x == 2), determines = x)
        d = Dataset(m)
        set_bounds!(d, x; upper = 1.0)       # problem bound, disjoint from the intrinsic one
        err = try; solve(b, d; replace_nothing = 1.0); catch e; e; end
        @test err isa ArgumentError
        @test occursin("empty effective bound interval", err.msg)
    end

    @testset "start values come from a dataset when given" begin
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x)
        @variable(m, c)
        b = Block(m; square = true)
        add_constraint!(b, @build_constraint(x^2 == c), determines = x)
        d = Dataset(m)
        d[c] = 9.0
        starts = Dataset(m)
        starts[x] = -2.0                     # steer to the negative root
        out = solve(b, d; start_values = starts)
        @test out[x] ≈ -3.0 atol = 1e-6
    end

    @testset "a block with an objective takes the optimization path" begin
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        @variable(m, x)
        b = Block(m)
        add_constraint!(b, @build_constraint(x >= 1))
        set_unknowns!(b, x)
        set_objective!(b, MOI.MIN_SENSE, x)
        out = solve(b, Dataset(m); replace_nothing = 5.0)
        @test out[x] ≈ 1.0 atol = 1e-6
        @test out.meta.objective_value ≈ 1.0 atol = 1e-6
    end

    @testset "a block declared square but not square fails before the solver runs" begin
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x)
        @variable(m, y)
        b = Block(m; square = true)
        add_constraint!(b, @build_constraint(x + y == 1))    # unpaired
        set_unknowns!(b, x, y)
        d = Dataset(m)
        @test_throws ArgumentError solve(b, d; replace_nothing = 1.0)
    end

    @testset "a model with no optimizer says so" begin
        m = Model()
        @variable(m, x)
        b = Block(m; square = true)
        add_constraint!(b, @build_constraint(x == 1), determines = x)
        d = Dataset(m)
        err = try; solve(b, d); catch e; e; end
        @test err isa ArgumentError
        @test occursin("no optimizer", err.msg)
    end

    @testset "calibration is the same block with a different unknown set" begin
        # x is observed; solve for the parameter a that reproduces it.
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x)
        @variable(m, y)
        @variable(m, a)

        behavioural = Block(m; square = true)
        add_constraint!(behavioural, @build_constraint(x == 2), determines = x)
        add_constraint!(behavioural, @build_constraint(y == a * x), determines = y)

        calibration = Block(m)
        add_constraint!(calibration, @build_constraint(y == a * x))
        set_unknowns!(calibration, a)

        d = Dataset(m)
        d[x] = 2.0
        d[y] = 10.0
        calibrated = solve(calibration, d; replace_nothing = 1.0)
        @test calibrated[a] ≈ 5.0

        # and the calibrated parameter reproduces the observation
        scenario = solve(behavioural, calibrated; replace_nothing = 1.0)
        @test scenario[y] ≈ 10.0
    end
end
