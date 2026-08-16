-- browser_catalog_test.lua — GridItemCatalog (catálogo do GridDevBrowser):
-- build/filtro/paginação, a lógica pura do browser de itens (sem ISUI).

local H = require("harness")
H.setName("browser_catalog_test")

local GridItemCatalog = require("Algorithm/GridItemCatalog")

-- ── Stubs do ambiente PZ ─────────────────────────────────────────────────────
_G.instanceof = function() return false end

-- ── ScriptItem stub ──────────────────────────────────────────────────────────
local seq = 0
local function makeScriptItem(fullType, displayName, obsolete, hidden)
    seq = seq + 1
    return {
        getFullName = function() return fullType or ("Base.Script" .. seq) end,
        getDisplayName = function() return displayName end,
        getObsolete = function() return obsolete or false end,
        isHidden = function() return hidden or false end,
    }
end

-- ── Classificador stub (simula instanceItem + ItemCategory + ItemFootprint) ──
local categoryOf = {}
local sizeOf = {}
local function classify(fullType)
    return categoryOf[fullType], sizeOf[fullType] and sizeOf[fullType][1], sizeOf[fullType] and sizeOf[fullType][2]
end

-- ── Build: pula obsoleto/hidden, categoriza, ordena ─────────────────────────
do
    categoryOf["Base.Hammer"] = "MELEE"
    categoryOf["Base.Apple"] = "FOOD"
    categoryOf["Base.Gun"] = "RANGED"
    sizeOf["Base.Hammer"] = { 1, 2 }
    sizeOf["Base.Apple"] = { 1, 1 }
    sizeOf["Base.Gun"] = { 2, 2 }

    local items = {
        makeScriptItem("Base.Gun", "Pistola"),
        makeScriptItem("Base.Apple", "Maca"),
        makeScriptItem("Base.Hammer", "Martelo"),
        makeScriptItem("Base.Obsolete", "Obsoleto", true, false),
        makeScriptItem("Base.Hidden", "Oculto", false, true),
    }
    local entries = GridItemCatalog.build(items, classify)
    H.ok(#entries == 3, "build pula obsoleto/hidden -> 3 [" .. #entries .. "]")
    H.ok(entries[1].fullType == "Base.Apple", "build ordena por fullType (1o Apple) [" .. entries[1].fullType .. "]")
    H.ok(entries[3].category == "MELEE", "categoria do Hammer -> MELEE [" .. entries[3].category .. "]")
    H.ok(entries[2].w == 2 and entries[2].h == 2, "size do Gun -> 2x2 [" .. entries[2].w .. "x" .. entries[2].h .. "]")
end

-- ── Filtro por categoria ────────────────────────────────────────────────────
do
    local entries = {
        { fullType = "Base.Knife", displayName = "Faca", category = "MELEE" },
        { fullType = "Base.Carrot", displayName = "Cenoura", category = "FOOD" },
        { fullType = "Base.Hammer", displayName = "Martelo", category = "MELEE" },
    }
    local melee = GridItemCatalog.filter(entries, nil, "MELEE")
    H.ok(#melee == 2, "filtro por categoria MELEE -> 2 [" .. #melee .. "]")

    local none = GridItemCatalog.filter(entries, nil, "RANGED")
    H.ok(#none == 0, "filtro por categoria sem match -> 0 [" .. #none .. "]")

    local all = GridItemCatalog.filter(entries, nil, nil)
    H.ok(#all == 3, "filtro sem categoria -> todos [" .. #all .. "]")
end

-- ── Filtro por busca (case-insensitive, fullType + displayName) ─────────────
do
    local entries = {
        { fullType = "Base.HamsterPet", displayName = "Hamster" },
        { fullType = "Base.Hammer", displayName = "Martelo" },
        { fullType = "Base.Whiskey", displayName = "Jack Daniels" },
    }
    local h = GridItemCatalog.filter(entries, "ham", nil)
    H.ok(#h == 2, "busca 'ham' (fullType+display) -> 2 [" .. #h .. "]")

    local upper = GridItemCatalog.filter(entries, "JACK", nil)
    H.ok(#upper == 1 and upper[1].fullType == "Base.Whiskey", "busca case-insensitive 'JACK' -> Whiskey")

    local q = GridItemCatalog.filter(entries, "zzz", nil)
    H.ok(#q == 0, "busca sem match -> 0")
end

-- ── Paginação ───────────────────────────────────────────────────────────────
do
    local entries = {}
    for i = 1, 45 do
        entries[#entries + 1] = { fullType = "Base.Item" .. i }
    end
    local p1, pages1 = GridItemCatalog.paginate(entries, 1, 10)
    H.ok(#p1 == 10 and pages1 == 5, "paginacao: pagina 1/5 -> 10 itens [" .. pages1 .. "]")

    local p5, pages5 = GridItemCatalog.paginate(entries, 5, 10)
    H.ok(#p5 == 5 and pages5 == 5, "ultima pagina (5) -> 5 itens [" .. #p5 .. "]")

    local pOver, pagesOver = GridItemCatalog.paginate(entries, 99, 10)
    H.ok(#pOver == 5 and pagesOver == 5, "pagina acima do limite clampada -> 5 itens [" .. #pOver .. "]")

    local pUnder, pagesUnder = GridItemCatalog.paginate(entries, 0, 10)
    H.ok(#pUnder == 10 and pagesUnder == 5, "pagina 0 clampada -> 10 itens [" .. #pUnder .. "]")
end

-- ── Paginação com lista vazia (não divide por zero) ─────────────────────────
do
    local items, pages = GridItemCatalog.paginate({}, 1, 20)
    H.ok(#items == 0 and pages == 1, "lista vazia -> 0 itens, 1 pagina [" .. pages .. "]")
end

-- ── sortEntries ─────────────────────────────────────────────────────────────
do
    local entries = {
        { fullType = "Base.Zeta" },
        { fullType = "Base.Alpha" },
    }
    GridItemCatalog.sortEntries(entries)
    H.ok(entries[1].fullType == "Base.Alpha", "sortEntries ordena in-place [" .. entries[1].fullType .. "]")
end

-- ── categoryOrder cobre as categorias do ItemCategory ───────────────────────
do
    local ItemCategory = require("Algorithm/ItemCategory")
    local missing = false
    for cat in pairs(ItemCategory.colors) do
        local found = false
        for _, c in ipairs(GridItemCatalog.categoryOrder) do
            if c == cat then found = true break end
        end
        if not found then missing = true end
    end
    H.ok(not missing, "categoryOrder cobre todas as categorias com cor")
end

-- ── buildDerivedIndex / getDerived (evolved recipes: base -> resultados) ─────
do
    -- Simula os pares { base, result } do getEvolvedRecipes() (BaseItem/ResultItem).
    local pairs = {
        { base = "Base.Bowl", result = "Base.Salad" },
        { base = "Base.Bowl", result = "Base.FruitSalad" },
        { base = "Base.Bowl", result = "Base.Salad" },   -- duplicado: dedup
        { base = "Base.ClayBowl", result = "Base.SaladClay" },
        { base = "Base.Pot", result = "Base.PotOfSoup" },
    }
    local index = GridItemCatalog.buildDerivedIndex(pairs)

    local bowl = GridItemCatalog.getDerived(index, "Base.Bowl")
    H.ok(#bowl == 2, "Bowl -> 2 derivados (dedup) [" .. #bowl .. "]")
    H.ok(bowl[1] == "Base.FruitSalad" and bowl[2] == "Base.Salad",
        "derivados ordenados [" .. table.concat(bowl, ",") .. "]")

    local clay = GridItemCatalog.getDerived(index, "Base.ClayBowl")
    H.ok(#clay == 1 and clay[1] == "Base.SaladClay", "ClayBowl -> SaladClay [" .. (clay[1] or "nil") .. "]")

    local pot = GridItemCatalog.getDerived(index, "Base.Pot")
    H.ok(#pot == 1 and pot[1] == "Base.PotOfSoup", "Pot -> PotOfSoup [" .. (pot[1] or "nil") .. "]")

    local none = GridItemCatalog.getDerived(index, "Base.Hammer")
    H.ok(#none == 0, "item sem derivados -> 0 [" .. #none .. "]")

    local noIndex = GridItemCatalog.getDerived(nil, "Base.Bowl")
    H.ok(#noIndex == 0, "index nil -> 0 [" .. #noIndex .. "]")

    local empty = GridItemCatalog.buildDerivedIndex(nil)
    H.ok(type(empty) == "table" and next(empty) == nil, "pairs nil -> index vazio")
end

H.finish()
