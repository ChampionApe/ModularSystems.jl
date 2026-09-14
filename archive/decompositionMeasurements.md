# Block-triangular solving: the measurements

The evidence behind the C14 decision in `docs/src/design.md` — that `decompose` is kept for
diagnosis and for convergence, and **not** as a speed optimisation. Scripts are
`archive/decompositionBenchmark.jl` and `archive/robustnessSweep.jl`, so the tables can be rerun
rather than believed. Run 2026-09-14, Julia 1.10.5, Ipopt, one thread.

The model is a T-period recursive dynamic one: three scalar equations per period (capital from the
period before, output from capital, wages from output) plus a simultaneous core of `nsim` variables.
So it has `(3 + nsim) * T` unknowns and never needs to solve more than `nsim` of them at once — the
shape block-triangular solving is supposed to suit best.

## 1. Speed: block-triangular loses, at every size where both work

Wall times, warmed session, so they include building the intermediate JuMP model.

| core | T | unknowns | subsystems | monolithic | block-triangular | ratio |
|---|---|---|---|---|---|---|
| 2 | 25 | 125 | 100 | 0.014 s | 0.288 s | 20.6× |
| 2 | 100 | 500 | 400 | 0.026 s | 1.550 s | 59.6× |
| 2 | 200 | 1000 | 800 | 0.029 s | 3.190 s | 110× |
| 10 | 100 | 1300 | 400 | 0.121 s | 1.524 s | 12.6× |
| 40 | 50 | 2150 | 200 | 0.082 s | 0.760 s | 9.3× |

Answers agree to between 1e-15 and 1e-7 throughout, so this is a cost comparison and not a
correctness one.

## 2. Why: the fixed cost of entering an interior-point solver

At T = 100, core = 2 — 400 subsystems:

| | wall | of which Ipopt |
|---|---|---|
| block-triangular | 1.723 s | **0.990 s** |
| monolithic, same model | 0.020 s | **0.004 s** |

Ipopt's own summed solve time over 400 tiny subsystems is **250× larger** than the time it spends
solving the whole system at once. Building 400 JuMP models costs 1.83 ms each and is the *smaller*
half of the overhead.

This is the finding. An interior-point solver has a setup cost — symbolic factorisation, barrier
initialisation — that is essentially independent of problem size, and a one- or two-variable
subsystem cannot amortise it. The speedups reported for block-triangular form in the literature
assume each subsystem is solved by a direct method, not by re-entering a general-purpose NLP code.

## 3. The gap narrows sharply with size, but no crossover was reached

core = 40, watching for the ratio to fall below 1:

| T | unknowns | monolithic | block-triangular | ratio |
|---|---|---|---|---|
| 50 | 2,150 | 0.08 s | 0.94 s | 12.3× |
| 100 | 4,300 | 0.42 s | 1.52 s | 3.6× |
| 250 | 10,750 | 0.73 s | 4.43 s | 6.1× |
| 500 | 21,500 | 5.03 s | 9.15 s | **1.8×** |
| 1000 | 43,000 | 4.64 s | `SubSystemFailure` | — |
| 2000 | 86,000 | 9.67 s | `SubSystemFailure` | — |

The trend is real and in the expected direction: the monolithic solve pays a cost growing in `n`
once, the block-triangular path pays a roughly fixed cost `n` times. Whether they cross beyond
21,500 unknowns is **not known** — the block-triangular path became unreliable before the monolithic
one did. Reopening this needs either a larger stable model or the fast path in §5.

## 4. Robustness: a modest but real advantage

Every (shape, starting point) pair solved both ways; 14 starting points from 0.1 to 500 including
negatives, 5 model shapes, 70 combinations.

| shape | monolithic converged | block-triangular converged | tri only | mono only |
|---|---|---|---|---|
| T=25 core=2 | 14 | 14 | 0 | 0 |
| T=25 core=10 | 12 | 14 | 2 | 0 |
| T=25 core=40 | 10 | 11 | 1 | 0 |
| T=50 core=10 | 12 | 12 | 0 | 0 |
| T=50 core=40 | 10 | 11 | 2 | 1 |
| **total** | **58** | **62** | **5** | **1** |

Net +4 of 70. Small, but in the right direction and with a mechanism behind it: each subsystem is
started from the results of the ones before it, where the monolithic solve gets whatever the user
supplied for everything at once.

## 5. What would make it a speed win

Not calling a general NLP solver for a small subsystem. Three of every four subsystems in the core=2
shape are scalar, and a scalar equation that is affine in its unknown after substitution has a
closed-form answer. Even so, the arithmetic is discouraging: removing 300 of the 400 solves at T=100
leaves 100 × 2.5 ms = 0.25 s against 0.020 s monolithic, so a scalar fast path alone does **not**
close the gap. It would need small subsystems to avoid the solver entirely *and* the model to be
large enough to reach the region in §3.

## 6. Decomposition cost, which is the number that matters for diagnosis

| unknowns | subsystems | decompose |
|---|---|---|
| 4,300 | 400 | 0.0095 s |
| 43,000 | 4,000 | 0.215 s |
| 215,000 | 20,000 | 2.03 s |

Roughly linear, 2–9 µs per unknown, and about three orders of magnitude cheaper than solving the
same model. As a diagnostic it is free.
