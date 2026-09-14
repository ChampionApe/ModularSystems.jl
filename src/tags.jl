# Tags and descriptions: cross-cutting attributes on variables, attached after declaration.

"""
    Tag(name::Symbol)

A marker for categorising variables — "these are real quantities", "these are growth-adjusted".
Tags are attached with [`tag!`](@ref) and turned back into a [`VariableGroup`](@ref) with
[`tagged`](@ref).

Define them as constants so a typo is an `UndefVarError` rather than a silently empty group:

```julia
const GrowthAdjusted = Tag(:growth_adjusted)
```
"""
struct Tag
    name::Symbol
end

Base.show(io::IO, t::Tag) = print(io, "Tag(:", t.name, ")")

mutable struct VariableMetadata
    tags::Set{Tag}
    description::String
end

VariableMetadata() = VariableMetadata(Set{Tag}(), "")

const _METADATA_KEY = :ModularSystems_metadata

# Keyed on VariableRef, not on the container's symbol, so a tag applies to a *cell*. That is what
# lets `tagged` hand back a VariableGroup, whose elements are cells too; keying on the container
# would make the two abstractions disagree about what they contain.
_metadata(model::JuMP.AbstractModel) =
    get!(model.ext, _METADATA_KEY) do
        Dict{VariableRef,VariableMetadata}()
    end::Dict{VariableRef,VariableMetadata}

_metadata_for(v::VariableRef) = get(_metadata(JuMP.owner_model(v)), v, VariableMetadata())

"""
    tag!(model, tag::Tag, items...) -> Tag

Attach a tag to every variable cell in `items`, which are flattened exactly as for
[`VariableGroup`](@ref) — variables, containers, groups, or any iterable of those.

Attaching after declaration rather than at it is deliberate: it needs no macro, so `JuMP.@variables`
is never shadowed and every JuMP declaration form keeps working.
"""
function tag!(model::JuMP.AbstractModel, tag::Tag, items...)
    store = _metadata(model)
    for v in VariableGroup(model, items...)
        get!(store, v, VariableMetadata()).tags |> s -> push!(s, tag)
    end
    return tag
end

"""
    untag!(model, tag::Tag, items...) -> Tag

Remove a tag from every variable cell in `items`. Variables that do not carry it are left alone.
"""
function untag!(model::JuMP.AbstractModel, tag::Tag, items...)
    store = _metadata(model)
    for v in VariableGroup(model, items...)
        haskey(store, v) && delete!(store[v].tags, tag)
    end
    return tag
end

"""
    tags(v::VariableRef) -> Set{Tag}

Every tag on a variable cell, empty if it has none.
"""
tags(v::VariableRef) = _metadata_for(v).tags

"""
    has_tag(v::VariableRef, tag::Tag) -> Bool
"""
has_tag(v::VariableRef, tag::Tag) = tag in _metadata_for(v).tags

"""
    tagged(model, tag::Tag) -> VariableGroup

Every variable carrying a tag, in the model's own variable order so the result is deterministic.

Walks the model's variables rather than keeping a second index by tag: tagging happens while a model
is being written, never in a solve, and one source of truth cannot fall out of step with itself.
"""
function tagged(model::JuMP.AbstractModel, tag::Tag)
    store = _metadata(model)
    return VariableGroup(model, VariableRef[
        v for v in JuMP.all_variables(model) if haskey(store, v) && tag in store[v].tags
    ])
end

"""
    describe!(model, v, text) -> String

Give a variable cell a human-readable description, for table and plot labels. Same store as tags, and
likewise attached after declaration.
"""
function describe!(model::JuMP.AbstractModel, v::VariableRef, text::AbstractString)
    JuMP.owner_model(v) === model || throw(ArgumentError(
        "$(JuMP.name(v)) belongs to a different model"))
    get!(_metadata(model), v, VariableMetadata()).description = String(text)
    return String(text)
end

function describe!(model::JuMP.AbstractModel, items, text::AbstractString)
    for v in VariableGroup(model, items)
        describe!(model, v, text)
    end
    return String(text)
end

"""
    description(v::VariableRef) -> String

A variable's description, or `""` if it has none.
"""
description(v::VariableRef) = _metadata_for(v).description
