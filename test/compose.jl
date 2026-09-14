@testset "composition" begin
    function testmodel()
        m = Model()
        set_optimizer_factory!(m, optimizer_with_attributes(Ipopt.Optimizer, "sb" => "yes"))
        return m
    end

    @testset "constraints concatenate and pairings carry over" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        @variable(m, a)

        first = @block m begin
            x, x == 2
        end
        second = @block m begin
            y, y == a + x
        end

        both = first + second
        @test length(both) == 2
        @test collect(unknowns(both)) == [x, y]
        @test issquare(both)
    end

    @testset "a composed block is never marked square, whatever its parts claimed" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        a = @block m begin
            @square
            x, x == 1
        end
        b = @block m begin
            @square
            y, y == 2
        end
        both = a + b
        @test both.assert_square == false        # the claim is not inherited
        @test issquare(both)                     # it happens to be square
        @test assert_square!(both) === both      # re-asserting checks and passes
        @test both.assert_square == true
    end

    @testset "re-asserting catches a sum that is not square" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        square_part = @block m begin
            @square
            x, x == 1
        end
        loose_part = @block m begin
            @unknowns y
            y >= 0
        end
        both = square_part + loose_part
        @test !issquare(both)
        @test_throws ArgumentError assert_square!(both)
    end

    @testset "a variable determined twice is an error" begin
        m = testmodel()
        @variable(m, x)
        a = @block m begin
            x, x == 1
        end
        b = @block m begin
            x, x == 2
        end
        err = try; a + b; catch e; e; end
        @test err isa ArgumentError
        @test occursin("determined only once", err.msg)
        @test occursin("x", err.msg)
    end

    @testset "two objectives are an error, one carries over" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        structural = @block m begin
            x, x == 2
        end
        estimation = @block m begin
            @unknowns x, y
            y >= 0
            @objective Min y
        end

        combined = structural + estimation
        @test combined.objective !== nothing
        @test combined.objective[1] == MOI.MIN_SENSE

        second = @block m begin
            @unknowns y
            @objective Max y
        end
        err = try; combined + second; catch e; e; end
        @test err isa ArgumentError
        @test occursin("at most one", err.msg)
    end

    @testset "unknowns union; a fully paired sum keeps deriving them" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        @variable(m, z)

        derived = (@block m begin
            x, x == 1
        end) + (@block m begin
            y, y == 2
        end)
        @test derived.declared_unknowns === nothing      # still derivable
        @test collect(unknowns(derived)) == [x, y]

        declared = (@block m begin
            @unknowns z
            z >= 0
        end) + (@block m begin
            x, x == 1
        end)
        @test declared.declared_unknowns !== nothing
        @test Set(collect(unknowns(declared))) == Set([z, x])
    end

    @testset "composing across models is rejected" begin
        m = testmodel()
        @variable(m, x)
        other = testmodel()
        @variable(other, w)
        a = @block m begin
            x, x == 1
        end
        b = @block other begin
            w, w == 1
        end
        @test_throws ArgumentError a + b
    end

    @testset "the parts are untouched by composing them" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        a = @block m begin
            x, x == 1
        end
        b = @block m begin
            y, y == 2
        end
        both = a + b
        @test length(a) == 1 && length(b) == 1
        add_constraint!(both, @build_constraint(x + y >= 0))
        @test length(a) == 1 && length(both) == 3
    end

    @testset "sum over several blocks" begin
        m = testmodel()
        @variable(m, v[1:4])
        parts = map(1:4) do i
            @block m begin
                v[i], v[i] == i          # a fixed index, not a loop
            end
        end
        whole = sum(parts)
        @test length(whole) == 4
        @test length(unknowns(whole)) == 4
    end

    @testset "a model assembled from modules solves" begin
        # The point of composition: each module owns its equations, and the system is their sum.
        m = testmodel()
        J = 1:2
        @variable(m, L[J])
        @variable(m, w[J])
        @variable(m, N[J])
        @variable(m, rho[J])

        labour() = @block m begin
            L[j ∈ J], L[j] == rho[j] * N[j]
        end
        wages() = @block m begin
            w[j ∈ J], w[j] == L[j] / 100
        end

        whole = assert_square!(labour() + wages())
        d = Dataset(m)
        d[N] = [3200.0, 500.0]
        d[rho] = [1.0, 2.0]
        out = solve(whole, d; replace_nothing = 1.0)
        @test out[L] ≈ [3200.0, 1000.0]
        @test out[w] ≈ [32.0, 10.0]
    end

    @testset "checks survive composition" begin
        m = testmodel()
        @variable(m, x)
        @variable(m, y)
        a = @block m begin
            x, x == 2
            @check x >= 0  "x nonnegative"
        end
        b = @block m begin
            y, y == 3
        end
        both = a + b
        @test length(checked_constraints(both)) == 1
        @test length(solved_constraints(both)) == 2
        out = solve(both, Dataset(m); replace_nothing = 1.0)
        @test out[x] ≈ 2.0 && out[y] ≈ 3.0
    end
end
