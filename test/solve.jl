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

    # -----------------------------------------------------------------------------------------
    # Solving one subsystem at a time
    # -----------------------------------------------------------------------------------------

    # A recursive chain with a nonlinear tail: z depends on x and y, w on z, and nothing is
    # simultaneous, so it decomposes to four scalar subsystems.
    function cascade()
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        @variable(m, a)
        @variable(m, x)
        @variable(m, y)
        @variable(m, z)
        @variable(m, w)
        b = @block m begin
            @square
            z, z == y * x
            x, x == a + 1
            y, y == x + 1
            w, w * w + w == z + 12
        end
        d = Dataset(m)
        d[a] = 2.0
        return b, d, (x = x, y = y, z = z, w = w)
    end

    @testset "block-triangular gives the same answer as monolithic" begin
        b, d, v = cascade()
        mono = solve(b, d; replace_nothing = 1.0)
        tri = solve(b, d; replace_nothing = 1.0, strategy = BlockTriangular())
        for name in (:x, :y, :z, :w)
            @test mono[v[name]] ≈ tri[v[name]] atol = 1e-8
        end
        @test tri[v.x] ≈ 3.0
        @test tri[v.z] ≈ 12.0
    end

    @testset "the strategy travels in the options like any other setting" begin
        b, d, v = cascade()
        opts = SolveOptions(replace_nothing = 1.0, strategy = BlockTriangular())
        @test solve(b, d; options = opts)[v.z] ≈ 12.0
        # and a keyword still overrides it
        @test solve(b, d; options = opts, strategy = Monolithic())[v.z] ≈ 12.0
    end

    @testset "a subsystem solve records the total time and a termination status" begin
        b, d, _ = cascade()
        tri = solve(b, d; replace_nothing = 1.0, strategy = BlockTriangular())
        @test tri.meta.termination_status !== nothing
        @test tri.meta.solve_time >= 0
        @test tri.meta.objective_value === nothing
    end

    @testset "checks and binding bounds still apply across the whole block" begin
        b, d, v = cascade()
        add_check!(b, @build_constraint(v.z == 0), "z is zero")
        @test_throws CheckFailure solve(b, d; replace_nothing = 1.0,
                                        strategy = BlockTriangular())

        # x solves to exactly 3, so an upper bound of 3 is *binding* rather than infeasible: the
        # solver succeeds and lands on it, which is the case the diagnostic exists for. The check
        # runs once over the whole block after the last subsystem, so it still sees this.
        b2, d2, v2 = cascade()
        set_bounds!(d2, v2.x; upper = 3.0)
        @test_throws BindingBoundError solve(b2, d2; replace_nothing = 1.0,
                                             strategy = BlockTriangular())
    end

    @testset "an infeasible subsystem is reported against that subsystem" begin
        # The same bound tightened past the solution makes subsystem 1 genuinely infeasible.
        # Monolithically that is an infeasibility over the whole system; here it names x.
        b, d, v = cascade()
        set_bounds!(d, v.x; upper = 2.0)
        e = try
            solve(b, d; replace_nothing = 1.0, strategy = BlockTriangular())
        catch err
            err
        end
        @test e isa SubSystemFailure
        @test JuMP.name(only(e.variables)) == "x"
        @test e.position == 1
    end

    @testset "a deficient block refuses to be solved subsystem by subsystem" begin
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x)
        @variable(m, y)
        b = Block(m)
        add_constraint!(b, @build_constraint(x == 1))
        set_unknowns!(b, x, y)
        d = Dataset(m)
        e = try
            solve(b, d; replace_nothing = 1.0, strategy = BlockTriangular())
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("underdetermined", e.msg)
        @test occursin("y", e.msg)
    end

    @testset "a failing subsystem says which one it was" begin
        # x solves fine; y is then asked for a real square root of a negative number, with a bound
        # keeping it away from any complex escape. The failure must name y rather than the block.
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes",
                                                            "max_iter" => 20))
        @variable(m, x)
        @variable(m, y >= 1)
        b = @block m begin
            @square
            x, x == 4
            y, y * y == -x
        end
        d = Dataset(m)
        e = try
            solve(b, d; replace_nothing = 1.0, strategy = BlockTriangular())
        catch err
            err
        end
        @test e isa SubSystemFailure
        @test e.position == 2
        @test e.total == 2
        @test JuMP.name(only(e.variables)) == "y"
        @test occursin("subsystem 2 of 2", sprint(showerror, e))
        @test occursin("y", sprint(showerror, e))
    end

    @testset "a solved inequality makes a block-triangular solve refuse" begin
        # An inequality determines nothing, so it belongs to no subsystem, so nothing would add it
        # to any model. Before this was caught, the two strategies returned DIFFERENT ROOTS: the
        # inequality picks x = -3, and the block-triangular path dropped it and returned +3 while
        # reporting success. A wrong answer delivered quietly is the thing this package is most
        # careful about, so the refusal is pinned here.
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        @variable(m, x)
        b = Block(m)
        add_constraint!(b, @build_constraint(x * x == 9), determines = x)
        add_constraint!(b, @build_constraint(x <= 0))
        set_unknowns!(b, x)
        d = Dataset(m)

        # Monolithically the inequality does its job.
        @test solve(b, d; replace_nothing = -1.0)[x] ≈ -3.0

        e = try
            solve(b, d; replace_nothing = -1.0, strategy = BlockTriangular())
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("inequality", e.msg)
        @test occursin("different problem", e.msg)

        # The decomposition itself is right to ignore it — the refusal belongs on the solve path.
        @test iswelldetermined(decompose(b))
    end

    @testset "an interrupt is not reported as a subsystem failure" begin
        # Wrapping InterruptException would report Ctrl-C mid-solve as a numerical problem. The
        # factory throwing it stands in for the user pressing the key inside the solve.
        m = Model()
        set_optimizer_factory!(m, () -> throw(InterruptException()))
        @variable(m, x)
        b = @block m begin
            @square
            x, x == 1
        end
        d = Dataset(m)
        @test_throws InterruptException solve(b, d; replace_nothing = 1.0,
                                              strategy = BlockTriangular())
    end

    @testset "an objective cannot be solved by subsystems" begin
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        @variable(m, x)
        b = @block m begin
            @unknowns x
            @objective Min (x - 2)^2
            x >= 0
        end
        d = Dataset(m)
        @test_throws ArgumentError solve(b, d; replace_nothing = 1.0,
                                         strategy = BlockTriangular())
    end
end
