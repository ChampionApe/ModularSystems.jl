@testset "dataset.jl" begin
    # A model with a scalar, a vector and a sparse container, reused by most sets below.
    function testmodel()
        m = Model()
        @variable(m, x)
        @variable(m, y[1:3])
        return m, x, y
    end

    @testset "values" begin
        m, x, y = testmodel()
        d = Dataset(m)
        @test d[x] === nothing              # unset reads as nothing, not zero
        d[x] = 2.5
        @test d[x] == 2.5
        d[y] = 1.0                          # fill a container
        @test d[y] == [1.0, 1.0, 1.0]
        d[y] = [4.0, 5.0, 6.0]
        @test d[y] == [4.0, 5.0, 6.0]
        @test haskey(d, x)
        d[x] = nothing
        @test !haskey(d, x)
    end

    @testset "integer assignment converts to the dataset's type" begin
        m, x, _ = testmodel()
        d = Dataset(m)
        d[x] = 3
        @test d[x] === 3.0
    end

    @testset "container assignment checks length" begin
        m, _, y = testmodel()
        d = Dataset(m)
        @test_throws DimensionMismatch (d[y] = [1.0, 2.0])
    end

    @testset "a variable from another model is rejected" begin
        m, x, _ = testmodel()
        other = Model()
        @variable(other, z)
        d = Dataset(m)
        @test_throws ArgumentError d[z]
        @test_throws ArgumentError (d[z] = 1.0)
    end

    @testset "growth preserves existing values" begin
        # Regression: growing the value vector must fill only the new slots. Filling the whole
        # vector erases every value already stored, and nothing else in the suite would catch it.
        m, x, y = testmodel()
        d = Dataset(m)
        d[x] = 1.0
        d[y] = [2.0, 3.0, 4.0]
        @variable(m, late)                  # declared after the dataset was built
        d[late] = 9.0
        @test d[x] == 1.0
        @test d[y] == [2.0, 3.0, 4.0]
        @test d[late] == 9.0
    end

    @testset "a variable declared after the dataset reads as unset, not as an error" begin
        m, x, _ = testmodel()
        d = Dataset(m)
        @variable(m, late)
        @test d[late] === nothing
    end

    @testset "copy is independent and keeps every layer" begin
        m, x, _ = testmodel()
        d = Dataset(m)
        d[x] = 1.0
        set_bounds!(d, x; lower = 0.0, upper = 10.0)
        d.meta.objective_value = 42.0

        c = copy(d)
        @test c[x] == 1.0
        @test bounds(c, x) == (0.0, 10.0)
        @test c.meta.objective_value == 42.0

        c[x] = 7.0
        set_bounds!(c, x; lower = 5.0)
        c.meta.objective_value = 1.0
        @test d[x] == 1.0                   # original untouched
        @test bounds(d, x) == (0.0, 10.0)
        @test d.meta.objective_value == 42.0
    end

    @testset "bounds" begin
        m, x, y = testmodel()
        d = Dataset(m)
        @test bounds(d, x) == (nothing, nothing)

        set_bounds!(d, x; lower = 0.1, upper = 10.0)
        @test bounds(d, x) == (0.1, 10.0)

        set_bounds!(d, x; upper = 5.0)      # one side at a time
        @test bounds(d, x) == (0.1, 5.0)

        clear_bounds!(d, x)
        @test bounds(d, x) == (nothing, nothing)

        set_bounds!(d, y[1]; lower = 0.0)   # bounds are per cell, not per container
        @test bounds(d, y[1]) == (0.0, nothing)
        @test bounds(d, y[2]) == (nothing, nothing)
    end

    @testset "an empty bound interval is rejected at the point it is created" begin
        m, x, _ = testmodel()
        d = Dataset(m)
        @test_throws ArgumentError set_bounds!(d, x; lower = 5.0, upper = 1.0)
        set_bounds!(d, x; lower = 5.0)
        @test_throws ArgumentError set_bounds!(d, x; upper = 1.0)   # also when built up in steps
    end

    @testset "arithmetic" begin
        m, x, y = testmodel()
        baseline = Dataset(m)
        baseline[x] = 2.0
        baseline[y] = [1.0, 2.0, 4.0]

        scenario = copy(baseline)
        scenario[x] = 3.0
        scenario[y] = [2.0, 2.0, 2.0]

        multipliers = scenario ./ baseline .- 1
        @test multipliers[x] ≈ 0.5
        @test multipliers[y] ≈ [1.0, 0.0, -0.5]

        @test (baseline * 2)[x] == 4.0
        @test (2 * baseline)[x] == 4.0
        @test (baseline + baseline)[x] == 4.0
        @test (10 - baseline)[x] == 8.0
    end

    @testset "arithmetic drops bounds and metadata" begin
        m, x, _ = testmodel()
        a = Dataset(m)
        a[x] = 2.0
        set_bounds!(a, x; lower = 0.0)
        a.meta.objective_value = 3.0

        r = a ./ a
        @test r[x] == 1.0
        @test bounds(r, x) == (nothing, nothing)       # a ratio of scenarios is not a scenario
        @test r.meta.objective_value === nothing
    end

    @testset "a cell missing from either operand is missing from the result" begin
        m, x, y = testmodel()
        a = Dataset(m)
        b = Dataset(m)
        a[x] = 2.0
        b[x] = 4.0
        a[y[1]] = 1.0                       # b has no value for y[1]
        r = b ./ a
        @test r[x] == 2.0
        @test r[y[1]] === nothing
        @test r[y[2]] === nothing
    end

    @testset "arithmetic across models is rejected" begin
        m, x, _ = testmodel()
        other = Model()
        @variable(other, z)
        @test_throws ArgumentError Dataset(m) ./ Dataset(other)
    end

    @testset "show reports what is filled in" begin
        m, x, _ = testmodel()
        d = Dataset(m)
        d[x] = 1.0
        set_bounds!(d, x; lower = 0.0)
        s = sprint(show, d)
        @test occursin("Dataset{Float64}", s)
        @test occursin("1/4 values", s)
        @test occursin("1 bounded", s)
    end
end
