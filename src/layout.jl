# Model layout: the per-model metadata that every Dataset over that model shares.

"""
    slot(v) -> Int

The storage slot of a variable. JuMP issues `MOI.VariableIndex` values sequentially from 1, so the
index doubles as a dense array position and no separate id map is needed.

!!! warning
    Deleting a variable leaves its slot permanently unused — MOI never reuses an index — so after a
    deletion the highest slot exceeds `num_variables(model)`. Size storage by the highest slot, never
    by `num_variables`.
"""
slot(v::JuMP.AbstractVariableRef) = JuMP.index(v).value

"""
    ModelLayout

Metadata shared by every [`Dataset`](@ref) built over one JuMP model. One layout per model, held in
`model.ext` and reached with [`layout`](@ref); datasets hold a reference to it rather than a copy, so
model-level information is stored once however many scenarios exist.

`nslots` is a high-water mark of the highest slot seen, not a variable count. It only ever grows.
"""
mutable struct ModelLayout
    model::JuMP.AbstractModel
    nslots::Int
end

const _LAYOUT_KEY = :ModularSystems_layout

"""
    layout(model) -> ModelLayout

The model's layout, created and cached in `model.ext` on first use.
"""
function layout(model::JuMP.AbstractModel)
    return get!(model.ext, _LAYOUT_KEY) do
        ModelLayout(model, highest_slot(model))
    end::ModelLayout
end

"""
    highest_slot(model) -> Int

The highest slot issued by `model`, or 0 for a model with no variables. Walks every variable, so it
is `O(num_variables)`: call it when building a dataset, not on the access path.
"""
function highest_slot(model::JuMP.AbstractModel)
    n = 0
    for v in JuMP.all_variables(model)
        s = slot(v)
        s > n && (n = s)
    end
    return n
end

"""
    note_slot!(l::ModelLayout, s::Integer) -> Int

Record that slot `s` is in use and return the layout's high-water mark. Lets a dataset grow to fit a
variable declared after it was built, without rescanning the model.
"""
function note_slot!(l::ModelLayout, s::Integer)
    s > l.nslots && (l.nslots = s)
    return l.nslots
end
