-- category_test.lua — ItemCategory: classificação semântica (estilo Tetris) e
-- paleta de cores do footprint. Verifica a ordem de precedência e que toda
-- categoria tem cor definida.

local H = require("harness")
H.setName("category_test")

-- ── Stubs do ambiente PZ ─────────────────────────────────────────────────────
_G.instanceof = function() return false end

local ItemCategory = require("Algorithm/ItemCategory")

-- Mock de item: define só os métodos que a classificação consulta.
-- fullType ÚNICO por mock (default auto-incrementado) — o getCategory cacheia
-- por fullType, então dois mocks com o mesmo fullType colidiriam no cache.
local mockSeq = 0
local function makeItem(overrides)
    mockSeq = mockSeq + 1
    local o = {
        getFullType = function() return "Base.Fallback" .. mockSeq end,
        getDisplayCategory = function() return nil end,
        getCategory = function() return nil end,
        IsInventoryContainer = function() return false end,
        IsWeapon = function() return false end,
        isRanged = function() return false end,
        getAmmoType = function() return nil end,
        getMaxAmmo = function() return 0 end,
        IsClothing = function() return false end,
        IsFood = function() return false end,
        isRecordedMedia = function() return false end,
    }
    if overrides then
        for k, v in pairs(overrides) do o[k] = v end
    end
    return o
end

ItemCategory.clearCache()

-- ─── Classificação: precedência ──────────────────────────────────────────────
H.ok(ItemCategory.getCategory(nil) == ItemCategory.MISC, "item nil -> MISC")

-- Moveable tem prioridade MÁXIMA (mesmo que seja container)
do
    local i = makeItem({ getFullType = function() return "Base.Sofa" end })
    _G.instanceof = function(_, cls) return cls == "Moveable" end
    H.ok(ItemCategory.getCategory(i) == ItemCategory.MOVEABLE, "Moveable -> MOVEABLE [" .. ItemCategory.getCategory(i) .. "]")
    _G.instanceof = function() return false end
end

-- CorpseAnimal
do
    local i = makeItem({ getFullType = function() return "Base.CorpseAnimal" end })
    H.ok(ItemCategory.getCategory(i) == ItemCategory.CORPSEANIMAL, "CorpseAnimal -> CORPSEANIMAL [" .. ItemCategory.getCategory(i) .. "]")
end

-- Container
do
    local i = makeItem({ IsInventoryContainer = function() return true end })
    H.ok(ItemCategory.getCategory(i) == ItemCategory.CONTAINER, "IsInventoryContainer -> CONTAINER [" .. ItemCategory.getCategory(i) .. "]")
end

-- Cura (FirstAid)
do
    local i = makeItem({ getDisplayCategory = function() return "FirstAid" end })
    H.ok(ItemCategory.getCategory(i) == ItemCategory.HEALING, "FirstAid -> HEALING [" .. ItemCategory.getCategory(i) .. "]")
end

-- Armas: melee vs ranged
do
    local melee = makeItem({ IsWeapon = function() return true end })
    H.ok(ItemCategory.getCategory(melee) == ItemCategory.MELEE, "weapon sem ammo/ranged -> MELEE [" .. ItemCategory.getCategory(melee) .. "]")

    local ranged = makeItem({ IsWeapon = function() return true end, getAmmoType = function() return "9x19" end })
    H.ok(ItemCategory.getCategory(ranged) == ItemCategory.RANGED, "weapon com getAmmoType -> RANGED [" .. ItemCategory.getCategory(ranged) .. "]")

    local ranged2 = makeItem({ IsWeapon = function() return true end, isRanged = function() return true end })
    H.ok(ItemCategory.getCategory(ranged2) == ItemCategory.RANGED, "weapon isRanged -> RANGED [" .. ItemCategory.getCategory(ranged2) .. "]")
end

-- Carregador (getMaxAmmo > 0)
do
    local i = makeItem({ getMaxAmmo = function() return 30 end })
    H.ok(ItemCategory.getCategory(i) == ItemCategory.MAGAZINE, "getMaxAmmo>0 -> MAGAZINE [" .. ItemCategory.getCategory(i) .. "]")
end

-- Peça de arma (WeaponPart)
do
    local i = makeItem({ getDisplayCategory = function() return "WeaponPart" end })
    H.ok(ItemCategory.getCategory(i) == ItemCategory.ATTACHMENT, "WeaponPart -> ATTACHMENT [" .. ItemCategory.getCategory(i) .. "]")
end

-- Munição (displayCategory "Ammo")
do
    local i = makeItem({ getDisplayCategory = function() return "Ammo" end })
    H.ok(ItemCategory.getCategory(i) == ItemCategory.AMMO, "Ammo -> AMMO [" .. ItemCategory.getCategory(i) .. "]")
end

-- Roupa
do
    local i = makeItem({ IsClothing = function() return true end })
    H.ok(ItemCategory.getCategory(i) == ItemCategory.CLOTHING, "IsClothing -> CLOTHING [" .. ItemCategory.getCategory(i) .. "]")
end

-- Comida e água
do
    local food = makeItem({ IsFood = function() return true end })
    H.ok(ItemCategory.getCategory(food) == ItemCategory.FOOD, "IsFood -> FOOD [" .. ItemCategory.getCategory(food) .. "]")

    local water = makeItem({ getDisplayCategory = function() return "WaterContainer" end })
    H.ok(ItemCategory.getCategory(water) == ItemCategory.FOOD, "WaterContainer -> FOOD [" .. ItemCategory.getCategory(water) .. "]")
end

-- Livro
do
    local i = makeItem({ getDisplayCategory = function() return "Literature" end })
    H.ok(ItemCategory.getCategory(i) == ItemCategory.BOOK, "Literature -> BOOK [" .. ItemCategory.getCategory(i) .. "]")
end

-- Mídia
do
    local i = makeItem({ isRecordedMedia = function() return true end })
    H.ok(ItemCategory.getCategory(i) == ItemCategory.ENTERTAINMENT, "isRecordedMedia -> ENTERTAINMENT [" .. ItemCategory.getCategory(i) .. "]")
end

-- Chave
do
    local i = makeItem({ getCategory = function() return "Key" end })
    H.ok(ItemCategory.getCategory(i) == ItemCategory.KEY, "getCategory=Key -> KEY [" .. ItemCategory.getCategory(i) .. "]")
end

-- Semente
do
    local i = makeItem({ getFullType = function() return "Base.TomatoSeed" end })
    H.ok(ItemCategory.getCategory(i) == ItemCategory.SEED, "fullType contém Seed -> SEED [" .. ItemCategory.getCategory(i) .. "]")
end

-- Fallback MISC
do
    local i = makeItem({ getFullType = function() return "Base.SomeRandom" end })
    H.ok(ItemCategory.getCategory(i) == ItemCategory.MISC, "sem match -> MISC [" .. ItemCategory.getCategory(i) .. "]")
end

-- ─── Cache ───────────────────────────────────────────────────────────────────
do
    local calls = 0
    local i = makeItem({
        getFullType = function() return "Base.CacheTest" end,
        getDisplayCategory = function() calls = calls + 1 return "FirstAid" end,
    })
    local c1 = ItemCategory.getCategory(i)
    local c2 = ItemCategory.getCategory(i)
    H.ok(c1 == ItemCategory.HEALING and c2 == ItemCategory.HEALING, "cache: mesma categoria nas 2 chamadas")
    H.ok(calls == 1, "cache: _classify rodou só 1x [calls=" .. calls .. "]")
    ItemCategory.clearCache()
end

-- ─── Cores ───────────────────────────────────────────────────────────────────
do
    local allCats = {}
    for k, v in pairs(ItemCategory.colors) do table.insert(allCats, k) end
    -- getColorByCategory nunca retorna nil (fallback MISC)
    local missing = {}
    for _, cat in ipairs(allCats) do
        local c = ItemCategory.getColorByCategory(cat)
        if not c or not c.r or not c.g or not c.b then
            table.insert(missing, cat)
        end
    end
    H.ok(#missing == 0, "toda categoria tem cor [faltando: " .. (#missing == 0 and "nenhuma" or table.concat(missing, ",")) .. "]")

    -- MISC = prata (base do degrade dos itens sem categoria rastreada)
    local misc = ItemCategory.getColorByCategory(ItemCategory.MISC)
    H.ok(misc.r == 0.72 and misc.g == 0.74 and misc.b == 0.78, "MISC é prata (0.72,0.74,0.78)")

    -- neutralColor (topo do degrade) é o cinza escuro fixo, independente do MISC
    H.ok(ItemCategory.neutralColor.r == 0.4 and ItemCategory.neutralColor.g == 0.4 and ItemCategory.neutralColor.b == 0.4,
        "neutralColor é cinza escuro fixo (0.4,0.4,0.4)")

    -- Categorias distintas têm cores distintas (sem colisão acidental)
    local seen = {}
    local collision = false
    for _, cat in ipairs(allCats) do
        local c = ItemCategory.getColorByCategory(cat)
        local key = string.format("%.3f_%.3f_%.3f", c.r, c.g, c.b)
        if seen[key] then collision = true end
        seen[key] = true
    end
    H.ok(not collision, "todas as categorias têm cores distintas")

    -- getColor (por item) retorna a cor da categoria
    local gun = makeItem({ IsWeapon = function() return true end, getAmmoType = function() return "12g" end })
    local gunColor = ItemCategory.getColor(gun)
    local rangedColor = ItemCategory.getColorByCategory(ItemCategory.RANGED)
    H.ok(gunColor == rangedColor and gunColor.r == rangedColor.r, "getColor(item) bate com getColorByCategory(RANGED)")
end

-- ─── Degrade vertical (NEUTRO no topo → CATEGORIA na base) ──────────────────
do
    local gun = makeItem({ IsWeapon = function() return true end, getAmmoType = function() return "12g" end })
    local rangedColor = ItemCategory.getColorByCategory(ItemCategory.RANGED)
    local neutral = ItemCategory.neutralColor
    local HGT = 100 -- altura de teste em pixels
    local bands = ItemCategory.getGradient(gun, HGT)

    -- nº de faixas variável (depende da altura) mas ≥ 1
    H.ok(#bands > 0, "degrade tem pelo menos 1 faixa [n=" .. #bands .. "]")

    -- Topo (1ª faixa) = NEUTRO (cinza escuro fixo)
    local top = bands[1]
    H.ok(math.abs(top.r - neutral.r) < 0.001
        and math.abs(top.g - neutral.g) < 0.001
        and math.abs(top.b - neutral.b) < 0.001,
        "TOPO do degrade = cor neutra (cinza escuro)")

    -- Base (última faixa) = CATEGORIA (RANGED azul)
    local bottom = bands[#bands]
    H.ok(math.abs(bottom.r - rangedColor.r) < 0.001
        and math.abs(bottom.g - rangedColor.g) < 0.001
        and math.abs(bottom.b - rangedColor.b) < 0.001,
        "BASE do degrade = cor da categoria")

    -- Faixas tileiam a altura inteira SEM gaps nem sobreposição (fix das
    -- linhas pretas): 1ª começa em y=0, cada faixa começa onde a anterior
    -- termina, e a última termina exatamente em HGT.
    H.ok(bands[1].y == 0, "primeira faixa começa em y=0 [y=" .. bands[1].y .. "]")
    local prevEnd = 0
    local continuous = true
    for _, band in ipairs(bands) do
        if band.y ~= prevEnd then continuous = false end
        prevEnd = band.y + band.h
    end
    H.ok(continuous, "faixas são contíguas (sem gap/sobreposição)")
    H.ok(prevEnd == HGT, "última faixa termina exatamente na altura [end=" .. prevEnd .. ", hgt=" .. HGT .. "]")

    -- Alturas são inteiras (sem pixel fracionário)
    local allInt = true
    for _, band in ipairs(bands) do
        if band.y % 1 ~= 0 or band.h % 1 ~= 0 then allInt = false end
    end
    H.ok(allInt, "todas as faixas têm y/h inteiros")

    -- Monotônico invertido: a base é mais distante do NEUTRO que o topo
    local distTop = math.abs(bands[1].r - neutral.r) + math.abs(bands[1].g - neutral.g) + math.abs(bands[1].b - neutral.b)
    local distBottom = math.abs(bands[#bands].r - neutral.r) + math.abs(bands[#bands].g - neutral.g) + math.abs(bands[#bands].b - neutral.b)
    H.ok(distBottom > distTop, "degrade desvanece do neutro (topo) pra categoria (base)")

    -- lerpColor: 0.5 está no meio entre from e to
    local r, g, b = ItemCategory.lerpColor({ r = 0, g = 0, b = 0 }, { r = 1, g = 1, b = 1 }, 0.5)
    H.ok(math.abs(r - 0.5) < 0.001 and math.abs(g - 0.5) < 0.001 and math.abs(b - 0.5) < 0.001,
        "lerpColor(0.5) = ponto médio")
end

-- ─── Degrade de item MISC (sem categoria rastreada) = cinza → prata ─────────
do
    local miscItem = makeItem({ getFullType = function() return "Base.UnknownJunk" end }) -- cai em MISC
    H.ok(ItemCategory.getCategory(miscItem) == ItemCategory.MISC, "junk sem match é MISC")
    local bands = ItemCategory.getGradient(miscItem, 100)
    local top = bands[1]
    local bottom = bands[#bands]
    local neutral = ItemCategory.neutralColor
    local prata = ItemCategory.getColorByCategory(ItemCategory.MISC)
    H.ok(math.abs(top.r - neutral.r) < 0.001 and math.abs(bottom.r - prata.r) < 0.001,
        "degrade MISC: cinza escuro no topo → prata na base")
end

H.finish()
