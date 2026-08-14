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

-- Container de CHÃO (getType() == "floor"): grid fixo 6x15 (90 slots),
-- posição salva ignorada, scatter desligado.
local function makeFloorContainer(items)
    local list = items
    return {
        getItems = function()
            return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
        end,
        getCapacity = function() return 90 end,
        getType = function() return "floor" end,
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

local function freshFloorContainer(items)
    GridContainer.instances = {}
    local inv = makeFloorContainer(items)
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

-- ─── Teste 10: CHÃO abre grid extra quando o 1º grid enche ───────────────────
-- Grid de chão = 6x15 (90 slots). 91 itens 1x1 não empilháveis → o 91º vai pro
-- grid[2] (overflow vira grid REAL de chão, não lista 1x1). unpositioned = 0.
do
    local items = {}
    for i = 1, 91 do
        -- fullType ÚNICO por item (não empilham entre si)
        table.insert(items, makeItem("f" .. i, "Base.FloorFill" .. i, 0.1, nil, nil))
    end
    local gc = freshFloorContainer(items)
    local unpos = gc:refresh()
    H.ok(#gc.grids == 2, "chão com 91 itens abre 2 grids [n=" .. #gc.grids .. "]")
    H.ok(#unpos == 0, "chão com grids extras: unpositioned = 0 [n=" .. #unpos .. "]")
    H.ok(gc.grids[1].width == 6 and gc.grids[1].height == 15,
        "grid[1] mantém tamanho original (6x15) [(" .. gc.grids[1].width .. "x" .. gc.grids[1].height .. ")]")
    H.ok(gc.grids[2].width == 6 and gc.grids[2].height == 15,
        "grid[2] também é 6x15 (tamanho original do chão) [(" .. gc.grids[2].width .. "x" .. gc.grids[2].height .. ")]")
end

-- ─── Teste 11: CHÃO respeita o teto MAX_FLOOR_GRIDS (8) ──────────────────────
-- 8 grids × 90 slots = 720 slots. 721 itens 1x1 → 720 cabem, 1 fica unpositioned.
do
    local items = {}
    for i = 1, 721 do
        table.insert(items, makeItem("g" .. i, "Base.FloorMax" .. i, 0.1, nil, nil))
    end
    local gc = freshFloorContainer(items)
    local unpos = gc:refresh()
    H.ok(#gc.grids == 8, "chão respeita teto de 8 grids [n=" .. #gc.grids .. "]")
    H.ok(#unpos == 1, "1 item sem vaga além do teto [n=" .. #unpos .. "]")
end

-- ─── Teste 12: container NÃO-chão NÃO abre grids extras ──────────────────────
-- Regressão: crate 6x2 (12 slots) com 13 itens → continua 1 grid + unpositioned.
do
    local items = {}
    for i = 1, 13 do
        table.insert(items, makeItem("c" .. i, "Base.CrateFill" .. i, 0.1, nil, nil))
    end
    local gc = freshContainer(items)
    local unpos = gc:refresh()
    H.ok(#gc.grids == 1, "crate não abre grid extra [n=" .. #gc.grids .. "]")
    H.ok(#unpos == 1, "crate mantém overflow em unpositioned [n=" .. #unpos .. "]")
end

-- ─── Teste 13: FLASH NÃO dispara na 1ª abertura do container ────────────────
-- Loot de mundo novo (nunca vasculhado): previouslyPlaced vazio → TODOS os
-- itens entram de uma vez e NADA pisca (senão tudo piscaria).
do
    GridInventory_AutoSlotFlash = nil
    local items = {
        makeItem("a1", "Base.FlashA", 0.1, nil, nil),
        makeItem("a2", "Base.FlashB", 0.1, nil, nil),
    }
    local gc = freshContainer(items)
    gc:refresh()
    H.ok(GridInventory_AutoSlotFlash == nil or next(GridInventory_AutoSlotFlash) == nil,
        "1ª abertura: nenhum flash (container novo, previouslyPlaced vazio)")
    GridInventory_AutoSlotFlash = nil
end

-- ─── Teste 14: FLASH de autoSlot em container JÁ em uso ─────────────────────
-- Container já tinha itens (previouslyPlaced não vazio): item novo sem posição
-- entra por auto-fit → flasha. E NÃO re-marca no refresh seguinte.
do
    GridInventory_AutoSlotFlash = nil
    local items = { makeItem("f1", "Base.F1", 0.1, 1, 1) } -- já posicionado
    local gc = freshContainer(items)
    gc:refresh()
    -- adiciona item novo SEM posição e re-refresca (container em uso)
    table.insert(items, makeItem("new1", "Base.FlashNew", 0.1, nil, nil))
    gc:refresh()
    H.ok(GridInventory_AutoSlotFlash ~= nil and GridInventory_AutoSlotFlash["new1"] ~= nil,
        "container em uso: item novo marca flash [" .. tostring(GridInventory_AutoSlotFlash and GridInventory_AutoSlotFlash["new1"]) .. "]")

    -- 3º refresh: o item já está no grid (previouslyPlaced) → NÃO re-marca
    GridInventory_AutoSlotFlash = {}
    gc:refresh()
    H.ok(GridInventory_AutoSlotFlash["new1"] == nil,
        "refresh seguinte NÃO re-marca (item já posicionado)")
    GridInventory_AutoSlotFlash = nil
end

-- ─── Teste 15: FLASH de item EMPILHADO marca o LÍDER ────────────────────────
do
    GridInventory_AutoSlotFlash = nil
    local items = { makeItem("ldr", "Base.Same2", 0.1, 1, 1) } -- líder já no grid
    local gc = freshContainer(items)
    gc:refresh()
    -- membro novo sem posição empilha no líder no 2º refresh (container em uso)
    table.insert(items, makeItem("mbr", "Base.Same2", 0.1, nil, nil))
    gc:refresh()
    H.ok(gc.grids[1]:getStackSize("ldr") == 2, "membro empilhou no líder")
    H.ok(GridInventory_AutoSlotFlash ~= nil and GridInventory_AutoSlotFlash["mbr"] == nil,
        "flash NÃO fica no membro")
    H.ok(GridInventory_AutoSlotFlash["ldr"] ~= nil,
        "flash fica no LÍDER da pilha")
    GridInventory_AutoSlotFlash = nil
end

-- ─── Teste 16: REGRESSÃO — overflow volta pro grid quando espaço abre ───────
-- Bug reportado: ao liberar espaço no grid, o item de overflow NÃO refluía até
-- um rebuild forçado (trocar de container). O refresh() deve recolocar o item
-- que agora cabe (a UI do overflow é um snapshot só recriado no rebuild — se a
-- matemática não refletir o reflow, o snapshot fica stale pra sempre).
do
    -- 13 itens 1x1 num grid 6x2 (12 slots) → 12 no grid, 1 no overflow.
    local items = {}
    for i = 1, 13 do
        table.insert(items, makeItem("r" .. i, "Base.Reflow" .. i, 0.1, nil, nil))
    end
    local gc = freshContainer(items)
    local unpos1 = gc:refresh()
    H.ok(#unpos1 == 1, "cheio: 1 item no overflow [n=" .. #unpos1 .. "]")
    local gridCount = 0
    for _ in pairs(gc.grids[1].items) do gridCount = gridCount + 1 end
    H.ok(gridCount == 12, "cheio: 12 itens no grid [n=" .. gridCount .. "]")

    -- Libera 1 slot (jogador pegou um item do grid) → refresh → overflow reflui.
    table.remove(items, 1)
    local unpos2 = gc:refresh()
    H.ok(#unpos2 == 0, "espaço aberto: overflow refluiu pro grid [n=" .. #unpos2 .. "]")
    local gridCount2 = 0
    for _ in pairs(gc.grids[1].items) do gridCount2 = gridCount2 + 1 end
    H.ok(gridCount2 == 12, "espaço aberto: 12 itens no grid (todos cabem) [n=" .. gridCount2 .. "]")
end

-- ─── Teste 17: REGRESSÃO — REORDER no mesmo grid devolve item do overflow ────
-- Reorder é puramente modData (o item NÃO sai do container): em SP não há eco
-- do servidor, o poll 300ms não detecta (hash de itens igual) e OnContainerUpdate
-- não dispara. O fix (GridClientNetwork.markGridChanged no performGridReorder)
-- dispara o refresh — e a matemática precisa recolocar o overflow que agora cabe
-- num bloco contíguo aberto pelo reorder.
do
    -- Grid 6x2 (12 slots). 8 itens 1x1 ocupam as 2 colunas centrais x 2 linhas,
    -- deixando livres os 4 CANTOS (sem NENHUM bloco 2x2 contíguo) → o item
    -- 2x2 ("Base.Pan") NÃO cabe → overflow.
    local items = {
        makeItem("s1", "Base.S1", 0.1, 2, 1),
        makeItem("s2", "Base.S2", 0.1, 3, 1),
        makeItem("s3", "Base.S3", 0.1, 4, 1),
        makeItem("s4", "Base.S4", 0.1, 5, 1),
        makeItem("s5", "Base.S5", 0.1, 2, 2),
        makeItem("s6", "Base.S6", 0.1, 3, 2),
        makeItem("s7", "Base.S7", 0.1, 4, 2),
        makeItem("s8", "Base.S8", 0.1, 5, 2),
        makeItem("zbig", "Base.Pan", 2.0, nil, nil), -- 2x2 (override nativo)
    }
    local gc = freshContainer(items)
    local unpos1 = gc:refresh()
    local bigInOverflow = false
    for _, u in ipairs(unpos1) do
        if u:getID() == "zbig" then bigInOverflow = true end
    end
    H.ok(bigInOverflow, "2x2 sem bloco contíguo -> zbig no overflow")
    H.ok(#unpos1 == 1, "overflow tem só o zbig [n=" .. #unpos1 .. "]")

    -- REORDER no mesmo grid: move s4 (5,1)→(1,1) e s8 (5,2)→(1,2), abrindo o
    -- bloco 2x2 (5,1)-(6,2) contíguo. Isso é EXATAMENTE o que o performGridReorder
    -- grava no modData (gridX/gridY/gridManual) antes do markGridChanged.
    items[4]:getModData().gridX = 1
    items[4]:getModData().gridY = 1
    items[4]:getModData().gridManual = true
    items[8]:getModData().gridX = 1
    items[8]:getModData().gridY = 2
    items[8]:getModData().gridManual = true

    -- Refresh (o que o markGridChanged → refreshContainerGrid → gc:refresh() faz).
    local unpos2 = gc:refresh()
    H.ok(#unpos2 == 0, "reorder abriu bloco 2x2 -> zbig voltou pro grid [n=" .. #unpos2 .. "]")
    local bigBack = gc.grids[1].items["zbig"]
    H.ok(bigBack ~= nil, "zbig está no grid")
    H.ok(bigBack and bigBack.x == 5 and bigBack.y == 1,
        "zbig ancorou no bloco aberto (5,1) [(" .. tostring(bigBack and bigBack.x) .. "," .. tostring(bigBack and bigBack.y) .. ")]")
end

H.finish()
