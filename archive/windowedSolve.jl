# Can a window of periods be solved on its own, with what the package already has?
using ModularSystems, JuMP, Ipopt

const T = 20
m = Model(); set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
@variable(m, K[1:T] >= 1e-6); @variable(m, Y[1:T]); @variable(m, I[1:T])
@variable(m, A[1:T]); @variable(m, K0)

# One block per period. This is the whole trick: the horizon is a composition, so a window is too.
function period(t)
    b = Block(m)
    prev = t == 1 ? K0 : K[t - 1]
    add_constraint!(b, @build_constraint(K[t] == 0.9 * prev + (t == 1 ? 0.0 : I[t - 1])),
                    determines = K[t])
    add_constraint!(b, @build_constraint(Y[t] == A[t] * sqrt(K[t])), determines = Y[t])
    add_constraint!(b, @build_constraint(I[t] == 0.2 * Y[t]), determines = I[t])
    return b
end
periods = [period(t) for t in 1:T]

d = Dataset(m); d[K0] = 100.0
for t in 1:T; d[A[t]] = 1.0 + 0.01t; end
opts = SolveOptions(replace_nothing = 1.0)

# Whole horizon at once, for a reference answer.
whole = compose(periods)
full = solve(whole, d; options = opts)
println("whole horizon: ", length(unknowns(whole)), " unknowns, K[20] = ", round(full[K[20]], digits = 6))

# Rolling horizon: five windows of four periods, each solved on its own. Everything outside the
# window is exogenous, and each window reads the previous one's answer out of the dataset -- the
# same substitution path an ordinary solve uses.
rolling = copy(d)
for start in 1:4:T
    w = compose(periods[start:(start + 3)])
    solve!(w, rolling; options = opts)
end
println("rolling:       K[20] = ", round(rolling[K[20]], digits = 6))
println("worst gap over the whole path: ",
        maximum(abs(full[K[t]] - rolling[K[t]]) for t in 1:T))

# And a window is a Block -> Block function like any other mode, so it composes with the rest.
window(a, b) = _ -> compose(periods[a:b])
println("\nfirst window: ", window(1, 4)(nothing))
