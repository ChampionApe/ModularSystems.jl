@testset "problem.jl" begin

    # A two-stage workflow: calibrate rho against observed L, then solve behaviourally.
    function workshop()
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        @variable(m, L)
        @variable(m, w)
        @variable(m, rho)
        @variable(m, N)
        behavioural = @block m begin
            @square
            L, L == rho * N
            w, w == 2 * L
        end
        calibration = swap(behavioural, rho => L)
        d = Dataset(m)
        d[N] = 10.0
        d[L] = 40.0
        return m, behavioural, calibration, d, (L = L, w = w, rho = rho, N = N)
    end

    @testset "a problem checks its block at construction" begin
        _, behavioural, _, d, _ = workshop()
        p = Problem(behavioural, d)
        @test p.block === behavioural
        @test p.data === d
        @test p.start === nothing
        @test p.options == SolveOptions()
    end

    @testset "an unsolvable block cannot become a problem" begin
        m = Model()
        @variable(m, x)
        @variable(m, y)
        b = Block(m)
        add_constraint!(b, @build_constraint(x == 1))
        set_unknowns!(b, x, y)          # nothing determines y
        d = Dataset(m)
        e = try
            Problem(b, d)
        catch err
            err
        end
        @test e isa StructuralError
        @test !isclean(e.diagnosis)
        @test occursin("cannot be solved", sprint(showerror, e))
        # and the check can be declined deliberately
        @test Problem(b, d; check = false) isa Problem
    end

    @testset "a dataset from another model is refused" begin
        _, behavioural, _, _, _ = workshop()
        other = Model()
        @variable(other, z)
        @test_throws ArgumentError Problem(behavioural, Dataset(other))
    end

    @testset "solving a problem uses its own data and options" begin
        _, behavioural, calibration, d, v = workshop()
        cal = Problem(calibration, d; options = SolveOptions(replace_nothing = 1.0))
        out = solve(cal)
        @test out[v.rho] ≈ 4.0
        @test d[v.rho] === nothing        # solve left the problem's dataset alone
        solve!(cal)
        @test d[v.rho] ≈ 4.0              # solve! wrote into it
    end

    @testset "a keyword overrides the problem's options" begin
        _, _, calibration, d, v = workshop()
        cal = Problem(calibration, d; options = SolveOptions(replace_nothing = 1.0))
        add_check!(calibration, @build_constraint(v.rho == 0), "rho is zero")
        @test_throws CheckFailure solve(cal)
        @test solve(cal; run_checks = false)[v.rho] ≈ 4.0
    end

    @testset "a problem derives from another" begin
        m, behavioural, calibration, d, v = workshop()
        base = Problem(behavioural, d; options = SolveOptions(replace_nothing = 1.0))
        other = Dataset(m)
        other[v.N] = 20.0
        other[v.rho] = 4.0
        shock = Problem(base; data = other, start = d)
        @test shock.block === base.block
        @test shock.options == base.options       # carried over
        @test shock.data === other                # replaced
        @test shock.start === d
        @test solve(shock)[v.L] ≈ 80.0
    end

    @testset "assert_solvable is the assertion form of diagnose" begin
        _, behavioural, _, d, v = workshop()
        @test assert_solvable(behavioural) === behavioural

        # `rho` is exogenous to the behavioural block and the observed data has not got it — it is
        # what the calibration exists to produce. So the block is sound and the pairing of block
        # with *this* data is not, which is exactly the distinction the two forms draw.
        @test_throws StructuralError assert_solvable(behavioural, d)
        d[v.rho] = 4.0
        @test assert_solvable(behavioural, d) === behavioural

        # A dataset missing an exogenous value is a data problem, not a structural one: the
        # block-only form must pass where the form with data does not.
        m2 = Model()
        @variable(m2, x)
        @variable(m2, a)
        b2 = @block m2 begin
            @square
            x, x == a
        end
        empty_data = Dataset(m2)
        @test assert_solvable(b2) === b2
        @test_throws StructuralError assert_solvable(b2, empty_data)
        # ...which is also why Problem checks the block only.
        @test Problem(b2, empty_data) isa Problem
    end

    @testset "show says the shape" begin
        _, behavioural, _, d, _ = workshop()
        s = sprint(show, Problem(behavioural, d))
        @test occursin("2 constraints", s)
        @test occursin("2 unknowns", s)
        # Cheap facts only: showing the largest subsystem would decompose the model on every
        # unnamed expression at the REPL.
        @test !occursin("subsystem", s)
    end

end

@testset "spec.jl" begin

    function two_stage()
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        @variable(m, L)
        @variable(m, w)
        @variable(m, rho)
        @variable(m, N)
        behavioural = @block m begin
            @square
            L, L == rho * N
            w, w == 2 * L
        end
        calibration = swap(behavioural, rho => L)
        observed = Dataset(m)
        observed[N] = 10.0
        observed[L] = 40.0
        opts = SolveOptions(replace_nothing = 1.0)

        spec = ModelSpec(m)
        register!(spec, :calibration, Problem(calibration, observed; options = opts))
        register!(spec, :baseline, Problem(behavioural, observed; options = opts))
        return m, spec, observed, (L = L, w = w, rho = rho, N = N)
    end

    @testset "modes come back in registration order" begin
        _, spec, _, _ = two_stage()
        @test modes(spec) == [:calibration, :baseline]
        @test length(spec) == 2
        @test haskey(spec, :baseline)
        @test !haskey(spec, :nonsense)
        @test spec[:baseline] isa Problem
    end

    @testset "a duplicate name is refused rather than silently replacing" begin
        _, spec, observed, _ = two_stage()
        p = spec[:baseline]
        e = try
            register!(spec, :baseline, p)
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("already registered", e.msg)
        # and removing it first is the way to mean it
        unregister!(spec, :baseline)
        @test modes(spec) == [:calibration]
        @test register!(spec, :baseline, p) === spec
        @test modes(spec) == [:calibration, :baseline]
    end

    @testset "unregistering something absent raises" begin
        _, spec, _, _ = two_stage()
        @test_throws KeyError unregister!(spec, :nonsense)
    end

    @testset "a mode over another model is refused" begin
        _, spec, _, _ = two_stage()
        other = Model()
        @variable(other, z)
        b = @block other begin
            @square
            z, z == 1
        end
        p = Problem(b, Dataset(other))
        @test_throws ArgumentError register!(spec, :elsewhere, p)
    end

    @testset "the whole workflow solves through the spec" begin
        _, spec, observed, v = two_stage()
        solve!(spec, :calibration)
        @test observed[v.rho] ≈ 4.0
        out = solve(spec, :baseline)
        @test out[v.L] ≈ 40.0
    end

    @testset "diagnose covers every mode at once" begin
        _, spec, _, v = two_stage()
        report = diagnose(spec)
        @test [name for (name, _) in report] == [:calibration, :baseline]

        # The whole workflow in one call: calibration is ready to run, baseline is not, because the
        # parameter it needs is what calibration produces. That ordering constraint is visible
        # without running anything, and without anyone having declared it.
        byname = Dict(report)
        @test isclean(byname[:calibration])
        @test !isclean(byname[:baseline])
        @test [JuMP.name(x) for x in byname[:baseline].missing_values] == ["rho"]

        # Once calibration has run, the baseline mode is ready too.
        solve!(spec, :calibration)
        @test all(isclean(x) for (_, x) in diagnose(spec))

        # Structurally — block only, no data — every mode was sound from the start.
        @test assert_solvable(spec) === spec
    end

    @testset "readiness is the workflow's order, derived rather than declared" begin
        # This is what replaced an inferred dependency graph. Nobody says the calibration comes
        # first; it is first because the baseline's parameter is not in the data until it has run.
        _, spec, _, _ = two_stage()
        @test ready(spec) == [:calibration]
        solve!(spec, :calibration)
        @test ready(spec) == [:calibration, :baseline]
    end

    @testset "show reports readiness against the data, not the block alone" begin
        _, spec, _, _ = two_stage()
        @test occursin("2 modes", sprint(show, spec))
        long = sprint(show, MIME("text/plain"), spec)
        @test occursin(":calibration", long)
        @test occursin(":baseline", long)
        # The block-only check is true of every mode at all times, so reporting it would say "ok"
        # beside a mode that cannot run. It must say what is missing instead.
        @test occursin("ready", long)
        @test occursin("needs rho", long)

        solve!(spec, :calibration)
        @test !occursin("needs", sprint(show, MIME("text/plain"), spec))
    end

    @testset "a mode can carry a line of prose" begin
        m, spec, observed, _ = two_stage()
        p = spec[:baseline]
        unregister!(spec, :baseline)
        register!(spec, :baseline, p; about = "forward run, energy linked")
        @test occursin("forward run, energy linked", sprint(show, MIME("text/plain"), spec))
        unregister!(spec, :baseline)
        @test !occursin("forward run", sprint(show, MIME("text/plain"), spec))
    end

    # A block nothing can determine `lonely` from, used by the two tests below.
    function broken_problem(m)
        @variable(m, stray)
        @variable(m, lonely)
        b = Block(m)
        add_constraint!(b, @build_constraint(stray == 1))
        set_unknowns!(b, stray, lonely)
        return Problem(b, Dataset(m); check = false)
    end

    @testset "an unsound mode is named in the error" begin
        m, spec, _, _ = two_stage()
        register!(spec, :broken, broken_problem(m))
        e = try
            assert_solvable(spec)
        catch err
            err
        end
        @test e isa StructuralError
        @test occursin("mode :broken", sprint(showerror, e))
    end

    @testset "deriving with the same block does not re-run the structural check" begin
        m, _, _, _ = two_stage()
        bad = broken_problem(m)
        # The check reads only the block, so deriving over the same block cannot change its answer,
        # and re-running it is pure cost. Observable: this block would fail the check, and deriving
        # from a problem that already declined it must not resurrect it.
        @test Problem(bad; data = Dataset(m)) isa Problem
        # Supplying a different block does re-check, and this one does not pass.
        @test_throws StructuralError Problem(bad; block = copy(bad.block))
    end

end
