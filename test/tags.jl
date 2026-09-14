@testset "tags.jl" begin
    # Not `const`: a @testset body is a local scope. In real code these are module-level constants,
    # so a typo is an UndefVarError rather than a silently empty group.
    GrowthAdjusted = Tag(:growth_adjusted)
    Nominal = Tag(:nominal)

    function testmodel()
        m = Model()
        @variable(m, qGDP[1:3])
        @variable(m, vGDP[1:3])
        @variable(m, p)
        return m, qGDP, vGDP, p
    end

    @testset "tagging is per cell, not per container" begin
        m, q, v, p = testmodel()
        tag!(m, GrowthAdjusted, q, v[1])
        @test has_tag(q[1], GrowthAdjusted)
        @test has_tag(v[1], GrowthAdjusted)
        @test !has_tag(v[2], GrowthAdjusted)
        @test !has_tag(p, GrowthAdjusted)
    end

    @testset "tagged returns a group, in model order" begin
        m, q, v, p = testmodel()
        tag!(m, GrowthAdjusted, q)
        g = tagged(m, GrowthAdjusted)
        @test g isa VariableGroup
        @test collect(g) == [q[1], q[2], q[3]]
        @test isempty(tagged(m, Nominal))
    end

    @testset "tags compose with groups" begin
        m, q, v, p = testmodel()
        tag!(m, GrowthAdjusted, q)
        tag!(m, Nominal, v, q[3])
        both = tagged(m, GrowthAdjusted) ∩ tagged(m, Nominal)
        @test collect(both) == [q[3]]
    end

    @testset "several tags on one variable" begin
        m, q, _, _ = testmodel()
        tag!(m, GrowthAdjusted, q[1])
        tag!(m, Nominal, q[1])
        @test tags(q[1]) == Set([GrowthAdjusted, Nominal])
    end

    @testset "untagging" begin
        m, q, _, _ = testmodel()
        tag!(m, GrowthAdjusted, q)
        untag!(m, GrowthAdjusted, q[2])
        @test collect(tagged(m, GrowthAdjusted)) == [q[1], q[3]]
        untag!(m, Nominal, q[1])            # never had it; harmless
        @test length(tagged(m, GrowthAdjusted)) == 2
    end

    @testset "an untagged variable has empty metadata" begin
        _, _, _, p = testmodel()
        @test isempty(tags(p))
        @test description(p) == ""
    end

    @testset "descriptions" begin
        m, q, _, p = testmodel()
        describe!(m, p, "Price level")
        describe!(m, q, "Real GDP")
        @test description(p) == "Price level"
        @test description(q[2]) == "Real GDP"
    end

    @testset "JuMP's own @variables macro is untouched" begin
        # The whole reason tags are attached by function: nothing shadows JuMP's macro, so every
        # declaration form keeps working.
        m = Model()
        JuMP.@variables(m, begin
            a >= 0
            b[1:2], (start = 3.0)
        end)
        @test lower_bound(a) == 0.0
        @test start_value(b[1]) == 3.0
        tag!(m, GrowthAdjusted, a, b)
        @test length(tagged(m, GrowthAdjusted)) == 3
    end

    @testset "tagged variables drive a solve" begin
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        @variable(m, x[1:2])
        @variable(m, n[1:2])
        tag!(m, GrowthAdjusted, x)
        b = @block m begin
            @unknowns tagged(m, GrowthAdjusted)
            [i ∈ 1:2], x[i] == n[i] * 2
        end
        d = Dataset(m)
        d[n] = [3.0, 4.0]
        out = solve(b, d; replace_nothing = 1.0)
        @test out[x] ≈ [6.0, 8.0]
    end
end
