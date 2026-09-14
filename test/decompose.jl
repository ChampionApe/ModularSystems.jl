@testset "decompose.jl" begin

    # A chain x -> y -> z, written deliberately out of dependency order so the test says something
    # about the ordering rather than about the source.
    function chain_block()
        m = Model()
        @variable(m, a)
        @variable(m, x)
        @variable(m, y)
        @variable(m, z)
        b = @block m begin
            @square
            z, z == y + x
            x, x == a
            y, y == x + 1
        end
        return m, b, (a = a, x = x, y = y, z = z)
    end

    names_of(s::SubSystem) = [JuMP.name(v) for v in s.variables]

    @testset "a chain decomposes to scalar subsystems in dependency order" begin
        _, b, _ = chain_block()
        d = decompose(b)
        @test iswelldetermined(d)
        @test length(subsystems(d)) == 3
        @test largest_subsystem(d) == 1
        @test [only(names_of(s)) for s in subsystems(d)] == ["x", "y", "z"]
    end

    @testset "solve order holds for a long chain, whatever order it was written in" begin
        # Pins the property this rests on: Tarjan emits a component only once everything it can
        # reach has been emitted, so `strongly_connected_components` is already in dependency order.
        # That belongs to Graphs.jl rather than to us, which is exactly why it is asserted here.
        n = 40
        m = Model()
        @variable(m, s0)
        @variable(m, v[1:n])
        b = Block(m)
        for i in n:-1:1                      # written backwards
            prev = i == 1 ? s0 : v[i - 1]
            add_constraint!(b, @build_constraint(v[i] == prev + 1), determines = v[i])
        end
        d = decompose(b)
        @test iswelldetermined(d)
        @test largest_subsystem(d) == 1
        @test [only(names_of(s)) for s in subsystems(d)] == ["v[$i]" for i in 1:n]
    end

    @testset "a simultaneous pair stays one subsystem" begin
        m = Model()
        @variable(m, c)
        @variable(m, p)
        @variable(m, q)
        @variable(m, r)
        b = @block m begin
            @square
            p, p == q + c
            q, q == 2 * p - 1
            r, r == p + q
        end
        d = decompose(b)
        @test iswelldetermined(d)
        @test length(subsystems(d)) == 2
        @test largest_subsystem(d) == 2
        @test sort(names_of(subsystems(d)[1])) == ["p", "q"]
        @test names_of(subsystems(d)[2]) == ["r"]
    end

    @testset "an irreducible block decomposes to itself and gains nothing" begin
        m = Model()
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @square
            x, x + y == 3
            y, x - y == 1
        end
        d = decompose(b)
        @test length(subsystems(d)) == 1
        @test largest_subsystem(d) == 2
    end

    @testset "underdetermined variables are named" begin
        m = Model()
        @variable(m, x)
        @variable(m, y)
        @variable(m, z)
        b = Block(m)
        add_constraint!(b, @build_constraint(x + y == 1))
        add_constraint!(b, @build_constraint(x - y == 0))
        set_unknowns!(b, x, y, z)
        d = decompose(b)
        @test !iswelldetermined(d)
        @test isempty(overdetermined(d))
        @test names_of(underdetermined(d)) == ["z"]
    end

    @testset "overdetermined equations are named" begin
        m = Model()
        @variable(m, p)
        @variable(m, q)
        b = Block(m)
        add_constraint!(b, @build_constraint(p + q == 1))
        add_constraint!(b, @build_constraint(p - q == 0))
        add_constraint!(b, @build_constraint(p + 2 * q == 3))
        set_unknowns!(b, p, q)
        d = decompose(b)
        @test !iswelldetermined(d)
        @test overdetermined(d).constraints == [1, 2, 3]
        @test isempty(underdetermined(d))
    end

    @testset "it catches what degrees of freedom cannot" begin
        # Two equations determine u and nothing determines v: the counts balance, so
        # degrees_of_freedom is zero and issquare's pairing check is the only other defence —
        # and a block built without pairings has nothing for it to check.
        m = Model()
        @variable(m, k)
        @variable(m, u)
        @variable(m, v)
        @variable(m, w)
        b = Block(m)
        add_constraint!(b, @build_constraint(u == k))
        add_constraint!(b, @build_constraint(2 * u == 2 * k))
        add_constraint!(b, @build_constraint(w == u + 1))
        set_unknowns!(b, u, v, w)

        @test degrees_of_freedom(b) == 0          # says nothing is wrong
        d = decompose(b)
        @test !iswelldetermined(d)                # but something is
        @test overdetermined(d).constraints == [1, 2]
        @test names_of(underdetermined(d)) == ["v"]
    end

    @testset "only solved equalities take part" begin
        m = Model()
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            x, x == 1
            y, y == x + 1
            0 <= x                          # an inequality determines nothing
            @check y >= 0  "y is positive"  # a check is evaluated, not solved
        end
        set_unknowns!(b, x, y)
        d = decompose(b)
        @test iswelldetermined(d)
        @test length(subsystems(d)) == 2
        # The inequality and the check are not among the constraint indices reported.
        @test sort(vcat((s.constraints for s in subsystems(d))...)) == [1, 2]
    end

    @testset "exogenous variables create no dependency" begin
        # `a` is not an unknown, so it is a number by solve time and must not chain anything.
        m = Model()
        @variable(m, a)
        @variable(m, x)
        @variable(m, y)
        b = @block m begin
            @square
            x, x == a
            y, y == a * 2
        end
        d = decompose(b)
        @test length(subsystems(d)) == 2
        @test largest_subsystem(d) == 1
    end

    @testset "a pairing the equation does not contain is not trusted" begin
        # `x, y == 3` claims to determine x, but x does not appear. The matching must find the real
        # assignment rather than take the claim at face value and report a well-determined system.
        m = Model()
        @variable(m, x)
        @variable(m, y)
        b = Block(m)
        add_constraint!(b, @build_constraint(y == 3), determines = x)
        set_unknowns!(b, x, y)
        d = decompose(b)
        @test !iswelldetermined(d)
        @test names_of(underdetermined(d)) == ["x"]
    end

    @testset "a block with an objective cannot be decomposed" begin
        m = Model()
        @variable(m, x)
        b = @block m begin
            @unknowns x
            @objective Min (x - 2)^2
            x >= 0
        end
        e = try
            decompose(b)
        catch err
            err
        end
        @test e isa ArgumentError
        @test occursin("objective", e.msg)
    end

    @testset "a maximum matching is found when the pairings give none" begin
        # A block with no pairings at all: the matching has to be computed from scratch, and the
        # epoch-stamped search has to find the same perfect matching a seeded one would.
        n = 60
        m = Model()
        @variable(m, s0)
        @variable(m, v[1:n])
        b = Block(m)
        for i in 1:n
            prev = i == 1 ? s0 : v[i - 1]
            add_constraint!(b, @build_constraint(v[i] == prev + 1))   # unpaired
        end
        set_unknowns!(b, v)
        d = decompose(b)
        @test iswelldetermined(d)
        @test length(subsystems(d)) == n
        @test largest_subsystem(d) == 1
        @test [only(names_of(s)) for s in subsystems(d)] == ["v[$i]" for i in 1:n]
    end

    @testset "the epoch stamp is not confused between searches" begin
        # `seen` is reused across augmenting searches and distinguished by an epoch counter rather
        # than being cleared. If the stamp leaked between searches, a later one would treat columns
        # as already visited and the matching would come out short.
        n = 30
        m = Model()
        @variable(m, x[1:n])
        @variable(m, c)
        b = Block(m)
        # Every equation touches two unknowns, so the search genuinely has to explore and backtrack.
        for i in 1:n
            j = i == n ? 1 : i + 1
            add_constraint!(b, @build_constraint(x[i] + 2 * x[j] == c))
        end
        set_unknowns!(b, x)
        d = decompose(b)
        @test iswelldetermined(d)
        @test sum(length(s) for s in subsystems(d)) == n
    end

    @testset "the result is deterministic" begin
        # The expression walkers hand back a Set, whose iteration order is not stable across
        # constructions. Anything built from one has to be sorted before it is used.
        _, b, _ = chain_block()
        first = [names_of(s) for s in subsystems(decompose(b))]
        for _ in 1:5
            @test [names_of(s) for s in subsystems(decompose(b))] == first
        end
    end

    @testset "show says the shape" begin
        _, b, _ = chain_block()
        @test sprint(show, decompose(b)) == "Decomposition(3 subsystems, largest 1)"
        s = sprint(show, subsystems(decompose(b))[1])
        @test occursin("1 equation,", s)
        @test occursin("x", s)
    end

end
