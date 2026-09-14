# Is block-triangular solving more ROBUST than monolithic, and does it ever become FASTER?
#
# v2 (decompositionBenchmarkRun.log) settled the speed question at small and medium sizes:
# block-triangular loses 5x to 110x, because entering an interior-point solver has a fixed cost that
# a one- or two-variable subsystem cannot amortise. Ipopt summed over 400 tiny solves cost 0.99 s
# against 0.004 s for the whole system at once.
#
# It also turned up one case where monolithic failed and block-triangular converged. One case is an
# anecdote. This run asks two things properly:
#
#   1. ROBUSTNESS. Over a grid of starting points and model shapes, how often does each strategy
#      converge? The mechanism that would explain an advantage is real: each subsystem is started
#      from the results of the ones before it, so the cascade has good starts where the monolithic
#      solve has whatever the user supplied.
#
#   2. CROSSOVER. Ipopt's cost per solve is roughly fixed plus something growing in n. The
#      block-triangular path pays the fixed cost many times; the monolithic path pays the growing
#      part once. There is a size where that reverses, if the model gets big enough to reach it.
#      This goes up to ~90,000 unknowns to find out whether it exists in practice.

using ModularSystems
using JuMP
using Ipopt
using Printf

const DELTA = 0.1

function build(T::Int, nsim::Int)
    m = Model()
    set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
    @variable(m, K[1:T])
    @variable(m, Y[1:T])
    @variable(m, w[1:T])
    @variable(m, x[1:T, 1:nsim])
    @variable(m, A[1:T])
    @variable(m, K0)

    b = Block(m)
    for t in 1:T
        if t == 1
            add_constraint!(b, @build_constraint(K[t] == K0), determines = K[t])
        else
            add_constraint!(b, @build_constraint(K[t] == (1 - DELTA) * K[t-1] + x[t-1, nsim]),
                            determines = K[t])
        end
        add_constraint!(b, @build_constraint(Y[t] == A[t] * 10 * (1 - exp(-K[t] / 50))),
                        determines = Y[t])
        add_constraint!(b, @build_constraint(w[t] == 0.7 * Y[t]), determines = w[t])
        for i in 1:nsim
            j = i == nsim ? 1 : i + 1
            if i == 1
                add_constraint!(b, @build_constraint(sum(x[t, k] for k in 1:nsim) == Y[t]),
                                determines = x[t, i])
            else
                add_constraint!(b, @build_constraint(x[t, i] * (1 + 0.01 * x[t, j]) == 0.1 * Y[t]),
                                determines = x[t, i])
            end
        end
    end
    d = Dataset(m)
    d[K0] = 50.0
    for t in 1:T
        d[A[t]] = 1.0 + 0.01 * t
    end
    return m, b, d
end

function guarded(f)
    t0 = time()
    try
        r = f()
        return (time() - t0, r, nothing)
    catch e
        return (time() - t0, nothing, string(nameof(typeof(e))))
    end
end

# ---------------------------------------------------------------------------------------------

function robustness_sweep()
    println("\n### 1. Convergence over a grid of starting points")
    println("Each cell is one model built fresh and solved from that start.\n")
    starts = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, -1.0, -10.0, -50.0]
    shapes = [(25, 2), (25, 10), (25, 40), (50, 10), (50, 40)]

    @printf("%-12s %8s %8s %10s %10s %10s\n",
            "shape", "mono ok", "tri ok", "mono only", "tri only", "of")
    println(repeat("-", 64))
    total_mono = total_tri = 0
    for (T, nsim) in shapes
        nm = nt = mono_only = tri_only = 0
        for s in starts
            _, b, d = build(T, nsim)
            opts = SolveOptions(replace_nothing = s)
            _, _, em = guarded(() -> solve(b, d; options = opts))
            _, _, et = guarded(
                () -> solve(b, d; options = SolveOptions(opts; strategy = BlockTriangular())))
            em === nothing && (nm += 1)
            et === nothing && (nt += 1)
            em === nothing && et !== nothing && (mono_only += 1)
            em !== nothing && et === nothing && (tri_only += 1)
        end
        total_mono += nm
        total_tri += nt
        @printf("T=%-3d core=%-3d %8d %8d %10d %10d %10d\n",
                T, nsim, nm, nt, mono_only, tri_only, length(starts))
        flush(stdout)
    end
    println(repeat("-", 64))
    @printf("%-12s %8d %8d\n", "total", total_mono, total_tri)
    println("\n'tri only' is where block-triangular converged and monolithic did not.")
    println("'mono only' is the reverse, and is the number that would sink the robustness claim.")
end

# ---------------------------------------------------------------------------------------------

function crossover()
    println("\n### 2. Does block-triangular ever become faster?")
    println("Larger and larger models, core = 40. Watching for tri/mono to fall below 1.\n")
    @printf("%6s %10s %8s %10s %12s %12s %10s\n",
            "T", "unknowns", "#sub", "decomp s", "mono s", "tri s", "tri/mono")
    println(repeat("-", 76))
    for T in [50, 100, 250, 500, 1000, 2000]
        _, b, d = build(T, 40)
        t_dec = @elapsed dec = decompose(b)
        opts = SolveOptions(replace_nothing = 1.0)
        t_mono, _, em = guarded(() -> solve(b, d; options = opts))
        _, b2, d2 = build(T, 40)
        t_tri, _, et = guarded(
            () -> solve(b2, d2; options = SolveOptions(opts; strategy = BlockTriangular())))

        monostr = em === nothing ? @sprintf("%12.2f", t_mono) : @sprintf("%12s", em)
        tristr = et === nothing ? @sprintf("%12.2f", t_tri) : @sprintf("%12s", et)
        ratiostr = (em === nothing && et === nothing) ?
            @sprintf("%10.2f", t_tri / t_mono) : @sprintf("%10s", "-")
        @printf("%6d %10d %8d %10.4f %s %s %s\n",
                T, length(unknowns(b)), length(subsystems(dec)), t_dec, monostr, tristr, ratiostr)
        flush(stdout)
    end
end

# ---------------------------------------------------------------------------------------------

function decomposition_cost()
    println("\n### 3. What the decomposition itself costs")
    println("This is the number that matters for using it as a diagnostic rather than a solver.\n")
    @printf("%6s %10s %10s %12s %14s\n", "T", "unknowns", "#sub", "decompose s", "per unknown us")
    println(repeat("-", 58))
    for T in [100, 500, 1000, 2000, 5000]
        _, b, _ = build(T, 40)
        decompose(b)                       # warm
        t = @elapsed dec = decompose(b)
        n = length(unknowns(b))
        @printf("%6d %10d %10d %12.4f %14.2f\n",
                T, n, length(subsystems(dec)), t, 1e6 * t / n)
        flush(stdout)
    end
end

function main()
    println("ModularSystems: robustness sweep and crossover search")
    println("Julia ", VERSION)
    print("\nwarming up... ")
    let (_, b, d) = build(5, 5)
        solve(b, d; options = SolveOptions(replace_nothing = 1.0))
        solve(b, d; options = SolveOptions(replace_nothing = 1.0, strategy = BlockTriangular()))
    end
    println("done")

    decomposition_cost()
    robustness_sweep()
    crossover()
    println("\nDONE")
end

main()
