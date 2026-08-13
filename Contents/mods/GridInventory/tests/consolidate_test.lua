-- consolidate_test.lua — STACK VIRTUAL (consolidação de pilhas).
-- O engine cria/limita cada pilha de objeto (20 pregos, 10 munição) e NÃO funde
-- além disso. A consolidação junta pilhas COMPATÍVEIS (mesmo compatKey + mesmo
-- retângulo) abaixo do maxStack numa única célula (ex.: 5×20 → 100).
-- Cobre: relocatePile (GridCore), merge no refresh, limite, compatibilidade,
-- rotação, posição manual, in-transit, modData, idempotência e retry de
-- unpositioned (a consolidação libera células).

local H = require("harness")
H.setName("consolidate_test")

-- ── Stubs do ambiente PZ ─────────────────────────────────────────────────────
_G.getPlayerHotbar = function() return nil end
_G.getTimestampMs = function() return 0 end
_G.getSpecificPlayer = function() return nil end
_G.instanceof = function() return false end
_G.ISTimedActionQueue = { getTimedActionQueue = function() return nil end }
_G.Events = { OnGameBoot = { Add = function() end } }

local GridContainer = require("DataModel/GridContainer")
local GridCore = require("DataModel/GridCore")
local ScatterLayout = require("Algorithm/ScatterLayout")
ScatterLayout.enabled = false -- evita o sorteador (newRNG/hashString) nos testes

-- ── Mocks ───────────────────────────────────────────────────────────────────
local function makeItem(id, fullType, count, gx, gy, rot, gridContainer, manual)
    local md = {
        gridX = gx, gridY = gy, gridRot = rot or false,
        gridContainer = gridContainer, gridManual = manual or nil,
    }
    return {
        getID = function() return id end,
        getModData = function() return md end,
        getFullType = function() return fullType end,
        getWeight = function() return 0.1 end,
        canStack = function() return true end,
        getCount = function() return count or 1 end,
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
    for _, g in ipairs(gc.grids) do
        if g.items[id] then return g.items[id] end
    end
    return nil
end

-- ─── Teste 1: relocatePile junta pilha inteira numa compatível ──────────────
do
    local g = GridCore.new(6, 6)
    local si = { limit = 100, units = 20 }
    g:insertItem("a", 1, 1, 1, 1, false, nil, "stack:Nails", si)
    g:insertItem("a2", 1, 1, 1, 1, false, nil, "stack:Nails", si)
    g:insertItem("b", 3, 1, 1, 1, false, nil, "stack:Nails", si)
    g:insertItem("b2", 3, 1, 1, 1, false, nil, "stack:Nails", si)

    local moved = g:relocatePile("b", "a")
    H.ok(moved ~= nil, "relocatePile retorna ids movidos")
    if moved then
        H.ok(#moved == 2, "movidos = 2 (líder b + membro b2) [n=" .. #moved .. "]")
    end
    H.ok(g.cells[1][1] == "a", "célula (1,1) continua com o líder a")
    H.ok(g.cells[3][1] == nil, "célula (3,1) liberada [(" .. tostring(g.cells[3][1]) .. ")]")
    H.ok(g:getStackSize("a") == 4, "pilha a agora tem 4 objetos [size=" .. g:getStackSize("a") .. "]")
    H.ok(g:getPileUnits("a") == 80, "pilha a tem 80 unidades [units=" .. g:getPileUnits("a") .. "]")
    H.ok(g.items["b"].stackMemberOf == "a", "b virou membro de a")
    H.ok(g.items["b2"].stackMemberOf == "a", "b2 virou membro de a")
end

-- ─── Teste 2: relocatePile GUARDS ───────────────────────────────────────────
do
    local g = GridCore.new(6, 6)
    local si = { limit = 100, units = 20 }
    g:insertItem("a", 1, 1, 1, 1, false, nil, "stack:Nails", si)
    g:insertItem("b", 3, 1, 1, 1, false, nil, "stack:Screws", si) -- compatKey diferente
    g:insertItem("c", 1, 2, 1, 1, true, nil, "stack:Nails", si)   -- retângulo igual mas rotacionado
    g:insertItem("d", 4, 1, 2, 1, false, nil, "stack:Nails", si)  -- retângulo diferente (2x1)
    g:insertItem("e", 1, 2, 1, 1, true, nil, "stack:Nails", si)   -- membro (empilha em c)
    -- b: compatKey diferente → não absorve
    H.ok(g:relocatePile("b", "a") == nil, "compatKey diferente não funde")
    -- c: rotacionado vs a não-rotacionado → não funde
    H.ok(g:relocatePile("c", "a") == nil, "rotação diferente não funde")
    -- d: retângulo 2x1 vs a 1x1 → não funde
    H.ok(g:relocatePile("d", "a") == nil, "retângulo diferente não funde")
    -- e: é membro (não-líder) → nunca é origem
    H.ok(g:relocatePile("e", "a") == nil, "membro não pode ser origem")
    -- a como origem de si mesmo → nil
    H.ok(g:relocatePile("a", "a") == nil, "origem == alvo não funde")
end

-- ─── Teste 3: relocatePile respeita o LIMITE do alvo ────────────────────────
do
    local g = GridCore.new(6, 6)
    local si = { limit = 100, units = 60 }
    g:insertItem("a", 1, 1, 1, 1, false, nil, "stack:X", si)
    g:insertItem("b", 3, 1, 1, 1, false, nil, "stack:X", si)
    -- 60 + 60 = 120 > 100 → NÃO funde
    H.ok(g:relocatePile("b", "a") == nil, "pilha inteira não cabe no limite (60+60>100)")
    H.ok(g.cells[3][1] == "b", "b permanece na célula (3,1)")
    -- com espaço (100 de limite, 40+40) → funde
    local g2 = GridCore.new(6, 6)
    local si2 = { limit = 100, units = 40 }
    g2:insertItem("a", 1, 1, 1, 1, false, nil, "stack:X", si2)
    g2:insertItem("b", 3, 1, 1, 1, false, nil, "stack:X", si2)
    H.ok(g2:relocatePile("b", "a") ~= nil, "pilha cabe no limite (40+40=80) funde")
    H.ok(g2:getPileUnits("a") == 80, "80 unidades após merge [units=" .. g2:getPileUnits("a") .. "]")
end

-- ─── Teste 4: refresh CONSOME 5×20 pregos numa célula (100) ─────────────────
do
    local items = {}
    for i = 1, 5 do
        table.insert(items, makeItem("n" .. i, "Base.Nails", 20, i, 1))
    end
    local gc = freshContainer(items)
    gc:refresh()
    local grid = gc.grids[1]
    local leaders = 0
    local occupied = 0
    for x = 1, grid.width do
        for y = 1, grid.height do
            local c = grid.cells[x][y]
            if c then occupied = occupied + 1 end
        end
    end
    local pileUnits = 0
    for id, d in pairs(grid.items) do
        if not d.stackMemberOf then
            leaders = leaders + 1
            pileUnits = grid:getPileUnits(id)
        end
    end
    H.ok(leaders == 1, "uma única pilha líder [leaders=" .. leaders .. "]")
    H.ok(pileUnits == 100, "pilha consolidada com 100 unidades [units=" .. pileUnits .. "]")
    H.ok(occupied == 1, "só 1 célula ocupada (5×20 → 100) [occupied=" .. occupied .. "]")
    H.ok(grid:getStackSize("n1") == 5 or grid:getStackSize("n2") == 5, "5 objetos na pilha")
end

-- ─── Teste 5: LIMITE respeitado no refresh (pilha cheia NÃO absorve) ────────
do
    -- 60 + 60 = 120 > limite 100 → duas pilhas continuam separadas
    local items = {
        makeItem("a1", "Base.Limited", 60, 1, 1),
        makeItem("a2", "Base.Limited", 60, 2, 1),
    }
    GridDevTool = { Overrides = { ["Base.Limited"] = { maxStack = 100 } } }
    local gc = freshContainer(items)
    gc:refresh()
    GridDevTool = nil
    local grid = gc.grids[1]
    local leaders = 0
    local pileUnits = 0
    for id, d in pairs(grid.items) do
        if not d.stackMemberOf then
            leaders = leaders + 1
            pileUnits = pileUnits + grid:getPileUnits(id)
        end
    end
    H.ok(leaders == 2, "120 > 100: pilhas permanecem separadas [leaders=" .. leaders .. "]")
    H.ok(pileUnits == 120, "total preservado [units=" .. pileUnits .. "]")
end

-- ─── Teste 6: compatKey DIFERENTE não funde no refresh ──────────────────────
do
    local items = {
        makeItem("a1", "Base.Nails", 20, 1, 1),
        makeItem("a2", "Base.Nails", 20, 1, 2),
        makeItem("b1", "Base.Screws", 20, 3, 1),
        makeItem("b2", "Base.Screws", 20, 3, 2),
    }
    local gc = freshContainer(items)
    gc:refresh()
    local grid = gc.grids[1]
    local leaders = 0
    for id, d in pairs(grid.items) do
        if not d.stackMemberOf then leaders = leaders + 1 end
    end
    H.ok(leaders == 2, "pregos e parafusos não se misturam [leaders=" .. leaders .. "]")
end

-- ─── Teste 7: ROTAÇÃO diferente não funde ───────────────────────────────────
do
    -- 1x2 deitado (não-rotated, em (4,1)) vs 1x2 em pé (rotated, em (1,1)):
    -- retângulos diferentes → nunca fundem.
    local function tallItem(id, gx, gy, rot)
        local it = makeItem(id, "Base.Tall", 10, gx, gy, rot)
        it.getWeight = function() return 0.5 end -- footprint 1x2
        return it
    end
    local items = {
        tallItem("t1", 1, 1, true),
        tallItem("t2", 1, 1, true),
        tallItem("u1", 4, 1, false),
        tallItem("u2", 4, 1, false),
    }
    local gc = freshContainer(items)
    gc:refresh()
    local grid = gc.grids[1]
    local leaders = 0
    for id, d in pairs(grid.items) do
        if not d.stackMemberOf then leaders = leaders + 1 end
    end
    H.ok(leaders == 2, "em pé e deitado não fundem [leaders=" .. leaders .. "]")
    H.ok(grid:getPileUnits("t1") == 20, "pilha em pé tem 20 (10+10) [units=" .. grid:getPileUnits("t1") .. "]")
    H.ok(grid:getPileUnits("u1") == 20, "pilha deitada tem 20 [units=" .. grid:getPileUnits("u1") .. "]")
end

-- ─── Teste 8: posição MANUAL (gridManual) nunca é MOVIDA ────────────────────
do
    -- man (manual) em (1,1): permanece E absorve as automáticas (alvo).
    local items = {
        makeItem("man", "Base.Nails", 20, 1, 1, false, "container:crate", true),
        makeItem("n1", "Base.Nails", 20, 2, 1),
        makeItem("n2", "Base.Nails", 20, 3, 1),
        makeItem("n3", "Base.Nails", 20, 4, 1),
    }
    local gc = freshContainer(items)
    gc:refresh()
    local grid = gc.grids[1]
    local leaders = 0
    local manPos = nil
    local manUnits = 0
    for id, d in pairs(grid.items) do
        if not d.stackMemberOf then
            leaders = leaders + 1
            if id == "man" then manPos = d.x end
            manUnits = manUnits + grid:getPileUnits(id)
        end
    end
    H.ok(manPos == 1, "item manual permanece na célula (1,1) [x=" .. tostring(manPos) .. "]")
    H.ok(leaders == 1, "automáticas consolidam NA manual (1 pilha) [leaders=" .. leaders .. "]")
    H.ok(manUnits == 80, "pilha manual absorveu as automáticas (20+20+20+20=80) [units=" .. manUnits .. "]")

    -- Caso inverso: manual em célula DEPOIS da automática — a manual NUNCA é
    -- movida; ela absorve a automática (1 pilha na célula da manual).
    local items2 = {
        makeItem("n1", "Base.Nails", 20, 1, 1),
        makeItem("man", "Base.Nails", 20, 2, 1, false, "container:crate", true),
    }
    local gc2 = freshContainer(items2)
    gc2:refresh()
    local grid2 = gc2.grids[1]
    local leaders2 = 0
    local manX2 = nil
    for id, d in pairs(grid2.items) do
        if not d.stackMemberOf then
            leaders2 = leaders2 + 1
            if id == "man" then manX2 = d.x end
        end
    end
    H.ok(manX2 == 2, "manual não é movida para a automática [x=" .. tostring(manX2) .. "]")
    H.ok(leaders2 == 1, "automática é absorvida pela manual (1 pilha) [leaders=" .. leaders2 .. "]")
end

-- ─── Teste 9: item em TRÂNSITO (InTransit) não é movido ─────────────────────
do
    GridInventory_InTransit = { ["n1"] = {} }
    local items = {
        makeItem("n1", "Base.Nails", 20, 1, 1),
        makeItem("n2", "Base.Nails", 20, 2, 1),
        makeItem("n3", "Base.Nails", 20, 3, 1),
        makeItem("n4", "Base.Nails", 20, 4, 1),
    }
    local gc = freshContainer(items)
    gc:refresh()
    GridInventory_InTransit = nil
    local grid = gc.grids[1]
    local leaders = 0
    local n1Cell = grid.items["n1"]
    for id, d in pairs(grid.items) do
        if not d.stackMemberOf then leaders = leaders + 1 end
    end
    H.ok(n1Cell and n1Cell.x == 1 and n1Cell.y == 1, "item em trânsito não é movido (permanece líder em 1,1)")
    H.ok(leaders >= 2, "em trânsito fica isolado da consolidação [leaders=" .. leaders .. "]")
end

-- ─── Teste 10: modData dos membros consolidados aponta pro líder ────────────
do
    local items = {}
    for i = 1, 5 do
        table.insert(items, makeItem("m" .. i, "Base.Nails", 20, i, 1))
    end
    local gc = freshContainer(items)
    gc:refresh()
    local grid = gc.grids[1]
    local leaderId, leaderX, leaderY
    for id, d in pairs(grid.items) do
        if not d.stackMemberOf then
            leaderId, leaderX, leaderY = id, d.x, d.y
        end
    end
    local allSynced = true
    for i = 1, 5 do
        local md = items[i]:getModData()
        if not (md.gridX == leaderX and md.gridY == leaderY and md.gridContainer == "container:crate") then
            allSynced = false
        end
    end
    H.ok(allSynced, "todos os 5 membros gravam a célula do líder + assinatura")
end

-- ─── Teste 11: IDEMPOTÊNCIA (2º refresh não muda nada) ──────────────────────
do
    local items = {}
    for i = 1, 5 do
        table.insert(items, makeItem("i" .. i, "Base.Nails", 20, i, 1))
    end
    local gc = freshContainer(items)
    gc:refresh()
    local grid1 = gc.grids[1]
    local leaders1 = 0
    for _, d in pairs(grid1.items) do
        if not d.stackMemberOf then leaders1 = leaders1 + 1 end
    end
    local units1 = 0
    for id, d in pairs(grid1.items) do
        if not d.stackMemberOf then units1 = grid1:getPileUnits(id) end
    end
    gc:refresh()
    local grid2 = gc.grids[1]
    local leaders2 = 0
    for _, d in pairs(grid2.items) do
        if not d.stackMemberOf then leaders2 = leaders2 + 1 end
    end
    local units2 = 0
    for id, d in pairs(grid2.items) do
        if not d.stackMemberOf then units2 = grid2:getPileUnits(id) end
    end
    H.ok(leaders1 == leaders2 and leaders2 == 1, "2º refresh: mesma estrutura (1 líder) [l1=" .. leaders1 .. " l2=" .. leaders2 .. "]")
    H.ok(units1 == units2 and units2 == 100, "2º refresh: mesmas unidades [u1=" .. units1 .. " u2=" .. units2 .. "]")
end

-- ─── Teste 12: retry de unpositioned após consolidação liberar células ──────
do
    -- Grid 6x2 = 12 células: 5×20 pregos (5 células) + 7 outros itens + 1 extra
    -- que não cabe. A consolidação funde os pregos → 4 células livres → o extra
    -- passa a caber e NÃO vira overflow fantasma.
    local items = {}
    for i = 1, 5 do
        table.insert(items, makeItem("n" .. i, "Base.Nails", 20, i, 1))
    end
    for i = 1, 7 do
        table.insert(items, makeItem("f" .. i, "Base.Fill" .. i, 1, nil, nil))
    end
    table.insert(items, makeItem("extra", "Base.Extra", 1, nil, nil))
    local gc = freshContainer(items)
    local unpos = gc:refresh()
    H.ok(#unpos == 0, "após consolidar, o extra agora cabe (sem overflow fantasma) [n=" .. #unpos .. "]")
    H.ok(gc.grids[1].items["extra"] ~= nil, "item extra posicionado no grid")
end

-- ─── Teste 13: MP — sendItemMove chamado pros membros consolidados ──────────
do
    local sent = {}
    _G.GridClientNetwork = {
        sendItemMove = function(container, itemId, x, y, rotated, sig, manual)
            table.insert(sent, { itemId = itemId, x = x, y = y, rotated = rotated, sig = sig, manual = manual })
        end,
    }
    local items = {}
    for i = 1, 5 do
        table.insert(items, makeItem("p" .. i, "Base.Nails", 20, i, 1))
    end
    local gc = freshContainer(items)
    gc:refresh()
    _G.GridClientNetwork = nil
    H.ok(#sent == 4, "4 membros movidos → 4 REQUEST_MOVE (líder fica) [n=" .. #sent .. "]")
    if #sent == 4 then
        local allSame = true
        for _, s in ipairs(sent) do
            if not (s.x == 1 and s.y == 1 and s.sig == "container:crate" and s.manual == nil) then
                allSame = false
            end
        end
        H.ok(allSame, "membros vão pra célula do líder (1,1), sem flag manual")
    end
end

-- ─── Teste 14: pilha com MEMBRO bloqueado não é absorvida ───────────────────
do
    -- a2 (membro de a1) está em trânsito: a pilha de a1 NUNCA pode ser absorvida
    -- como candidata (senão o item recém-soltado "teleportaria"). Como a1 está
    -- na célula posterior (2,1), o líder b (1,1) é varrido primeiro e deveria
    -- absorver a1 — o guard impede; no fim é a pilha de a1 que absorve b.
    GridInventory_InTransit = { ["a2"] = {} }
    local items = {
        makeItem("a1", "Base.Nails", 20, 2, 1),
        makeItem("a2", "Base.Nails", 20, 2, 1),
        makeItem("b", "Base.Nails", 20, 1, 1),
    }
    local gc = freshContainer(items)
    gc:refresh()
    GridInventory_InTransit = nil
    local grid = gc.grids[1]
    local leaderId, leaderCell
    for id, d in pairs(grid.items) do
        if not d.stackMemberOf then leaderId, leaderCell = id, d.x .. "," .. d.y end
    end
    H.ok(leaderId == "a1" and leaderCell == "2,1",
        "pilha com membro bloqueado não é absorvida [leader=" .. tostring(leaderId) .. " " .. tostring(leaderCell) .. "]")
    H.ok(grid.items["a2"] and grid.items["a2"].stackMemberOf == "a1",
        "membro bloqueado permanece membro de a1 (não movido)")
    H.ok(grid:getPileUnits(leaderId) == 60, "pilha absorveu b (20+20+20=60)")
end

H.finish()
