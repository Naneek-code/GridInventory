-- refresh_stack_test.lua — GridContainer:refresh().
-- Testa: posição salva, auto-fit de item sem posição, empilhamento no refresh,
-- não-empilháveis não sobrepõem, limite de unidades, grid cheio → unpositioned,
-- e gravação da posição auto-gerada no modData.

local H = require("harness")
H.setName("refresh_stack_test")

-- ── Stubs do ambiente PZ ─────────────────────────────────────────────────────
_G.getPlayerHotbar = function() return nil end
_G.getTimestampMs = function() return 0 end
_G.getSpecificPlayer = function() return nil end
_G.instanceof = function() return false end
_G.ISTimedActionQueue = { getTimedActionQueue = function() return nil end }
_G.Events = { OnGameBoot = { Add = function() end } }
-- GridDevTool fica nil (o getStackableCompatKey checa e segue pro fallback leve)

local GridContainer = require("DataModel/GridContainer")
local ScatterLayout = require("Algorithm/ScatterLayout")
ScatterLayout.enabled = false -- evita o sorteador (newRNG/hashString) nos testes

-- ── Mocks ───────────────────────────────────────────────────────────────────
local function makeItem(id, fullType, weight, gx, gy, rot, gridContainer)
    local md = { gridX = gx, gridY = gy, gridRot = rot or false, gridContainer = gridContainer }
    return {
        getID = function() return id end,
        getModData = function() return md end,
        getFullType = function() return fullType or "Base.TestDefault" end,
        getWeight = function() return weight or 0.1 end,
        canStack = function() return true end,
        getCount = function() return 1 end,
        isHidden = function() return false end,
    }
end

-- Container tipo "crate" com capacity 6 → grid 6x2 (12 slots).
local function makeContainer(items)
    local list = items
    return {
        getItems = function()
            return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
        end,
        getCapacity = function() return 6 end,
        getType = function() return "crate" end,
        getParent = function() return nil end,
        getContainingItem = function() return nil end,
        isInCharacterInventory = function() return false end,
    }
end

local function freshContainer(items)
    GridContainer.instances = {}
    local inv = makeContainer(items)
    return GridContainer.getOrCreate(inv, 0), inv
end

local function itemAt(gc, id)
    return gc.grids[1].items[id]
end

-- ─── Teste 1: posição SAVADA é respeitada ───────────────────────────────────
do
    local gc = freshContainer({ makeItem("a", "Base.A", 0.1, 3, 2) })
    gc:refresh()
    local it = itemAt(gc, "a")
    H.ok(it ~= nil, "item entrou no grid")
    H.ok(it and it.x == 3 and it.y == 2, "item salvo (3,2) permanece [(" .. tostring(it and it.x) .. "," .. tostring(it and it.y) .. ")]")
end

-- ─── Teste 2: item SEM posição → auto-fit top-left livre ────────────────────
do
    local gc = freshContainer({
        makeItem("a", "Base.A", 0.1, nil, nil),  -- sem posição
        makeItem("b", "Base.B", 0.1, 2, 2),
    })
    gc:refresh()
    local a = itemAt(gc, "a")
    H.ok(a and a.x == 1 and a.y == 1, "item sem posição foi pro top-left (1,1) [(" .. tostring(a and a.x) .. "," .. tostring(a and a.y) .. ")]")
    local b = itemAt(gc, "b")
    H.ok(b and b.x == 2 and b.y == 2, "item salvo (2,2) mantido [(" .. tostring(b and b.x) .. "," .. tostring(b and b.y) .. ")]")
end

-- ─── Teste 3: EMPILHAMENTO no refresh (mesmo fullType leve, mesma posição) ──
do
    local gc = freshContainer({
        makeItem("a", "Base.Same", 0.1, 1, 1),
        makeItem("b", "Base.Same", 0.1, 1, 1),
    })
    gc:refresh()
    H.ok(gc.grids[1]:getStackSize("a") == 2, "pilha reconstruída com 2 [size=" .. gc.grids[1]:getStackSize("a") .. "]")
    H.ok(gc.grids[1].cells[1][1] == "a", "célula aponta pro líder")
    H.ok(gc.grids[1].items["b"].stackMemberOf == "a", "b virou membro da pilha de a")
end

-- ─── Teste 4: item PESADO (não-empilhável) não sobrepõe mesma posição ───────
do
    local gc = freshContainer({
        makeItem("a", "Base.Heavy", 2.0, 1, 1),
        makeItem("b", "Base.Heavy", 2.0, 1, 1),
    })
    gc:refresh()
    local a = itemAt(gc, "a")
    local b = itemAt(gc, "b")
    H.ok(a and a.x == 1 and a.y == 1, "a fica em (1,1)")
    H.ok(b and not (b.x == 1 and b.y == 1), "b NÃO sobrepõe a [(" .. tostring(b and b.x) .. "," .. tostring(b and b.y) .. ")]")
    H.ok(gc.grids[1]:getStackSize("a") == 1, "não formou pilha [size=" .. gc.grids[1]:getStackSize("a") .. "]")
end

-- ─── Teste 5: LIMITE DE UNIDADES no refresh (pilha cheia não empilha mais) ──
do
    GridDevTool = { Overrides = { ["Base.Limited"] = { maxStack = 2 } } } -- 2 unidades máx
    local gc = freshContainer({
        makeItem("a", "Base.Limited", 0.1, 1, 1),
        makeItem("b", "Base.Limited", 0.1, 1, 1),
        makeItem("c", "Base.Limited", 0.1, 1, 1),
    })
    gc:refresh()
    GridDevTool = nil
    H.ok(gc.grids[1]:getStackSize("a") == 2, "pilha de a tem 2 (limite 2) [size=" .. gc.grids[1]:getStackSize("a") .. "]")
    local c = itemAt(gc, "c")
    H.ok(c and not (c.x == 1 and c.y == 1), "c NÃO empilha (pilha cheia) -> outra célula [(" .. tostring(c and c.x) .. "," .. tostring(c and c.y) .. ")]")
end

-- ─── Teste 6: GRID CHEIO → itens extras viram unpositioned ──────────────────
do
    local items = {}
    for x = 1, 6 do
        for y = 1, 2 do
            -- fullType ÚNICO por item (não empilham entre si)
            table.insert(items, makeItem("f" .. x .. "_" .. y, "Base.Fill" .. x .. "_" .. y, 0.1, x, y))
        end
    end
    table.insert(items, makeItem("extra", "Base.Extra", 0.1, nil, nil))
    local gc = freshContainer(items)
    local unpos = gc:refresh()
    -- "extra" ordena primeiro (id 'e' < 'f') e toma a vaga; o ÚLTIMO fill
    -- (f6_2, posição salva roubada) é quem acaba sem espaço.
    H.ok(#unpos == 1, "só 1 item sem vaga [n=" .. #unpos .. "]")
    if #unpos == 1 then
        H.ok(unpos[1]:getID() == "f6_2", "o sem vaga é o último fill (f6_2) [" .. tostring(unpos[1]:getID()) .. "]")
    end
end

-- ─── Teste 7: refresh GRAVA a posição auto-gerada no modData ────────────────
do
    local item = makeItem("a", "Base.A", 0.1, nil, nil)
    local gc = freshContainer({ item })
    gc:refresh()
    local md = item:getModData()
    H.ok(md.gridX == 1 and md.gridY == 1 and md.gridRot == false,
        "modData salvo após auto-fit [(" .. tostring(md.gridX) .. "," .. tostring(md.gridY) .. ")]")
end

-- ─── Teste 8: previouslPlaced — item já posicionado não perde a vaga ────────
do
    local items = {
        makeItem("a", "Base.A", 0.1, 1, 1),
        makeItem("b", "Base.B", 0.1, 1, 2),
    }
    local gc = freshContainer(items)
    gc:refresh()
    -- adiciona um item novo e re-refresca
    table.insert(items, makeItem("c", "Base.C", 0.1, nil, nil))
    gc:refresh()
    local a = itemAt(gc, "a")
    local b = itemAt(gc, "b")
    local c = itemAt(gc, "c")
    H.ok(a and a.x == 1 and a.y == 1, "a mantém (1,1) [(" .. tostring(a and a.x) .. "," .. tostring(a and a.y) .. ")]")
    H.ok(b and b.x == 1 and b.y == 2, "b mantém (1,2) [(" .. tostring(b and b.x) .. "," .. tostring(b and b.y) .. ")]")
    H.ok(c and c.x == 2 and c.y == 1, "c novo vai pra próxima livre (2,1) [(" .. tostring(c and c.x) .. "," .. tostring(c and c.y) .. ")]")
end

-- ─── Teste 9: ASSINATURA de container — posição só vale no MESMO container ──
-- Container mock "crate" tem assinatura "container:crate".
do
    -- a) assinatura bate -> posição salva honrada
    local gc = freshContainer({ makeItem("a", "Base.A", 0.1, 3, 2, false, "container:crate") })
    gc:refresh()
    local it = itemAt(gc, "a")
    H.ok(it and it.x == 3 and it.y == 2, "assinatura bate -> posição (3,2) honrada [(" .. tostring(it and it.x) .. "," .. tostring(it and it.y) .. ")]")

    -- b) assinatura DIFERENTE (transferido do inventário "player") -> posição IGNORADA
    local gc2 = freshContainer({ makeItem("b", "Base.B", 0.1, 3, 2, false, "player") })
    gc2:refresh()
    local it2 = itemAt(gc2, "b")
    H.ok(it2 and it2.x == 1 and it2.y == 1,
        "assinatura diferente -> posição antiga IGNORADA -> autogrid (1,1) [(" .. tostring(it2 and it2.x) .. "," .. tostring(it2 and it2.y) .. ")]")

    -- c) item legado (SEM assinatura) mantém posição (compat saves antigos)
    local gc3 = freshContainer({ makeItem("c", "Base.C", 0.1, 3, 2) })
    gc3:refresh()
    local it3 = itemAt(gc3, "c")
    H.ok(it3 and it3.x == 3 and it3.y == 2, "item legado (sem assinatura) mantém posição [(" .. tostring(it3 and it3.x) .. "," .. tostring(it3 and it3.y) .. ")]")

    -- d) refresh GRAVA a assinatura do container no modData ao posicionar
    local item = makeItem("d", "Base.D", 0.1, nil, nil)
    local gc4 = freshContainer({ item })
    gc4:refresh()
    local md = item:getModData()
    H.ok(md.gridContainer == "container:crate", "refresh grava assinatura no modData [" .. tostring(md.gridContainer) .. "]")
end

H.finish()
