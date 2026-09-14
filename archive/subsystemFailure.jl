# C18: why does a block-triangular solve fail at 43,000 unknowns when a monolithic one does not?
#
# Two hypotheses worth telling apart, because they mean opposite things:
#
#   (a) the benchmark model is degenerate at large T, so the limit is an artefact of the generator
#       and the crossover measurement should be rerun on a better-behaved model;
#   (b) error accumulates down the cascade. A monolithic solve enforces every equation jointly to
#       tolerance; a cascade fixes each subsystem's answer and hands it on as data, so whatever
#       residual it left is not revisited. If that is what is happening it is a real property of the
#       strategy and belongs in its docstring, not in the benchmark's footnotes.
#
# The distinguishing evidence is where it fails and what the values look like there. Under (a) the
# model goes somewhere silly at large t regardless of strategy. Under (b) the monolithic answer at
# the failing point is perfectly ordinary and only the cascade has drifted.

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

function main()
    T, nsim = 1000, 40
    println("C18: locating the block-triangular failure at T = ", T, ", core = ", nsim)
    println()

    # Monolithic first, so there is a reference answer to compare against.
    _, bm, dm, vm = build(T, nsim)
    mono = nothing
    try
        mono = solve(bm, dm; options = SolveOptions(replace_nothing = 1.0))
        println("monolithic: converged")
    catch e
        println("monolithic: FAILED (", nameof(typeof(e)), ") — hypothesis (a) gains support")
    end

    _, b, d, v = build(T, nsim)
    local failure = nothing
    try
        solve!(b, d; options = SolveOptions(replace_nothing = 1.0), strategy = BlockTriangular())
        println("block-triangular: converged (the failure did not reproduce)")
        return
    catch e
        e isa SubSystemFailure || rethrow()
        failure = e
    end

    @printf("\nblock-triangular failed at subsystem %d of %d (%.1f%% of the way through)\n",
            failure.position, failure.total, 100 * failure.position / failure.total)
    println("solving for: ", join((JuMP.name(x) for x in Iterators.take(failure.variables, 6)), ", "),
            length(failure.variables) > 6 ? " …" : "")

    # `solve!` wrote every subsystem before the failing one, so `d` holds the cascade's own answer up
    # to that point. Comparing it with the monolithic answer at the same t is the whole question.
    failed_t = 0
    for t in 1:T
        d[v.K[t]] === nothing && (failed_t = t; break)
    end
    failed_t == 0 && (failed_t = T)
    println("\nfirst period with no capital written: t = ", failed_t)

    println("\nthe cascade's own path, approaching the failure:")
    @printf("%8s %14s %14s %14s %14s\n", "t", "A", "K", "Y", "x[t,40]")
    for t in unique([1, 2, max(1, failed_t ÷ 4), max(1, failed_t ÷ 2),
                     max(1, failed_t - 3), max(1, failed_t - 2), max(1, failed_t - 1), failed_t])
        get(x) = x === nothing ? NaN : x
        @printf("%8d %14.4f %14.4f %14.4f %14.4f\n",
                t, get(d[v.A[t]]), get(d[v.K[t]]), get(d[v.Y[t]]), get(d[v.x[t, nsim]]))
    end

    if mono !== nothing
        println("\nthe monolithic answer at the same periods:")
        @printf("%8s %14s %14s %14s\n", "t", "K", "Y", "x[t,40]")
        for t in unique([1, max(1, failed_t ÷ 2), max(1, failed_t - 1), failed_t])
            @printf("%8d %14.4f %14.4f %14.4f\n",
                    t, mono[vm.K[t]], mono[vm.Y[t]], mono[vm.x[t, nsim]])
        end

        # If the cascade drifted, the gap grows with t. If the model is degenerate, both go silly.
        println("\ngap between the two, where both have an answer:")
        @printf("%8s %16s %16s\n", "t", "abs gap in K", "rel gap in K")
        for t in unique([1, max(1, failed_t ÷ 4), max(1, failed_t ÷ 2), max(1, failed_t - 1)])
            a, c = mono[vm.K[t]], d[v.K[t]]
            c === nothing && continue
            @printf("%8d %16.3e %16.3e\n", t, abs(a - c), abs(a - c) / max(abs(a), 1e-12))
        end
    end

    println("\nthe underlying cause reported by the solver:")
    showerror(stdout, failure.cause)
    println()
end

main()
