# Evidence for the C10 decision (docs/src/design.md: "Sparsity is handled by coordinate axes").
# Compares JuMP's filtered sparse declaration against declaring over a coordinate axis, for the same
# set of variables. Filtered declaration evaluates its predicate over the full product of the axes;
# the coordinate axis does not. Run: julia --project=. archive/sparseDeclarationBenchmark.jl
#
# Frozen 2026-09-14. Timings in design.md were taken on Julia 1.10.5, JuMP 1.31.2, Windows.

using JuMP
println(rpad("I x J x T", 22), rpad("combinations", 14), rpad("nvars", 9), rpad("filtered", 12), "coord axis")
for n in (50, 100, 200, 400)
    I, J, T = 1:n, 1:n, 1:50
    pairset = Set((i, j) for i in I for j in max(1, i-1):min(n, i+1))
    pairs = sort(collect(pairset))
    f() = (m = Model(); @variable(m, x[i = I, j = J, t = T; (i, j) in pairset]); m)
    g() = (m = Model(); @variable(m, x[pairs, T]); m)
    f(); g()
    tf = @elapsed mf = f()
    tg = @elapsed mg = g()
    println(rpad("$n x $n x 50", 22), rpad(n*n*50, 14), rpad(num_variables(mf), 9),
            rpad(string(round(tf*1000, digits=1), " ms"), 12), round(tg*1000, digits=1), " ms")
end
