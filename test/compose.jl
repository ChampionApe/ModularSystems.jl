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

    # -----------------------------------------------------------------------------------------
    # compose: the n-ary form
    # -----------------------------------------------------------------------------------------

    function period_blocks(m, T)
        @variable(m, K[1:T])
        @variable(m, Y[1:T])
        @variable(m, A[1:T])
        @variable(m, K0)
        blocks = Block[]
        for t in 1:T
            b = Block(m)
            prev = t == 1 ? K0 : K[t - 1]
            add_constraint!(b, @build_constraint(K[t] == 0.9 * prev + A[t]), determines = K[t])
            add_constraint!(b, @build_constraint(Y[t] == 2 * K[t]), determines = Y[t])
            push!(blocks, b)
        end
        return blocks, (K = K, Y = Y, A = A, K0 = K0)
    end

    @testset "compose agrees with folding + " begin
        m = Model()
        blocks, _ = period_blocks(m, 6)
        folded = reduce(+, blocks)
        composed = compose(blocks)
        @test length(composed) == length(folded)
        @test [c.determines for c in composed.constraints] ==
              [c.determines for c in folded.constraints]
        @test Set(collect(unknowns(composed))) == Set(collect(unknowns(folded)))
        @test Set(collect(pairings(composed))) == Set(collect(pairings(folded)))
        @test composed.paired == folded.paired
    end

    @testset "sum over a vector and a tuple routes through compose" begin
        m = Model()
        blocks, _ = period_blocks(m, 4)
        @test length(sum(blocks)) == length(compose(blocks))
        @test length(sum((blocks[1], blocks[2], blocks[3]))) == 6
    end

    @testset "compose keeps the rules + has" begin
        m = Model()
        blocks, v = period_blocks(m, 3)

        # never square, whatever the parts claimed
        for b in blocks
            b.assert_square = true
        end
        @test !compose(blocks).assert_square

        # a variable determined twice is an error
        dup = Block(m)
        add_constraint!(dup, @build_constraint(v.Y[1] == 5), determines = v.Y[1])
        e = try
            compose([blocks[1], dup])
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("determined in more than one", e.msg)

        # at most one objective across the whole collection
        o1 = Block(m)
        set_objective!(o1, MOI.MIN_SENSE, v.K[1])
        set_unknowns!(o1, v.K[1])
        o2 = Block(m)
        set_objective!(o2, MOI.MIN_SENSE, v.K[2])
        set_unknowns!(o2, v.K[2])
        @test_throws ArgumentError compose([o1, o2])
        @test compose([blocks[1], o1]).objective !== nothing
    end

    @testset "compose checks the model and refuses an empty collection" begin
        m = Model()
        blocks, _ = period_blocks(m, 2)
        other = Model()
        @variable(other, z)
        stray = Block(other)
        add_constraint!(stray, @build_constraint(z == 1), determines = z)
        @test_throws ArgumentError compose([blocks[1], stray])
        @test_throws ArgumentError compose(Block[])
    end

    @testset "the unknowns rule survives the n-ary form" begin
        m = Model()
        blocks, v = period_blocks(m, 3)
        # none declares, so the result declares none either and stays derivable
        @test compose(blocks).declared_unknowns === nothing

        # once any part declares, the result declares the union
        set_unknowns!(blocks[2], v.K[2], v.Y[2], v.A[2])
        composed = compose(blocks)
        @test composed.declared_unknowns !== nothing
        @test v.A[2] in unknowns(composed)          # carried from the declaration
        @test v.K[1] in unknowns(composed)          # derived from the others' pairings
    end

    @testset "composing many blocks is linear, not quadratic" begin
        # The reason compose exists. Folding + copies both constraint vectors every time, so n
        # blocks cost O(n^2); at n = 2000 that was 0.32 s against about a millisecond here. The
        # assertion is deliberately loose -- it is guarding against a return to quadratic, not
        # pinning a timing.
        m = Model()
        blocks, _ = period_blocks(m, 2000)
        compose(blocks[1:10])                       # warm
        small = @elapsed compose(blocks[1:250])
        large = @elapsed compose(blocks)
        @test length(compose(blocks)) == 4000
        # 8x the blocks must not cost 30x the time; quadratic would be 64x.
        @test large < 30 * max(small, 1e-6)
    end
end
