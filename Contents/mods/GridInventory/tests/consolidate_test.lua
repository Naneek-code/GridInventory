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

-- ─── Teste 4: refresh CONSOME 5 objetos de prego numa célula (5 unidades) ──
do
    local items = {}
    for i = 1, 5 do
        table.insert(items, makeItem("n" .. i, "Base.Nails", 1, i, 1))
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
    H.ok(pileUnits == 5, "pilha consolidada com 5 unidades [units=" .. pileUnits .. "]")
    H.ok(occupied == 1, "só 1 célula ocupada (5 objetos → 1 pilha) [occupied=" .. occupied .. "]")
    H.ok(grid:getStackSize("n1") == 5 or grid:getStackSize("n2") == 5, "5 objetos na pilha")
end

-- ─── Teste 5: LIMITE respeitado no refresh (pilha cheia NÃO absorve) ────────
do
    -- 120 > limite 100 (objetos) → duas pilhas continuam separadas
    local items = {}
    for i = 1, 120 do
        table.insert(items, makeItem("a" .. i, "Base.Limited", 1, nil, nil))
    end
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
    H.ok(grid:getPileUnits("t1") == 2, "pilha em pé tem 2 (1+1) [units=" .. grid:getPileUnits("t1") .. "]")
    H.ok(grid:getPileUnits("u1") == 2, "pilha deitada tem 2 [units=" .. grid:getPileUnits("u1") .. "]")
end

-- ─── Teste 8: posição MANUAL (gridManual) é INERTE na consolidação ──────────
do
    -- man (manual) em (1,1): NÃO absorve nem é absorvida — as automáticas
    -- consolidam ENTRE SI, deixando a manual isolada (controle do jogador).
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
    local autoUnits = 0
    for id, d in pairs(grid.items) do
        if not d.stackMemberOf then
            leaders = leaders + 1
            if id == "man" then
                manPos = d.x
                manUnits = grid:getPileUnits(id)
            else
                autoUnits = grid:getPileUnits(id)
            end
        end
    end
    H.ok(manPos == 1, "item manual permanece na célula (1,1) [x=" .. tostring(manPos) .. "]")
    H.ok(leaders == 2, "manual NÃO absorve as automáticas (2 pilhas) [leaders=" .. leaders .. "]")
    H.ok(manUnits == 1, "pilha manual fica com 1 unidade (não absorve) [units=" .. tostring(manUnits) .. "]")
    H.ok(autoUnits == 3, "automáticas consolidam entre si (1+1+1=3) [units=" .. tostring(autoUnits) .. "]")

    -- Caso inverso: manual em célula DEPOIS da automática — a manual NÃO é
    -- movida NEM absorve: ficam 2 pilhas separadas.
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
    H.ok(leaders2 == 2, "manual fica separada da automática (2 pilhas) [leaders=" .. leaders2 .. "]")
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
    H.ok(units1 == units2 and units2 == 5, "2º refresh: mesmas unidades [u1=" .. units1 .. " u2=" .. units2 .. "]")
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
    H.ok(grid:getPileUnits(leaderId) == 3, "pilha absorveu b (1+1+1=3)")
end

-- ─── Teste 15: unidades = OBJETOS (o B42 conta o objeto, não o count do script) ──
-- O jogo cria uma caixa de pregos como 100 objetos de Base.Nails (cada um conta
-- como 1 prego — o count=5 do script é vestigial; o pack de 100 consome 100
-- objetos). O mod deve tratar CADA OBJETO como 1 unidade: uma caixa (100 objetos)
-- vira UMA pilha de 100 (limite exato), e 500 objetos viram 5 pilhas de 100.
do
    local function makeNail(id, gx, gy)
        return makeItem(id, "Base.Nails", 1, gx, gy)
    end

    -- Um único objeto = 1 unidade (badge oculto; "1 prego")
    local gc1 = freshContainer({ makeNail("solo", nil, nil) })
    gc1:refresh()
    local soloData = itemAt(gc1, "solo")
    H.ok(soloData and soloData.stackInfo and soloData.stackInfo.units == 1,
        "objeto único tem units=1 no stackInfo [units=" .. tostring(soloData and soloData.stackInfo and soloData.stackInfo.units) .. "]")
    H.ok(gc1.grids[1]:getPileUnits("solo") == 1,
        "pilha de 1 objeto = 1 unidade [units=" .. gc1.grids[1]:getPileUnits("solo") .. "]")

    -- Dois objetos: 2 unidades, 2 objetos
    local gc2 = freshContainer({ makeNail("n1", 1, 1), makeNail("n2", 2, 1) })
    gc2:refresh()
    local grid2 = gc2.grids[1]
    local leader2 = nil
    for id, d in pairs(grid2.items) do
        if not d.stackMemberOf then leader2 = id end
    end
    H.ok(leader2 ~= nil and grid2:getPileUnits(leader2) == 2,
        "1+1 consolidado = 2 unidades [units=" .. tostring(leader2 and grid2:getPileUnits(leader2)) .. "]")
    H.ok(leader2 ~= nil and grid2:getStackSize(leader2) == 2,
        "1+1 = 2 objetos na pilha [size=" .. tostring(leader2 and grid2:getStackSize(leader2)) .. "]")

    -- UMA caixa = 100 objetos → UMA pilha de 100 (o caso do usuário!)
    local boxItems = {}
    for i = 1, 100 do
        table.insert(boxItems, makeNail("b" .. i, nil, nil))
    end
    local gcBox = freshContainer(boxItems)
    gcBox:refresh()
    local gridBox = gcBox.grids[1]
    local boxLeaders = 0
    local boxUnits = 0
    for id, d in pairs(gridBox.items) do
        if not d.stackMemberOf then
            boxLeaders = boxLeaders + 1
            boxUnits = gridBox:getPileUnits(id)
        end
    end
    H.ok(boxLeaders == 1, "1 caixa (100 objetos) = 1 pilha [leaders=" .. boxLeaders .. "]")
    H.ok(boxUnits == 100, "pilha da caixa = 100 unidades [units=" .. boxUnits .. "]")

    -- 500 objetos (5 caixas) → 5 pilhas de 100, total preservado (cap mantido)
    local items = {}
    for i = 1, 500 do
        table.insert(items, makeNail("m" .. i, nil, nil))
    end
    local gc3 = freshContainer(items)
    gc3:refresh()
    local grid3 = gc3.grids[1]
    local leaders, total = 0, 0
    for id, d in pairs(grid3.items) do
        if not d.stackMemberOf then
            leaders = leaders + 1
            total = total + grid3:getPileUnits(id)
        end
    end
    H.ok(leaders == 5, "500 objetos → 5 pilhas de 100 [leaders=" .. leaders .. "]")
    H.ok(total == 500, "total de unidades preservado (500) [total=" .. total .. "]")
end

H.finish()
