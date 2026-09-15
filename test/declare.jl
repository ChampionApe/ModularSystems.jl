@testset "declare.jl" begin
    # Not `const`: a @testset body is a local scope. In real code these are module-level constants.
    Quantity = Tag(:quantity)
    Price = Tag(:price)

    @testset "descriptions attach to every cell of a row" begin
        m = Model()
        J = 1:2
        L, w, Y = @declare m begin
            L[j in J], "Labour demand"
            w[j in J], "Wage"
            Y,         "Output"
        end
        @test description(L[1]) == "Labour demand"
        @test description(L[2]) == "Labour demand"
        @test description(w[2]) == "Wage"
        @test description(Y) == "Output"
    end

    @testset "named rows bind their names, so nothing needs destructuring" begin
        # The manual declares without an assignment; the binding comes from `JuMP.@variable`.
        m = Model()
        J = 1:2
        @declare m begin
            K[j in J], "Capital"
            r >= 0,    "Rental rate"
        end
        @test K isa AbstractArray && length(K) == 2
        @test description(K[1]) == "Capital"
        @test lower_bound(r) == 0.0
    end

    @testset "the return value is JuMP's: a tuple in row order" begin
        m = Model()
        declared = @declare m begin
            a,      "First"
            b[1:3], "Second"
            c
        end
        @test declared isa Tuple
        @test length(declared) == 3
        @test declared[1] isa VariableRef
        @test length(declared[2]) == 3
        @test description(declared[3]) == ""
    end

    @testset "rows reach JuMP unchanged" begin
        # Bounds, keyword arguments and every container form still work, with or without a
        # description — the description is stripped and the rest is passed through verbatim.
        m = Model()
        T = 2020:2022
        x, y, z, anon = @declare m begin
            x >= 0,                       "Lower bound only"
            0 <= y <= 10
            z[t in T] >= 1, (start = 2.0), "Indexed with keywords"
            [1:2]
        end
        @test lower_bound(x) == 0.0
        @test lower_bound(y) == 0.0 && upper_bound(y) == 10.0
        @test lower_bound(z[2021]) == 1.0
        @test start_value(z[2020]) == 2.0
        @test description(z[2022]) == "Indexed with keywords"
        @test description(y) == ""
        @test length(anon) == 2
        @test num_variables(m) == 1 + 1 + 3 + 2
    end

    @testset "a block tag applies to everything the block declares" begin
        m = Model()
        J = 1:2
        L, Y, anon = @declare m::Quantity begin
            L[j in J], "Labour demand"
            Y,         "Output"
            [1:2]
        end
        @test has_tag(L[1], Quantity)
        @test has_tag(L[2], Quantity)
        @test has_tag(Y, Quantity)
        @test has_tag(anon[1], Quantity)     # anonymous rows are tagged too
        @test length(tagged(m, Quantity)) == 5
    end

    @testset "several block tags accumulate" begin
        m = Model()
        p, = @declare m::(Quantity, Price) begin
            p, "Price"
        end
        @test has_tag(p, Quantity)
        @test has_tag(p, Price)
        @test tags(p) == Set([Quantity, Price])
    end

    @testset "untagged declarations stay untagged" begin
        m = Model()
        a, = @declare m begin
            a, "No tag here"
        end
        @test isempty(tags(a))
        @test isempty(tagged(m, Quantity))
    end

    @testset "a Dataset is accepted as the target" begin
        m = Model()
        @variable(m, seed)
        data = Dataset(m)
        q, = @declare data::Quantity begin
            q, "Declared through a dataset"
        end
        @test owner_model(q) === m
        @test description(q) == "Declared through a dataset"
        @test has_tag(q, Quantity)
    end

    @testset "descriptions may be interpolated" begin
        m = Model()
        country = "DK"
        p, = @declare m begin
            p, "Price in $country"
        end
        @test description(p) == "Price in DK"
    end

    @testset "index sets resolve in the caller's scope" begin
        # Hygiene regression: the rows are handed to a macro that escapes its own arguments, so an
        # unescaped nested macrocall resolved `J` in ModularSystems rather than here.
        function inner()
            m = Model()
            J = 1:3
            x, = @declare m::Quantity begin
                x[j in J] >= 0, "Capital"
            end
            return m, x
        end
        m, x = inner()
        @test length(x) == 3
        @test description(x[3]) == "Capital"
        @test has_tag(x[1], Quantity)
        @test lower_bound(x[2]) == 0.0
    end

    @testset "declared variables drive a solve" begin
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        J = 1:2
        L, N, rho = @declare m::Quantity begin
            L[j in J], "Labour demand"
            N[j in J], "Labour force"
            rho[j in J], "Productivity"
        end
        b = @block m begin
            @unknowns L
            L[j in J], L[j] == rho[j] * N[j]
        end
        d = Dataset(m)
        d[N] = [10.0, 20.0]
        d[rho] = [1.5, 0.5]
        out = solve(b, d)
        @test out[L[1]] ≈ 15.0
        @test out[L[2]] ≈ 10.0
    end

    @testset "malformed blocks are rejected" begin
        m = Model()
        @test_throws Exception (@eval @declare $m (x, "not a block"))
        @test_throws Exception (@eval @declare $m begin
            "a description with no variable"
        end)
    end
end
