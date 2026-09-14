@testset "options.jl" begin

    @testset "defaults match what solve used to hard-code" begin
        o = SolveOptions()
        @test o.optimizer === nothing
        @test o.replace_nothing === nothing
        @test o.check_binding_bounds
        @test o.bound_tolerance == 1e-6
        @test o.silent
        @test o.run_checks
        @test o.check_atol == 1e-6
        @test o.check_rtol == 1e-8
    end

    @testset "keyword construction converts" begin
        o = SolveOptions(replace_nothing = 1, bound_tolerance = 1//100)
        @test o.replace_nothing === 1.0
        @test o.bound_tolerance === 0.01
    end

    @testset "deriving changes only what is named" begin
        base = SolveOptions(replace_nothing = 2.0, silent = false, check_atol = 1e-4)
        derived = SolveOptions(base; silent = true)
        @test derived.silent
        @test derived.replace_nothing == 2.0
        @test derived.check_atol == 1e-4
        # and the original is untouched
        @test !base.silent
    end

    @testset "deriving rejects a field that does not exist" begin
        e = try
            SolveOptions(SolveOptions(); slient = true)
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("slient", e.msg)
        @test occursin("bound_tolerance", e.msg)   # lists the real fields
    end

    @testset "equality is by value, so options can be compared" begin
        @test SolveOptions(silent = false) == SolveOptions(silent = false)
        @test SolveOptions(silent = false) != SolveOptions(silent = true)
    end

    @testset "show reports only what differs from the defaults" begin
        @test occursin("defaults", sprint(show, SolveOptions()))
        s = sprint(show, SolveOptions(silent = false, replace_nothing = 1.0))
        @test occursin("silent = false", s)
        @test occursin("replace_nothing = 1.0", s)
        @test !occursin("check_rtol", s)
    end

    @testset "solve takes options, and keywords override them" begin
        m = Model()
        set_optimizer_factory!(m, Ipopt.Optimizer)
        @variable(m, x)
        @variable(m, a)
        b = @block m begin
            @square
            x, x == 2 * a
        end
        d = Dataset(m)
        d[a] = 3.0

        quiet = SolveOptions(silent = true, replace_nothing = 0.0)
        @test solve(b, d; options = quiet)[x] ≈ 6.0

        # A check that cannot hold at the solution, so whether it is evaluated is observable.
        add_check!(b, @build_constraint(x == 0), "x is zero")
        @test_throws CheckFailure solve(b, d; options = quiet)
        # The keyword wins over the options it was passed alongside.
        @test solve(b, d; options = quiet, run_checks = false)[x] ≈ 6.0
        # ...and the same override expressed through the options has the same effect.
        @test solve(b, d; options = SolveOptions(quiet; run_checks = false))[x] ≈ 6.0
    end

    @testset "an options optimizer is used without attaching itself to the model" begin
        m = Model()
        @variable(m, x)
        @variable(m, a)
        b = @block m begin
            @square
            x, x == a + 1
        end
        d = Dataset(m)
        d[a] = 1.0

        # No factory on the model, so the solve can only work if the options carried one.
        @test solve(b, d; optimizer = Ipopt.Optimizer, replace_nothing = 0.0)[x] ≈ 2.0
        # ...and it did not stay behind: the model still has no default optimizer.
        @test_throws ArgumentError solve(b, d; replace_nothing = 0.0)
    end

    @testset "named settings are reusable across models" begin
        opts = SolveOptions(optimizer = Ipopt.Optimizer, replace_nothing = 1.0)
        for _ in 1:2
            m = Model()
            @variable(m, x)
            b = @block m begin
                @square
                x, 2 * x == 6
            end
            d = Dataset(m)   # x has no value, so replace_nothing has to supply the start
            @test solve(b, d; options = opts)[x] ≈ 3.0
        end
    end

end
