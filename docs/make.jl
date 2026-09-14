using Documenter
using Documenter: Remotes
using ModularSystems

# A jldoctest block runs in a bare sandbox module, not inside the package -- without this line every
# doctest fails with `UndefVarError: ... not defined in Main` however correct it is.
DocMeta.setdocmeta!(ModularSystems, :DocTestSetup, :(using ModularSystems); recursive = true)

# doctest = true means every ```jldoctest block in a docstring or manual page is executed and its
# output compared. That is the whole reason the examples in the manual are worth trusting: they
# cannot drift from the code without CI going red.
makedocs(;
    modules = [ModularSystems],
    authors = "Rasmus Kehlet Berg",
    sitename = "ModularSystems.jl",
    # Stated explicitly rather than sniffed from `git remote`, so the build works in a fresh clone,
    # a worktree, or before the GitHub repository exists.
    repo = Remotes.GitHub("ChampionApe", "ModularSystems.jl"),
    doctest = true,
    checkdocs = :exports,
    format = Documenter.HTML(;
        canonical = "https://ChampionApe.github.io/ModularSystems.jl",
        prettyurls = get(ENV, "CI", "false") == "true",
        edit_link = "main",
    ),
    pages = [
        "Home" => "index.md",
        "Design" => "design.md",
        "API" => "api.md",
    ],
)

deploydocs(; repo = "github.com/ChampionApe/ModularSystems.jl", devbranch = "main")
