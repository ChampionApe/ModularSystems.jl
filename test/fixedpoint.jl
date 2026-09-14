@testset "fixedpoint.jl" begin

    # Two one-variable models, soft-linked. Model A reads `pa` and writes `ya = f(pa)`; model B reads
    # `yb` and writes `pb = g(yb)`. The loop passes ya -> yb and pb -> pa, so the fixed point is
    # p = g(f(p)). Everything is linear, so the contraction factor is exactly controllable and the
    # convergent and divergent cases are both exact.
    function pair(gain)
        ma = Model()
        set_optimizer_factory!(ma, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        @variable(ma, ya)
        @variable(ma, pa)
        ba = @block ma begin
            @square
            ya, ya == 10 - pa
        end
        da = Dataset(ma)
        da[pa] = 1.0
        pa_problem = Problem(ba, da; options = SolveOptions(replace_nothing = 1.0))

        mb = Model()
        set_optimizer_factory!(mb, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        @variable(mb, yb)
        @variable(mb, pb)
        bb = @block mb begin
            @square
            pb, pb == gain * yb
        end
        db = Dataset(mb)
        db[yb] = 1.0
        pb_problem = Problem(bb, db; options = SolveOptions(replace_nothing = 1.0))

        step! = function ()
            solve!(pa_problem)
            db[yb] = da[ya]
            solve!(pb_problem)
            da[pa] = db[pb]
            return nothing
        end
        return step!, [da => pa], (da = da, db = db, pa = pa, ya = ya, pb = pb, yb = yb)
    end

    @testset "a contracting link converges to the fixed point" begin
        # p = gain * (10 - p)  =>  p = 10*gain / (1 + gain). At gain = 0.5 that is 10/3.
        step!, exchanged, v = pair(0.5)
        r = fixed_point!(step!, exchanged)
        @test r isa ConvergenceReport
        @test r.converged
        @test r.iterations > 1
        @test v.da[v.pa] ≈ 10 / 3 atol = 1e-6
        # and the two models agree about the quantity they exchanged
        @test v.da[v.ya] ≈ v.db[v.yb] atol = 1e-8
    end

    @testset "history has one entry per pass and ends at the reported change" begin
        step!, exchanged, _ = pair(0.5)
        r = fixed_point!(step!, exchanged)
        @test length(r.history) == r.iterations
        @test r.history[end] == r.change
        @test r.history[end] < r.history[1]
    end

    @testset "a diverging link raises rather than returning its last iterate" begin
        # gain = -2 makes the map p -> -2*(10 - p) expand by |2| per pass.
        step!, exchanged, _ = pair(-2.0)
        e = try
            fixed_point!(step!, exchanged; maxiter = 12)
        catch err
            err
        end
        @test e isa ConvergenceFailure
        @test e.maxiter == 12
        @test !e.report.converged
        @test e.report.iterations == 12
        msg = sprint(showerror, e)
        @test occursin("did not settle in 12 passes", msg)
        # Divergence is diagnosed from the raw magnitudes, not from the change in tolerance units:
        # a geometrically growing link has a roughly constant relative change.
        @test occursin("exchanged values grew", msg)
        @test !occursin("falling", msg)
    end

    @testset "raise = false returns the failure instead" begin
        step!, exchanged, _ = pair(-2.0)
        r = fixed_point!(step!, exchanged; maxiter = 5, raise = false)
        @test !r.converged
        @test r.iterations == 5
        @test length(r.history) == 5
    end

    @testset "damping converges a link that oscillates without it" begin
        # gain = 1.5 gives the map p -> 1.5*(10 - p), whose derivative is -1.5: it OSCILLATES and
        # grows. Damping d turns the derivative into (1-d)*(-1.5) + d = -1.5 + 2.5d, which is inside
        # (-1, 1) for d > 0.2. This is the whole case for having the keyword, so it is pinned.
        # maxiter is short on purpose: left long enough the undamped iterate overflows the solver
        # rather than the loop.
        step!, exchanged, v = pair(1.5)
        @test_throws ConvergenceFailure fixed_point!(step!, exchanged; maxiter = 15)

        step!, exchanged, v = pair(1.5)
        r = fixed_point!(step!, exchanged; damping = 0.5, maxiter = 200)
        @test r.converged
        # p = 1.5 * (10 - p)  =>  2.5p = 15  =>  p = 6
        @test v.da[v.pa] ≈ 6.0 atol = 1e-5
    end

    @testset "damping cannot rescue monotone divergence, and should not pretend to" begin
        # gain = -2 gives p -> -2*(10 - p), derivative +2. Damped it is (1-d)*2 + d = 2 - d, which is
        # still above 1 for every admissible d. Damping fixes overshoot, not expansion — worth a test
        # because the docstring claims it and a user reaching for it here needs the failure, not a
        # quiet wrong answer.
        for d in (0.0, 0.5, 0.9)
            step!, exchanged, _ = pair(-2.0)
            @test_throws ConvergenceFailure fixed_point!(step!, exchanged; maxiter = 10, damping = d)
        end
    end

    @testset "damping is written back, so the next pass reads it" begin
        # Observable: with damping the exchanged cell must never equal the raw value the step wrote,
        # until the two coincide at the fixed point.
        step!, exchanged, v = pair(0.5)
        seen = Float64[]
        wrapped = function ()
            step!()
            push!(seen, v.da[v.pa])     # the raw value, before damping
            return nothing
        end
        r = fixed_point!(wrapped, exchanged; damping = 0.5)
        @test r.converged
        @test v.da[v.pa] ≈ 10 / 3 atol = 1e-5
        @test seen[2] != seen[1]        # the second pass started from a damped value
    end

    @testset "the arguments are checked" begin
        step!, exchanged, v = pair(0.5)
        @test_throws ArgumentError fixed_point!(step!, Pair{Dataset,VariableRef}[])
        @test_throws ArgumentError fixed_point!(step!, exchanged; damping = 1.0)
        @test_throws ArgumentError fixed_point!(step!, exchanged; damping = -0.1)

        # A cell paired with a dataset over a different model would silently converge on nothing.
        _, other, w = pair(0.5)
        @test_throws ArgumentError fixed_point!(step!, [v.da => w.pa])
    end

    @testset "a link that is already at its fixed point converges in one pass" begin
        step!, exchanged, v = pair(0.5)
        fixed_point!(step!, exchanged)
        r = fixed_point!(step!, exchanged)
        @test r.converged
        @test r.iterations == 1
    end

    @testset "show says whether it converged" begin
        step!, exchanged, _ = pair(0.5)
        r = fixed_point!(step!, exchanged)
        @test occursin("converged after", sprint(show, r))
        # One pair, used once: calling pair() twice would hand the step of one linked system the
        # exchanged cells of another, and the loop would converge on a cell nothing was writing.
        bad_step!, bad_exchanged, _ = pair(-2.0)
        r2 = fixed_point!(bad_step!, bad_exchanged; maxiter = 3, raise = false)
        @test occursin("did NOT converge", sprint(show, r2))
    end

    @testset "damping cannot manufacture convergence" begin
        # THE regression test. Damping used to be applied before the change was measured, so the
        # measured change was (1 - damping) * |f(x) - x| and the effective tolerance was
        # tol / (1 - damping) -- unbounded. At damping = 0.95 a link with multiplier 1.00002, which
        # grows without bound, reported "converged after 1 pass". The measurement is now taken on the
        # raw iterate, so no amount of damping can shrink it.
        #
        # The multiplier is deliberately just above 1: an obviously explosive link outruns the
        # (1 - damping) shrink and hides the bug, which is why the original suite missed it.
        # The map is p -> gain*(10 - p), so the multiplier is -gain: gain = -1.00002 walks away by
        # 0.002% a pass. Deliberately just above 1, because an obviously explosive link outruns the
        # (1 - damping) shrink and hides the bug -- which is why the first version of this suite,
        # whose only expansion case was gain = -2, missed it entirely.
        for d in (0.0, 0.5, 0.9, 0.95, 0.99)
            step!, exchanged, _ = pair(-1.00002)
            r = fixed_point!(step!, exchanged; maxiter = 40, damping = d, raise = false)
            @test !r.converged
        end
    end

    @testset "accuracy does not degrade with damping" begin
        # The same ordering bug made the answer worse the harder you damped, silently: the reported
        # change stayed at tolerance while the true distance from the fixed point grew like
        # 1 / (1 - damping). Every damping level must now land on the same answer.
        for d in (0.0, 0.5, 0.9, 0.99)
            step!, exchanged, v = pair(0.5)
            r = fixed_point!(step!, exchanged; damping = d, maxiter = 20000)
            @test r.converged
            @test v.da[v.pa] ≈ 10 / 3 atol = 1e-5
        end
    end

    @testset "on success the datasets hold raw values, not a blend" begin
        # Returning before the blend is what makes this true. A blended answer is one no solve
        # produced, and the rest of each dataset was solved at the previous value.
        step!, exchanged, v = pair(0.5)
        fixed_point!(step!, exchanged; damping = 0.9)
        # pa is what model B last wrote, and ya is what model A produced from it: they must be
        # consistent with each other, which a blend would break.
        @test v.da[v.ya] ≈ 10 - v.da[v.pa] atol = 1e-4
    end

    @testset "change is measured in multiples of the tolerance" begin
        # So one number covers cells of any magnitude, and `converged` means change <= 1.
        step!, exchanged, _ = pair(0.5)
        r = fixed_point!(step!, exchanged)
        @test r.change <= 1
        @test all(h -> h >= 0, r.history)
        @test occursin("× tolerance", sprint(show, r))
    end

    @testset "a cell the step never writes is a wiring error, not a convergence one" begin
        # Naming the wrong cell is the one coupling mistake the loop can catch: a cell it watches but
        # the step never sets can never converge, and without this it would report Inf forever
        # without saying why.
        step!, exchanged, v = pair(0.5)
        m = JuMP.owner_model(v.pa)
        @variable(m, untouched)
        e = try
            fixed_point!(step!, [v.da => untouched]; maxiter = 3)
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("nothing in `step!` writes it", e.msg)
    end

    @testset "argument checks cover maxiter and the tolerances" begin
        step!, exchanged, _ = pair(0.5)
        @test_throws ArgumentError fixed_point!(step!, exchanged; maxiter = 0)
        @test_throws ArgumentError fixed_point!(step!, exchanged; maxiter = -3)
        @test_throws ArgumentError fixed_point!(step!, exchanged; atol = 0.0)
        @test_throws ArgumentError fixed_point!(step!, exchanged; rtol = -1.0)
    end

    @testset "a bare pair and a container are both accepted" begin
        step!, exchanged, v = pair(0.5)
        r = fixed_point!(step!, v.da => v.pa)       # not wrapped in a vector
        @test r.converged
    end

    @testset "a diverging failure says so even when the first pass had no value" begin
        # A cell with no value yet records Inf for that pass. Comparing a later change against Inf
        # would call every failure "falling", so the heuristic looks only at finite entries.
        # `pb` has no value until the first pass writes it, which is the ordinary case: a price
        # does not exist before the model that sets it has run.
        step!, _, v = pair(-2.0)
        r = fixed_point!(step!, [v.db => v.pb]; maxiter = 10, raise = false)
        @test !r.converged
        @test isinf(r.history[1])
        msg = sprint(showerror, ConvergenceFailure(r, 10))
        @test occursin("exchanged values grew", msg)
        @test !occursin("falling", msg)
    end
end
