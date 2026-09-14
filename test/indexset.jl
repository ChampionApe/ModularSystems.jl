@testset "indexset.jl" begin
    pairs() = IndexSet((:p, :i), [(:food, :agri), (:steel, :mfg), (:food, :mfg)])

    @testset "construction, order and membership" begin
        s = pairs()
        @test length(s) == 3
        @test (:food, :agri) in s
        @test !((:steel, :agri) in s)
        @test axisnames(s) == (:p, :i)
        @test collect(s)[1] == (:food, :agri)
    end

    @testset "duplicates dropped, wrong arity rejected" begin
        s = IndexSet((:a, :b), [(1, 2), (1, 2), (3, 4)])
        @test length(s) == 2
        @test_throws DimensionMismatch IndexSet((:a, :b), [(1, 2, 3)])
    end

    @testset "empty set" begin
        s = IndexSet((:a,), Tuple{Int}[])
        @test isempty(s)
        @test length(s) == 0
    end

    @testset "set operations keep the left operand's order" begin
        a = pairs()
        b = IndexSet((:p, :i), [(:food, :mfg), (:food, :agri)])
        @test collect(a ∩ b) == [(:food, :agri), (:food, :mfg)]
        @test collect(setdiff(a, b)) == [(:steel, :mfg)]
        @test length(a ∪ b) == 3
    end

    @testset "mismatched axes are rejected" begin
        a = pairs()
        b = IndexSet((:x, :y), [(1, 2)])
        @test_throws ArgumentError a ∩ b
    end

    @testset "select_axes projects and de-duplicates" begin
        s = pairs()
        prods = select_axes(s, :p)
        @test axisnames(prods) == (:p,)
        @test collect(prods) == [(:food,), (:steel,)]
        @test_throws ArgumentError select_axes(s, :nope)
    end

    @testset "group_by buckets coordinates" begin
        g = group_by(pairs(), :p)
        @test Set(keys(g)) == Set([(:food,), (:steel,)])
        @test collect(g[(:food,)]) == [(:food, :agri), (:food, :mfg)]
        @test length(g[(:steel,)]) == 1
    end

    @testset "an IndexSet works as a JuMP axis, with no scan" begin
        m = Model()
        s = pairs()
        T = 1:2
        @variable(m, use[s, T])
        @test num_variables(m) == length(s) * length(T)
        @test use[(:food, :agri), 1] isa VariableRef
        # dense over its own axes: every stored coordinate resolves, and nothing else is declared
        @test all(use[k, t] isa VariableRef for k in s, t in T)
    end

    @testset "equations iterate the pattern instead of guarding a product" begin
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        s = pairs()
        @variable(m, use[s])
        @variable(m, price[s])
        @variable(m, total)

        b = @block m begin
            @square
            use[k ∈ s], use[k] == 1.0
            total, total == sum(use[k] * price[k] for k in s)
        end
        d = Dataset(m)
        d[price] = [2.0, 3.0, 4.0]
        out = solve(b, d; replace_nothing = 1.0)
        @test out[total] ≈ 9.0
    end

    @testset "grouping replaces a sum over one sparse index" begin
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        s = pairs()
        by_product = group_by(s, :p)
        prods = select_axes(s, :p)
        @variable(m, use[s])
        @variable(m, byprod[prods])

        b = @block m begin
            @square
            use[k ∈ s], use[k] == 2.0
            byprod[q ∈ prods], byprod[q] == sum(use[k] for k in by_product[q])
        end
        out = solve(b, Dataset(m); replace_nothing = 1.0)
        @test out[byprod[(:food,)]] ≈ 4.0     # two coordinates
        @test out[byprod[(:steel,)]] ≈ 2.0    # one
    end
end
