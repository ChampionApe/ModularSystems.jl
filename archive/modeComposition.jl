# Can the product of orthogonal mode axes be expressed with plain function composition?
using ModularSystems, JuMP, Ipopt

const J = 1:2
const P = 1:4
const DELTA = 0.1
const ALPHA = 0.3

model = Model()
set_optimizer_factory!(model, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
@variable(model, Y[J, P] >= 1e-3); @variable(model, K[J, P] >= 1e-3)
@variable(model, L[J, P] >= 1e-3); @variable(model, I[J, P])
@variable(model, rho[J, P] >= 1e-3); @variable(model, w[P] >= 1e-3)
@variable(model, ecost[J, P]); @variable(model, E[J, P] >= 1e-3); @variable(model, pE[P] >= 1e-3)
@variable(model, Lbar[P]); @variable(model, Ebar[P]); @variable(model, K0[J])

core = @block model begin
    Y[j in J, t in P],  Y[j, t] == rho[j, t] * K[j, t]^ALPHA * L[j, t]^(1 - ALPHA)
    L[j in J, t in P],  L[j, t] == (1 - ALPHA) * Y[j, t] / w[t]
    w[t in P],          sum(L[j, t] for j in J) == Lbar[t]
    I[j in J, t in P],  I[j, t] == 0.2 * (Y[j, t] - ecost[j, t])
end
accumulation = @block model begin
    K[j in J, t in P],  K[j, t] == (t == 1 ? K0[j] : (1 - DELTA) * K[j, t-1] + I[j, t-1])
end
steady = @block model begin
    K[j in J, t in P],  I[j, t] == DELTA * K[j, t]
end
energy = @block model begin
    E[j in J, t in P],  E[j, t] == 0.1 * Y[j, t] / pE[t]^0.5
    pE[t in P],         sum(E[j, t] for j in J) == Ebar[t]
end
coupling = @block model begin
    ecost[j in J, t in P],  ecost[j, t] == pE[t] * E[j, t]
end

# --- the three axes, each a Block -> Block function -------------------------------------------
dynamic(b)  = b + accumulation
static(b)   = b + steady
linked(b)   = b + energy + coupling
unlinked(b) = b
baseline(b) = b
calibrate(b) = swap(b, @group(rho[j in J, t in P]) => @group(Y[j in J, t in P]))

observed = Dataset(model)
observed[Lbar] = [100.0 + 2.0t for t in P]
observed[Ebar] = [40.0 for _ in P]
observed[K0] = [150.0, 100.0]
for j in J, t in P
    observed[Y[j, t]] = (j == 1 ? 120.0 : 80.0) * (1 + 0.02 * (t - 1))
end
opts = SolveOptions(replace_nothing = 1.0)

# --- the product, in five lines ----------------------------------------------------------------
spec = ModelSpec(model)
for (tn, time_) in (:static => static, :dynamic => dynamic),
    (ln, link) in (:linked => linked, :unlinked => unlinked),
    (cn, closing) in (:baseline => baseline, :calibration => calibrate)
    register!(spec, Symbol(tn, :_, ln, :_, cn),
              Problem((closing ∘ link ∘ time_)(core), observed; options = opts);
              about = "$tn closure, $ln, $cn")
end
show(stdout, MIME("text/plain"), spec)
println("\n", length(modes(spec)), " modes from 6 ingredients and 5 lines")

# Does composition order matter, and does getting it wrong fail loudly?
println("\ncalibrating BEFORE the closure is added (wrong order):")
try
    (linked ∘ dynamic ∘ calibrate)(core)
    println("  built without complaint — that would be bad")
catch e
    println("  ", nameof(typeof(e)), ": ", first(split(sprint(showerror, e), '\n')))
end

# Do the two orders actually give the same block? They should, when the swapped equation is already
# present: `swap` only re-points one constraint, and `+` unions unknowns either way.
a = (calibrate ∘ linked ∘ dynamic)(core)
b = (linked ∘ dynamic ∘ calibrate)(core)
println("\nsame constraint count: ", length(a) == length(b))
println("same unknowns:        ", Set(collect(unknowns(a))) == Set(collect(unknowns(b))))
println("same pairings:        ", Set(collect(pairings(a))) == Set(collect(pairings(b))))

# And where they genuinely cannot commute — calibrating against an equation that has not been added
# yet — does it fail loudly?
calibrate_energy(bl) = swap(bl, @group(Ebar[t in P]) => @group(pE[t in P]))
println("\ncalibrating on an equation not yet in the block:")
try
    calibrate_energy(dynamic(core))     # the pE equation lives in `energy`, which is absent
    println("  built without complaint — that would be bad")
catch e
    println("  ", nameof(typeof(e)), ": ", first(split(sprint(showerror, e), '\n')))
end
println("\nand with `energy` present it is fine:")
println("  ", (calibrate_energy ∘ linked ∘ dynamic)(core))
