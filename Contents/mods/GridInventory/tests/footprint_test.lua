-- footprint_test.lua — ItemFootprint.getSize.
-- Foco: LITERATURA nunca passa de 1x2 (antes caía em 2x2/2x3 no branch geral).

local H = require("harness")
H.setName("footprint_test")

-- ── Stubs do ambiente PZ ─────────────────────────────────────────────────────
_G.instanceof = function() return false end

local ItemFootprint = require("Algorithm/ItemFootprint")
ItemFootprint.clearCache()

-- Mock de item: fullType, peso e displayCategory/instanceof controláveis.
-- container = { cap = N } faz o item ser um InventoryContainer com capacidade N.
local makeSeq = 0
local function makeItem(weight, displayCat, litInstanceof, container, fullType)
    makeSeq = makeSeq + 1
    return {
        getFullType = function() return fullType or ("Base.Book" .. makeSeq) end,
        getWeight = function() return weight end,
        getDisplayCategory = function() return displayCat end,
        getMaxAmmo = function() return 0 end,
        canStack = function() return false end,
        getCount = function() return 1 end,
        isHidden = function() return false end,
        _isLit = litInstanceof,
        _isContainer = container ~= nil,
        _containerCap = container and container.cap,
        IsInventoryContainer = function(self)
            return self._isContainer
        end,
        getInventory = function(self)
            if not self._isContainer then return nil end
            return { getCapacity = function() return self._containerCap end }
        end,
    }
end

-- Sobrescreve instanceof pra responder Literature, InventoryContainer e Moveable.
local og_instanceof = _G.instanceof
_G.instanceof = function(item, cls)
    if cls == "Literature" and item and item._isLit then return true end
    if cls == "InventoryContainer" and item and item._isContainer then return true end
    if cls == "Moveable" and item and item._isMoveable then return true end
    return false
end

ItemFootprint.clearCache()-- ─── Literatura: no MÁXIMO 1x2 ──────────────────────────────────────────────
do
    -- Livro pesado (>= 1.0): 1x2, NUNCA 2x2
    local heavyLit = makeItem(2.5, "Literature")
    local w, h = ItemFootprint.getSize(heavyLit)
    H.ok(w == 1 and h == 2,
        "literatura pesada (2.5) -> 1x2, nunca 2x2 [(" .. w .. "x" .. h .. ")]")

    -- Livro médio: 1x2
    local midLit = makeItem(1.2, "Literature")
    w, h = ItemFootprint.getSize(midLit)
    H.ok(w == 1 and h == 2,
        "literatura média (1.2) -> 1x2 [(" .. w .. "x" .. h .. ")]")

    -- Livro leve: 1x2 (revista também ganha largura — grid viva)
    local lightLit = makeItem(0.4, "Literature")
    w, h = ItemFootprint.getSize(lightLit)
    H.ok(w == 1 and h == 2,
        "literatura leve (0.4) -> 1x2 [(" .. w .. "x" .. h .. ")]")
end

-- ─── Literatura via instanceof (sem displayCategory) ────────────────────────
do
    local litObj = makeItem(3.0, nil, true) -- instanceof Literature, sem displayCat
    local w, h = ItemFootprint.getSize(litObj)
    H.ok(w == 1 and h == 2,
        "instanceof Literature pesado (3.0) -> 1x2 [(" .. w .. "x" .. h .. ")]")
end

-- ─── SkillBook via displayCategory ──────────────────────────────────────────
do
    local skill = makeItem(1.5, "SkillBook")
    local w, h = ItemFootprint.getSize(skill)
    H.ok(w == 1 and h == 2,
        "SkillBook (1.5) -> 1x2 [(" .. w .. "x" .. h .. ")]")
end

-- ─── Regressão: item GERAL (categoria sem regra) continua no genérico ───────
do
    local gen = makeItem(2.5, "Generic") -- sem regra própria → genérico
    local w, h = ItemFootprint.getSize(gen)
    H.ok(w == 2 and h == 3,
        "item genérico pesado (2.5) continua 2x3 [(" .. w .. "x" .. h .. ")]")
end

-- ─── Regras finas por DisplayCategory ───────────────────────────────────────
-- Munição: bala solta 1x1, caixa 1x2
do
    local loose = makeItem(0.05, "Ammo")
    local w, h = ItemFootprint.getSize(loose)
    H.ok(w == 1 and h == 1, "munição solta (0.05) -> 1x1 [(" .. w .. "x" .. h .. ")]")

    local box = makeItem(2.0, "Ammo")
    w, h = ItemFootprint.getSize(box)
    H.ok(w == 1 and h == 2, "caixa de munição (2.0) -> 1x2 [(" .. w .. "x" .. h .. ")]")
end

-- Ferramenta: martelo 1x2, furadeira/marreta 2x3 (volumoso com espaço)
do
    local hammer = makeItem(1.2, "Tool")
    local w, h = ItemFootprint.getSize(hammer)
    H.ok(w == 1 and h == 2, "martelo (1.2) -> 1x2 [(" .. w .. "x" .. h .. ")]")

    local drill = makeItem(3.0, "Tool")
    w, h = ItemFootprint.getSize(drill)
    H.ok(w == 2 and h == 3, "furadeira (3.0) -> 2x3 [(" .. w .. "x" .. h .. ")]")
end

-- Material: tábua 2x2, madeira 2x3, viga 2x4, pillow (1.0) 2x2
do
    local plank = makeItem(1.5, "Material")
    local w, h = ItemFootprint.getSize(plank)
    H.ok(w == 2 and h == 2, "tábua (1.5) -> 2x2 [(" .. w .. "x" .. h .. ")]")

    local log = makeItem(4.0, "Material")
    w, h = ItemFootprint.getSize(log)
    H.ok(w == 2 and h == 3, "madeira (4.0) -> 2x3 [(" .. w .. "x" .. h .. ")]")

    local beam = makeItem(8.0, "Material")
    w, h = ItemFootprint.getSize(beam)
    H.ok(w == 2 and h == 4, "viga (8.0) -> 2x4 [(" .. w .. "x" .. h .. ")]")

    -- Pillow: peso 1.0 Material volumoso → 2x2 (não 1x2)
    local pillow = makeItem(1.0, "Material")
    w, h = ItemFootprint.getSize(pillow)
    H.ok(w == 2 and h == 2, "travesseiro (1.0) -> 2x2 [(" .. w .. "x" .. h .. ")]")
end

-- Eletrônicos: walkie 1x1, TV 2x2
do
    local walkie = makeItem(0.4, "Electronics")
    local w, h = ItemFootprint.getSize(walkie)
    H.ok(w == 1 and h == 1, "walkie (0.4) -> 1x1 [(" .. w .. "x" .. h .. ")]")

    local tv = makeItem(5.0, "Electronics")
    w, h = ItemFootprint.getSize(tv)
    H.ok(w == 2 and h == 2, "TV (5.0) -> 2x2 [(" .. w .. "x" .. h .. ")]")
end

-- Água: garrafinha 1x1, garrafa 1x2, galão 2x2
do
    local cup = makeItem(0.3, "WaterContainer")
    local w, h = ItemFootprint.getSize(cup)
    H.ok(w == 1 and h == 1, "copinho (0.3) -> 1x1 [(" .. w .. "x" .. h .. ")]")

    local bottle = makeItem(1.0, "WaterContainer")
    w, h = ItemFootprint.getSize(bottle)
    H.ok(w == 1 and h == 2, "garrafa (1.0) -> 1x2 [(" .. w .. "x" .. h .. ")]")

    local gallon = makeItem(5.0, "WaterContainer")
    w, h = ItemFootprint.getSize(gallon)
    H.ok(w == 2 and h == 2, "galão (5.0) -> 2x2 [(" .. w .. "x" .. h .. ")]")
end

-- Chave/segurança: sempre 1x1
do
    local key = makeItem(0.2, "Security")
    local w, h = ItemFootprint.getSize(key)
    H.ok(w == 1 and h == 1, "chave (0.2) -> 1x1 [(" .. w .. "x" .. h .. ")]")
end

-- ─── CONTAINERS: footprint escala pelo CAPACITY interno ─────────────────────
do
    -- Chaveiro (cap 1): 1x1, NUNCA 2x2
    local keyring = makeItem(0.05, "Accessory", nil, { cap = 1 })
    local w, h = ItemFootprint.getSize(keyring)
    H.ok(w == 1 and h == 1, "chaveiro (cap 1) -> 1x1, nunca 2x2 [(" .. w .. "x" .. h .. ")]")

    -- Sacolinha/estojo (cap 2-3): 1x2
    local pouch = makeItem(0.1, "Container", nil, { cap = 2 })
    w, h = ItemFootprint.getSize(pouch)
    H.ok(w == 1 and h == 2, "sacolinha (cap 2) -> 1x2 [(" .. w .. "x" .. h .. ")]")

    -- Pochete/toolbox (cap 4-6): 2x2
    local fanny = makeItem(0.5, "Bag", nil, { cap = 6 })
    w, h = ItemFootprint.getSize(fanny)
    H.ok(w == 2 and h == 2, "pochete (cap 6) -> 2x2 [(" .. w .. "x" .. h .. ")]")

    -- Mochila média (cap 8-12): 2x3
    local mid = makeItem(1.0, "Bag", nil, { cap = 10 })
    w, h = ItemFootprint.getSize(mid)
    H.ok(w == 2 and h == 3, "mochila média (cap 10) -> 2x3 [(" .. w .. "x" .. h .. ")]")

    -- Mochila grande (cap 20+): 3x3
    local big = makeItem(2.0, "Bag", nil, { cap = 20 })
    w, h = ItemFootprint.getSize(big)
    H.ok(w == 3 and h == 3, "mochila grande (cap 20) -> 3x3 [(" .. w .. "x" .. h .. ")]")
end

-- ─── CONTAINERS: NUNCA stackam por padrão (mesmo leves/vazios) ──────────────
do
    local GridContainer = require("DataModel/GridContainer")
    -- Chaveiro vazio é leve (0.05) mas é container → não pode stackar
    local keyring = makeItem(0.05, "Accessory", nil, { cap = 1 })
    H.ok(GridContainer.getStackableCompatKey(keyring) == nil,
        "chaveiro (container leve) NÃO stacka por padrão")

    -- Container pesado: também não stacka
    local big = makeItem(2.0, "Bag", nil, { cap = 20 })
    H.ok(GridContainer.getStackableCompatKey(big) == nil,
        "mochila (container pesado) NÃO stacka")

    -- Regressão: item NÃO-container leve continua stackável
    local rag = makeItem(0.1, "Clothing") -- não-container, leve
    rag.canStack = function() return true end
    H.ok(GridContainer.getStackableCompatKey(rag) ~= nil,
        "pano (não-container, leve) continua stackável")
end

-- ─── MÓVEIS: largura SEMPRE 6 (máx do grid), altura por peso ────────────────
do
    -- Moveable leve (2.0): 6x3
    local chair = makeItem(2.0, "Furniture")
    chair._isMoveable = true
    local w, h = ItemFootprint.getSize(chair)
    H.ok(w == 6 and h == 3, "cadeira (2.0) -> 6x3 [(" .. w .. "x" .. h .. ")]")

    -- Moveable médio (5.0): 6x5
    local table = makeItem(5.0, "Furniture")
    table._isMoveable = true
    w, h = ItemFootprint.getSize(table)
    H.ok(w == 6 and h == 5, "mesa (5.0) -> 6x5 [(" .. w .. "x" .. h .. ")]")

    -- Moveable pesado (15.0): 6x10
    local sofa = makeItem(15.0, "Furniture")
    sofa._isMoveable = true
    w, h = ItemFootprint.getSize(sofa)
    H.ok(w == 6 and h == 10, "sofá (15.0) -> 6x10 [(" .. w .. "x" .. h .. ")]")

    -- Moveable muito pesado (25.0): 6x12
    local fridge = makeItem(25.0, "Furniture")
    fridge._isMoveable = true
    w, h = ItemFootprint.getSize(fridge)
    H.ok(w == 6 and h == 12, "geladeira (25.0) -> 6x12 [(" .. w .. "x" .. h .. ")]")
end

-- ─── Footprint vertical (Tarkov): longos e finos 1x3, volumosos 2xN ─────────
do
    -- vara de pescar: LONGOS e finos mantêm 1x3
    local rod = makeItem(1.0, "Fishing")
    local w, h = ItemFootprint.getSize(rod)
    H.ok(w == 1 and h == 3, "vara de pescar (1.0) -> 1x3 [(" .. w .. "x" .. h .. ")]")

    -- violão: LONGOS e finos mantêm 1x3
    local guitar = makeItem(1.0, "Instrument")
    w, h = ItemFootprint.getSize(guitar)
    H.ok(w == 1 and h == 3, "violão (1.0) -> 1x3 [(" .. w .. "x" .. h .. ")]")

    -- barraca grande: VOLUMOSA -> 2x3 (não 1x4, dá espaço pro sprite)
    local tent = makeItem(8.0, "Camping")
    w, h = ItemFootprint.getSize(tent)
    H.ok(w == 2 and h == 3, "barraca (8.0) -> 2x3 [(" .. w .. "x" .. h .. ")]")

    -- marreta/pé de cabra: VOLUMOSO -> 2x3
    local crowbar = makeItem(3.0, "Tool")
    w, h = ItemFootprint.getSize(crowbar)
    H.ok(w == 2 and h == 3, "marreta (3.0) -> 2x3 [(" .. w .. "x" .. h .. ")]")

    -- caixão de balas: VOLUMOSO -> 2x2
    local ammoCase = makeItem(8.0, "Ammo")
    w, h = ItemFootprint.getSize(ammoCase)
    H.ok(w == 2 and h == 2, "caixão de balas (8.0) -> 2x2 [(" .. w .. "x" .. h .. ")]")

    -- Junk: sucata 1x2, volumoso 2x2
    local junkSm = makeItem(0.5, "Junk")
    w, h = ItemFootprint.getSize(junkSm)
    H.ok(w == 1 and h == 2, "sucata (0.5) -> 1x2 [(" .. w .. "x" .. h .. ")]")

    local junkBig = makeItem(0.8, "Junk")
    w, h = ItemFootprint.getSize(junkBig)
    H.ok(w == 2 and h == 2, "lixo (0.8) -> 2x2 [(" .. w .. "x" .. h .. ")]")

    -- Galões: PetrolCan (1.6) e JerryCan (4.0) são 2x2, não 1x2
    local petrol = makeItem(1.6, "VehicleMaintenance")
    w, h = ItemFootprint.getSize(petrol)
    H.ok(w == 2 and h == 2, "galão de gasolina (1.6) -> 2x2 [(" .. w .. "x" .. h .. ")]")

    local jerry = makeItem(4.0, "VehicleMaintenance")
    w, h = ItemFootprint.getSize(jerry)
    H.ok(w == 2 and h == 2, "jerrycan (4.0) -> 2x2 [(" .. w .. "x" .. h .. ")]")

    -- VHS: override fixo → sempre 2x1 (não 1x1)
    local vhs = makeItem(0.5, "Entertainment", nil, nil, "Base.VHS_Retail")
    w, h = ItemFootprint.getSize(vhs)
    H.ok(w == 2 and h == 1, "VHS (0.5) -> 2x1 [(" .. w .. "x" .. h .. ")]")

    local vhsHome = makeItem(0.5, "Entertainment", nil, nil, "Base.VHS_Home")
    w, h = ItemFootprint.getSize(vhsHome)
    H.ok(w == 2 and h == 1, "VHS_Home -> 2x1 [(" .. w .. "x" .. h .. ")]")

    -- Regressão: outro Entertainment continua na regra normal (fita 1x1)
    local tape = makeItem(0.4, "Entertainment", nil, nil, "Base.RecordingTape")
    w, h = ItemFootprint.getSize(tape)
    H.ok(w == 1 and h == 1, "fita comum (0.4) -> 1x1 [(" .. w .. "x" .. h .. ")]")
end

-- ─── Novos overrides (GridOverrides.ini limpo) ──────────────────────────────
do
    local function sz(ft, weight, cat)
        local it = makeItem(weight, cat, nil, nil, ft)
        return ItemFootprint.getSize(it)
    end
    local w, h

    w, h = sz("Base.Pillow", 1.0, "Material")
    H.ok(w == 3 and h == 2, "Pillow -> 3x2 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.Spatula", 0.6, "Cooking")
    H.ok(w == 1 and h == 2, "Spatula -> 1x2 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.RadioRed", 3.0, "Electronics")
    H.ok(w == 3 and h == 2, "RadioRed -> 3x2 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.IDcard", 0.1, "Memento")
    H.ok(w == 1 and h == 1, "IDcard -> 1x1 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.Garbagebag", 1.5, "Household")
    H.ok(w == 2 and h == 3, "Garbagebag -> 2x3 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.WeldingRods", 1.0, "Tool")
    H.ok(w == 2 and h == 2, "WeldingRods -> 2x2 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.Strainer", 0.4, "Cooking")
    H.ok(w == 1 and h == 2, "Strainer -> 1x2 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.Mirror", 2.0, "Household")
    H.ok(w == 2 and h == 2, "Mirror -> 2x2 [(" .. w .. "x" .. h .. ")]")

    -- Novos overrides nativos vindos do GridOverrides.ini do dev
    w, h = sz("Base.EngineParts", 2.5, "VehicleMaintenance")
    H.ok(w == 3 and h == 2, "EngineParts -> 3x2 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.Doorknob", 0.4, "Junk")
    H.ok(w == 1 and h == 2, "Doorknob -> 1x2 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.HuntingKnife", 0.8, "Junk")
    H.ok(w == 3 and h == 1, "HuntingKnife -> 3x1 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.Boxers_Hearts", 0.5, "Clothing")
    H.ok(w == 1 and h == 2, "Boxers_Hearts -> 1x2 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.IDcard_Male", 0.1, "Memento")
    H.ok(w == 1 and h == 1, "IDcard_Male -> 1x1 [(" .. w .. "x" .. h .. ")]")

    -- Containers calibrados: footprint nativo w/h (o grid interno é testado
    -- no bloco de GridContainer.getGridSize abaixo)
    w, h = sz("Base.Toolbox", 2.5, "Tool")
    H.ok(w == 3 and h == 2, "Toolbox -> 3x2 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.Shoebox", 0.5, "Household")
    H.ok(w == 2 and h == 1, "Shoebox -> 2x1 [(" .. w .. "x" .. h .. ")]")

    w, h = sz("Base.Bag_FannyPackFront", 0.4, "Clothing")
    H.ok(w == 2 and h == 1, "FannyPackFront -> 2x1 [(" .. w .. "x" .. h .. ")]")
end

-- ─── Grid interno nativo de containers (cols/rows do ItemFootprint.Overrides) ─
do
    local GridContainer = require("DataModel/GridContainer")
    local function makeInvContainer(fullType, cap)
        return {
            getCapacity = function() return cap end,
            getType = function() return "crate" end,
            getParent = function() return nil end,
            getContainingItem = function()
                if not fullType then return nil end
                return { getFullType = function() return fullType end }
            end,
        }
    end

    -- sem override nativo → fórmula por capacidade
    local w, h = GridContainer.getGridSize(makeInvContainer(nil, 24))
    H.ok(w == 6 and h == 8, "grid por capacidade (24 cap) -> 6x8 [" .. w .. "x" .. h .. "]")

    -- override NATIVO substitui a fórmula: Toolbox 6x3, Shoebox 6x2
    w, h = GridContainer.getGridSize(makeInvContainer("Base.Toolbox", 24))
    H.ok(w == 6 and h == 3, "Toolbox grid nativo -> 6x3 [" .. w .. "x" .. h .. "]")

    w, h = GridContainer.getGridSize(makeInvContainer("Base.Shoebox", 24))
    H.ok(w == 6 and h == 2, "Shoebox grid nativo -> 6x2 [" .. w .. "x" .. h .. "]" )

    -- GridDevTool ao vivo (GridOverrides.ini) TEM prioridade sobre o nativo
    local savedDev = _G.GridDevTool
    _G.GridDevTool = { Overrides = { ["Base.Toolbox"] = { cols = 4, rows = 4 } } }
    w, h = GridContainer.getGridSize(makeInvContainer("Base.Toolbox", 24))
    H.ok(w == 4 and h == 4, "GridDevTool prioriza sobre nativo -> 4x4 [" .. w .. "x" .. h .. "]")
    _G.GridDevTool = savedDev
end

_G.instanceof = og_instanceof

H.finish()
