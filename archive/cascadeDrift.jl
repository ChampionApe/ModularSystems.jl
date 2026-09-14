# C18, part two: is the block-triangular failure error amplification, and does it follow the
# predicted rate?
#
# Part one located the failure at subsystem 3136 of 4000 and showed the relative gap against the
# monolithic answer growing from 3e-16 at t = 1 to 4e+10 at t = 784. This asks whether that growth
# is the geometric amplification a recursive cascade must produce, at the rate the model's own
# forward map predicts.
#
# The mechanism, for the benchmark model. Near K = 0,
#
#     Y[t] = A[t] * 10 * (1 - exp(-K[t]/50))  ~  A[t] * K[t] / 5
#
# the core's last variable x[t,40] takes about a tenth of output, and capital accumulates as
#
#     K[t+1] = 0.9 K[t] + x[t,40]  ~  (0.9 + 0.02 A[t]) K[t]
#
# so the local gain is g(t) = 0.9 + 0.02 A[t], which crosses 1 exactly when A[t] > 5. With
# A[t] = 1 + 0.01 t that is t > 400. A cascade solves each period to solver tolerance and hands the
# answer on as exact data, so a residual e introduced at period s is multiplied by prod(g(t)) after
# it. If the prediction is right, the measured gap should track that product.

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
    return m, b, d, (K = K, Y = Y, w = w, x = x, A = A)
end

gain(t) = 0.9 + 0.02 * (1.0 + 0.01 * t)

function main()
    T, nsim = 700, 40        # short of the failure at 784, so both strategies finish
    println("C18 part two: does the cascade's drift follow the model's own forward gain?")
    println("T = ", T, ", core = ", nsim)
    println()
    @printf("local gain crosses 1 at t = %d (A[t] = 5)\n\n", 400)

    opts = SolveOptions(replace_nothing = 1.0)
    _, bm, dm, vm = build(T, nsim)
    mono = solve(bm, dm; options = opts)
    println("monolithic: converged")

    _, b, d, v = build(T, nsim)
    tri = try
        solve(b, d; options = opts, strategy = BlockTriangular())
    catch e
        println("block-triangular: FAILED at T = ", T, " (", nameof(typeof(e)), ")")
        nothing
    end
    tri === nothing && return
    println("block-triangular: converged")

    println("\nrelative gap in K, and the cumulative gain predicted from t = 1:")
    @printf("%8s %10s %16s %16s %14s\n", "t", "gain g(t)", "measured gap", "predicted", "ratio")
    cum = 1.0
    prev_t = 1
    for t in [1, 100, 200, 300, 400, 450, 500, 550, 600, 650, 700]
        for s in prev_t:(t - 1)
            cum *= max(gain(s), 1.0)      # only the expansive stretch amplifies
        end
        prev_t = t
        a, c = mono[vm.K[t]], tri[v.K[t]]
        gap = abs(a - c) / max(abs(a), 1e-300)
        @printf("%8d %10.4f %16.3e %16.3e %14.3e\n", t, gain(t), gap, 1e-16 * cum,
                gap / max(1e-16 * cum, 1e-300))
    end

    println("\nwhere the two paths actually are:")
    @printf("%8s %16s %16s\n", "t", "monolithic K", "cascade K")
    for t in [1, 200, 400, 500, 600, 700]
        @printf("%8d %16.6e %16.6e\n", t, mono[vm.K[t]], tri[v.K[t]])
    end

    # The guard this suggests: evaluate every equation of the WHOLE block against the cascade's
    # answer. Each subsystem is locally converged, so only a joint check can see the drift.
    # Each dataset must be evaluated against the block over ITS OWN model: a VariableRef from
    # another model is a different key, and Dataset refuses it rather than returning a plausible
    # wrong number.
    println("\nworst ABSOLUTE residual of the whole system, evaluated against each answer:")
    for (label, blk, ds) in (("monolithic", bm, mono), ("block-triangular", b, tri))
        worst = 0.0
        for c in blk.constraints
            ModularSystems.is_solved(c) || continue
            gap, _ = ModularSystems._check_gap(c, ds)
            worst = max(worst, gap)
        end
        @printf("  %-18s %12.3e\n", label, worst)
    end
    println("\nIf these are comparable, a post-solve residual check does NOT catch the drift: both")
    println("answers satisfy every equation to absolute tolerance, and the disagreement lives")
    println("entirely in the relative scale of a state variable passing near zero.")
end

main()
