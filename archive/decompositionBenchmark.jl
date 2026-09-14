# Does solving one subsystem at a time pay, and if not, where does the time go?
#
# v1 (kept at decompositionBenchmarkRun.v1.log) answered the first question: no, block-triangular was
# 11x to 53x SLOWER on a model whose subsystems are almost all scalar. This run asks why, and whether
# the picture changes when the subsystems are big enough for the per-subsystem overhead to amortise.
#
# The model is a recursive dynamic one. Each period has three scalar equations (capital from the
# period before, output from capital, wages from output) and one simultaneous core of `nsim`
# variables. `nsim = 2` is v1's shape; larger values are what a real multi-sector model looks like.
#
# Times are WALL times over a warmed session, so they include building the intermediate JuMP model —
# the honest comparison, since the block-triangular path builds one per subsystem and that cost is
# the question. Every solve is guarded, so one failure does not end the run: whether a strategy
# converges at all is part of what is being measured.

using ModularSystems
using JuMP
using Ipopt
using Printf

const DELTA = 0.1

"""
    build(T, nsim)

A T-period model with a simultaneous core of `nsim` variables per period. Returns the model, the
block, a dataset with the exogenous values set, and the unknown variables.
"""
function build(T::Int, nsim::Int)
    m = Model()
    set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))

    @variable(m, K[1:T])
    @variable(m, Y[1:T])
    @variable(m, w[1:T])
    @variable(m, x[1:T, 1:nsim])     # the simultaneous core
    @variable(m, A[1:T])             # exogenous
    @variable(m, K0)                 # exogenous

    b = Block(m)
    for t in 1:T
        if t == 1
            add_constraint!(b, @build_constraint(K[t] == K0), determines = K[t])
        else
            # Investment is the last element of the previous period's core.
            add_constraint!(b, @build_constraint(K[t] == (1 - DELTA) * K[t-1] + x[t-1, nsim]),
                            determines = K[t])
        end
        # Concave, increasing and defined for every K, so the solver cannot step off the domain.
        add_constraint!(b, @build_constraint(Y[t] == A[t] * 10 * (1 - exp(-K[t] / 50))),
                        determines = Y[t])
        add_constraint!(b, @build_constraint(w[t] == 0.7 * Y[t]), determines = w[t])

        # A cyclic, mildly nonlinear core: every equation touches its neighbour, so the whole of
        # x[t, :] is one strongly connected component.
        for i in 1:nsim
            j = i == nsim ? 1 : i + 1
            if i == 1
                add_constraint!(b, @build_constraint(
                    sum(x[t, k] for k in 1:nsim) == Y[t]), determines = x[t, i])
            else
                add_constraint!(b, @build_constraint(
                    x[t, i] * (1 + 0.01 * x[t, j]) == 0.1 * Y[t]), determines = x[t, i])
            end
        end
    end

    d = Dataset(m)
    d[K0] = 50.0
    for t in 1:T
        d[A[t]] = 1.0 + 0.01 * t
    end
    allvars = vcat(collect(K), collect(Y), collect(w), vec(collect(x)))
    return m, b, d, allvars
end

"""Run `f`, returning (elapsed, result, nothing) or (elapsed, nothing, exception name)."""
function guarded(f)
    t0 = time()
    try
        r = f()
        return (time() - t0, r, nothing)
    catch e
        return (time() - t0, nothing, string(nameof(typeof(e))))
    end
end

maxdiff(a, b, vars) = maximum(abs(a[v] - b[v]) for v in vars)

function timing_table(sizes, nsim)
    println()
    println("### Simultaneous core of ", nsim, " variables per period")
    @printf("%6s %9s %6s %8s %10s %10s %10s %9s %11s\n",
            "T", "unknowns", "#sub", "largest", "decomp s", "mono s", "tri s", "tri/mono", "agree")
    println(repeat("-", 92))
    for T in sizes
        _, b, d, allvars = build(T, nsim)
        dec = decompose(b)
        t_dec = @elapsed decompose(b)
        opts = SolveOptions(replace_nothing = 1.0)

        t_mono, mono, err_mono = guarded(() -> solve(b, d; options = opts))
        t_tri, tri, err_tri = guarded(
            () -> solve(b, d; options = SolveOptions(opts; strategy = BlockTriangular())))

        agree = (mono === nothing || tri === nothing) ? NaN : maxdiff(mono, tri, allvars)
        monostr = err_mono === nothing ? @sprintf("%10.3f", t_mono) : @sprintf("%10s", err_mono)
        tristr = err_tri === nothing ? @sprintf("%10.3f", t_tri) : @sprintf("%10s", err_tri)
        ratiostr = (err_mono === nothing && err_tri === nothing) ?
            @sprintf("%9.2f", t_tri / t_mono) : @sprintf("%9s", "-")

        @printf("%6d %9d %6d %8d %10.4f %s %s %s %11.2e\n",
                T, length(unknowns(b)), length(subsystems(dec)), largest_subsystem(dec),
                t_dec, monostr, tristr, ratiostr, agree)
        flush(stdout)
    end
end

"""Where the per-subsystem time goes: building the intermediate model, or optimizing it."""
function overhead_breakdown(T::Int, nsim::Int)
    println()
    println("### Per-subsystem overhead (T = ", T, ", core = ", nsim, ")")
    _, b, d, _ = build(T, nsim)
    dec = decompose(b)
    opts = SolveOptions(replace_nothing = 1.0, strategy = BlockTriangular())

    t_total, solved, err = guarded(() -> solve(b, d; options = opts))
    if err !== nothing
        println("  block-triangular failed: ", err)
        return
    end
    n = length(subsystems(dec))
    ipopt = solved.meta.solve_time
    @printf("  subsystems              %8d\n", n)
    @printf("  wall time               %8.3f s\n", t_total)
    @printf("  Ipopt's own solve time  %8.3f s  (%.0f%% of wall)\n", ipopt, 100 * ipopt / t_total)
    @printf("  everything else         %8.3f s  (%.2f ms per subsystem)\n",
            t_total - ipopt, 1000 * (t_total - ipopt) / n)
    println("  'everything else' is building one JuMP model and one solver instance per subsystem,")
    println("  plus substitution and write-back.")

    # For comparison: what one monolithic solve of the same model costs to build.
    t_mono, mono, errm = guarded(() -> solve(b, d; options = SolveOptions(opts;
                                                                         strategy = Monolithic())))
    if errm === nothing
        @printf("  monolithic wall         %8.3f s, of which Ipopt %.3f s\n",
                t_mono, mono.meta.solve_time)
    else
        println("  monolithic failed: ", errm)
    end
end

"""Which strategy still converges when started a long way from the solution."""
function robustness(T::Int, nsim::Int)
    println()
    println("### Convergence from a distant start (T = ", T, ", core = ", nsim, ")")
    for start in (1.0, 50.0, 500.0, -20.0)
        _, b, d, _ = build(T, nsim)
        opts = SolveOptions(replace_nothing = start)
        _, _, em = guarded(() -> solve(b, d; options = opts))
        _, _, et = guarded(() -> solve(b, d; options = SolveOptions(opts;
                                                                    strategy = BlockTriangular())))
        @printf("  start %7.1f   monolithic: %-22s  block-triangular: %s\n",
                start, em === nothing ? "converged" : em, et === nothing ? "converged" : et)
        flush(stdout)
    end
end

function main()
    println("ModularSystems block-triangular benchmark, v2")
    println("Julia ", VERSION)

    print("\nwarming up... ")
    build(5, 2)
    let (_, b, d, _) = build(5, 2)
        solve(b, d; options = SolveOptions(replace_nothing = 1.0))
        solve(b, d; options = SolveOptions(replace_nothing = 1.0, strategy = BlockTriangular()))
    end
    println("done")

    timing_table([10, 25, 50, 100, 200], 2)
    timing_table([10, 25, 50, 100], 10)
    timing_table([5, 10, 25, 50], 40)

    overhead_breakdown(100, 2)
    overhead_breakdown(50, 40)

    robustness(100, 2)
    robustness(50, 40)

    println("\nDONE")
end

main()
