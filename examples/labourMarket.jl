# Calibrate a small labour-market model to observed data, then shock it.
#
# The point of the example is that calibration is not a separate mode: it is the same equations with a
# different set of unknowns. Run with:
#
#     julia --project=. examples/labourMarket.jl

using ModularSystems
using JuMP
using Ipopt

const J = 1:2   # labour types

model = Model()
set_optimizer_factory!(model, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))

@variable(model, L[J])      # labour demand
@variable(model, w[J])      # wage
@variable(model, Y)         # output
@variable(model, p)         # price
@variable(model, N[J])      # workforce            (exogenous)
@variable(model, rho[J])    # productivity         (calibrated)

# The behavioural block: each equation sits next to the variable it determines.
behavioural = @block model begin
    @square
    L[j in J], L[j] == rho[j] * N[j]
    w[j in J], w[j] == p * Y / sum(L[k] for k in J)
    Y,         Y == sum(L[k] for k in J)
    p,         p == 1
    @check sum(w[j] * L[j] for j in J) == p * Y  "factor payments exhaust output"
end

# Calibration: the same equation, solved for the parameter instead of the outcome. Only the unknown
# set differs — the pairing is documentation, so it does not have to be rewritten.
calibration = @block model begin
    @unknowns rho
    [j in J], L[j] == rho[j] * N[j]
end

observed = Dataset(model)
observed[N] = [3200.0, 500.0]
observed[L] = [3200.0, 1000.0]          # observed labour demand

calibrated = solve(calibration, observed; replace_nothing = 1.0)
println("calibrated productivity: ", calibrated[rho])

# Solving the behavioural block with those parameters must reproduce the observation.
baseline = solve(behavioural, calibrated; replace_nothing = 1.0)
println("baseline labour:         ", baseline[L])
println("baseline wages:          ", round.(baseline[w], digits = 4))

# A scenario is a copy with something changed.
scenario = copy(baseline)
scenario[N] = [2700.0, 1000.0]
scenario = solve(behavioural, scenario; replace_nothing = 1.0)

multipliers = scenario ./ baseline .- 1
println("labour multipliers:      ", round.(multipliers[L], digits = 4))
println("wage multipliers:        ", round.(multipliers[w], digits = 4))

# Wages do not move here: with p fixed as numeraire and Y == sum(L), the wage equation pins both
# types to the same value whatever the workforce does. The model is a mechanism demonstration, not
# an economic claim.
