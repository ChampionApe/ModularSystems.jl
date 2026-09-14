# A named, checked combination of a block, the data it is solved against, and how to solve it.
#
# Without this there is nothing in the package that says which pairings of block and dataset are
# meaningful: `solve(block, data)` will accept any of them, and a model with four blocks and five
# scenarios has twenty possible calls of which perhaps five mean anything. A Problem is the five.

"""
    StructuralError

Raised when a block cannot be solved for structural reasons — before any data, any solver and any
numbers. Carries the [`Diagnosis`](@ref) that found it, so the caller can inspect exactly what was
wrong rather than parse a message.
"""
struct StructuralError <: Exception
    diagnosis::Diagnosis
end

function Base.showerror(io::IO, e::StructuralError)
    print(io, "StructuralError: this block cannot be solved as it stands.\n")
    show(io, e.diagnosis)
end

"""
    assert_solvable(b::Block) -> Block
    assert_solvable(b::Block, d::Dataset) -> Block

Raise [`StructuralError`](@ref) unless the block is structurally sound: no constraint left with
nothing to determine, no unknown left undetermined, no orphan, and no constraint that has become a
constant. With a dataset, also check every exogenous variable has a value.

This is the assertion form of [`diagnose`](@ref), which deliberately reports rather than raises.
Both exist because they are for different moments: `diagnose` is for reading while a model is being
built, `assert_solvable` for the point where a configuration is declared fit to solve.

It is a **structural** guarantee and not a numerical one. A block that passes can still be singular
at the point the solver reaches, or fail to converge.
"""
function assert_solvable(b::Block, d::Union{Nothing,Dataset} = nothing)
    x = diagnose(b, d)
    isclean(x) || throw(StructuralError(x))
    return b
end

"""
    Problem(block, data; start = nothing, options = SolveOptions())
    Problem(base::Problem; kwargs...)

A block, the dataset it is solved against, where it starts from and how it is solved — one named
configuration of a model, checked at construction.

The constructor runs [`assert_solvable`](@ref) on the block, so a `Problem` that exists is one whose
structure has been checked. The check is on the **block only**: a block is a value and cannot change
underneath the problem, whereas `data` is mutable by design — a scenario is a dataset that gets
edited — so a data-dependent guarantee made here would be stale by the time it mattered. Missing
data is caught at solve time instead, where it is still exact.

The second form derives a problem from an existing one, changing only the fields named, which is how
a shock is expressed as a baseline with something different about it:

```julia
shock = Problem(baseline; data = edited, start = baseline_solution)
```

# Fields
Read them directly — `p.block`, `p.data`, `p.start`, `p.options`. There are deliberately no exported
accessors: `data` and `options` are names a user is very likely to want for their own variables, and
an exported function makes that assignment an error rather than a shadow. See
`notes/crossCuttingFindings.md` #2.

`data` is shared, not copied. A scenario is usually a dataset something else has already written
into, and copying here would break that chain silently.

# Examples
```jldoctest
julia> using JuMP

julia> model = Model();

julia> @variable(model, x); @variable(model, a);

julia> b = @block model begin
           @square
           x, x == 2 * a
       end;

julia> data = Dataset(model); data[a] = 3.0;

julia> p = Problem(b, data)
Problem(1 constraint, 1 unknown, largest subsystem 1)
```
"""
struct Problem
    block::Block
    data::Dataset
    start::Union{Nothing,Dataset}
    options::SolveOptions
end

function Problem(block::Block, data::Dataset;
                 start::Union{Nothing,Dataset} = nothing,
                 options::SolveOptions = _DEFAULT_OPTIONS,
                 check::Bool = true)
    JuMP.owner_model(data) === block.model || throw(ArgumentError(
        "the dataset and the block belong to different models"))
    start === nothing || JuMP.owner_model(start) === block.model || throw(ArgumentError(
        "the starting values belong to a different model than the block"))
    check && assert_solvable(block)
    return Problem(block, data, start, options)
end

function Problem(base::Problem;
                 block::Block = base.block,
                 data::Dataset = base.data,
                 start::Union{Nothing,Dataset} = base.start,
                 options::SolveOptions = base.options,
                 check::Bool = true)
    return Problem(block, data; start = start, options = options, check = check)
end

"""
    solve(p::Problem; kwargs...) -> Dataset
    solve!(p::Problem; kwargs...) -> Dataset

Solve a problem, using its own dataset, starting values and options. `solve` returns a solved copy
and leaves the problem's dataset untouched; `solve!` writes into it.

Any keyword accepted by [`solve!`](@ref) overrides the problem's own options for this call.
"""
function solve(p::Problem; kwargs...)
    return solve(p.block, p.data; options = p.options, start_values = p.start, kwargs...)
end

function solve!(p::Problem; kwargs...)
    return solve!(p.block, p.data; options = p.options, start_values = p.start, kwargs...)
end

"""
    diagnose(p::Problem) -> Diagnosis

Diagnose a problem's block against its own data, which is the pairing that will actually be solved.
"""
diagnose(p::Problem) = diagnose(p.block, p.data)

function Base.show(io::IO, p::Problem)
    n = length(solved_constraints(p.block))
    print(io, "Problem(", n, " constraint", n == 1 ? "" : "s")
    if p.block.declared_unknowns !== nothing ||
       all(c -> !is_solved(c) || is_paired(c), p.block.constraints)
        u = length(unknowns(p.block))
        print(io, ", ", u, " unknown", u == 1 ? "" : "s")
    end
    if p.block.objective === nothing
        print(io, ", largest subsystem ", largest_subsystem(decompose(p.block)))
    else
        print(io, ", objective")
    end
    p.start === nothing || print(io, ", started")
    print(io, ")")
end
