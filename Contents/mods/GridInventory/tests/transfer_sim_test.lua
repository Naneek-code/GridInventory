-- transfer_sim_test.lua — simula o fluxo REAL de um drop de stack virtual
-- (ex.: Base.Twine, peso 0.5): onMouseUp grava posições + InTransit, o engine
-- absorve todos os transfers individuais no queueList da 1ª ação (checkQueueList),
-- e os GridRenders rodam o ciclo de vida do InTransit a cada frame.
--
-- Reproduz o bug "só 2 itens caem no x,y correto" e valida o fix.
--
-- DETALHE CRÍTICO (descoberto 11/08/2026): o ISTimedActionQueue NÃO tem campo
-- `action`. A ação atual é `queue[1]` e os transfers absorvidos pelo
-- checkQueueList vivem em `queue[1].queueList`. O fix anterior lia
-- `q.action.queueList` — como `q.action` é sempre nil, era CÓDIGO MORTO e o
-- bug persistia no jogo real. Este teste usa a forma REAL da fila
-- (`{ queue = { action1 } }`, sem `.action`) para não dar falso positivo.

local H = require("harness")
H.setName("transfer_sim_test")

-- ── Stubs do ambiente PZ ─────────────────────────────────────────────────────
_G.getPlayerHotbar = function() return nil end
_G.getTimestampMs = function() return 0 end
_G.getSpecificPlayer = function() return nil end
_G.instanceof = function() return false end
_G.ISTimedActionQueue = { getTimedActionQueue = function() return nil end }
_G.Events = { OnGameBoot = { Add = function() end } }

local GridContainer = require("DataModel/GridContainer")
local ScatterLayout = require("Algorithm/ScatterLayout")
ScatterLayout.enabled = false

-- ── Mocks ───────────────────────────────────────────────────────────────────
local function makeItem(id, container)
    local md = { gridX = 3, gridY = 3, gridRot = false, gridContainer = nil, _container = container }
    return {
        _md = md,
        getID = function() return id end,
        getModData = function() return md end,
        getFullType = function() return "Base.Twine" end,
        getWeight = function() return 0.5 end,
        canStack = function() return true end,
        getCount = function() return 1 end,
        isHidden = function() return false end,
        isEquipped = function() return false end,
        getContainer = function() return md._container end,
    }
end

local function makeContainer(type, capacity)
    local items = {}
    return {
        _items = items,
        getItems = function()
            return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
        end,
        getCapacity = function() return capacity end,
        getType = function() return type end,
        getParent = function() return nil end,
        getContainingItem = function() return nil end,
        isInCharacterInventory = function() return false end,
    }
end

-- Estado REAL da fila APÓS o primeiro perform() do engine: a 1ª ação
-- (queue[1]) absorveu todos os demais transfers no queueList e os removeu de
-- queue. Não existe campo `.action` — usar isso no activeTransfers é bug.
local function buildActionQueue(items)
    local action = { item = items[1], queueList = {} }
    for i = 2, #items do
        table.insert(action.queueList, { items = { items[i] }, time = 50, type = "Base.Twine" })
    end
    return { queue = { action } }
end

-- Ciclo de vida do InTransit — CÓPIA literal do GridRender:update() (1940-1953)
local function runInTransitLifecycle(InTransit, activeTransfers, ghosts, now)
    for itemId, info in pairs(InTransit) do
        local item = info and info.item
        local placedHere = info.grid and info.grid.gridCore
            and info.grid.gridCore.items[itemId]
            and not (ghosts and ghosts[itemId])
        local movedAway = item and item.getContainer and info.source
            and item:getContainer() ~= info.source
        local stuck = info.startedAt and (now - info.startedAt > 5000)
            and not activeTransfers[itemId]
        local cancelled = item and item.getContainer and info.source
            and item:getContainer() == info.source
            and not activeTransfers[itemId]

        if placedHere or movedAway or stuck or cancelled then
            if cancelled and info.previousX and info.previousY then
                local md = item:getModData()
                md.gridX = info.previousX
                md.gridY = info.previousY
                md.gridRot = info.previousRot or false
                md.gridContainer = info.previousContainer
            end
            InTransit[itemId] = nil
        end
    end
end

-- Construção do activeTransfers — varre q.queue (e o queueList de cada ação
-- da fila, fix atual). CÓPIA literal do GridRender:update() (1878-1916).
local function buildActiveTransfers(q)
    local active = {}
    if q and q.queue then
        for i = 1, #q.queue do
            local act = q.queue[i]
            if act.item and act.item.getID then
                active[act.item:getID()] = true
            end
            if act.queueList then
                for j = 1, #act.queueList do
                    local entry = act.queueList[j]
                    if entry and entry.items then
                        for k = 1, #entry.items do
                            local it = entry.items[k]
                            if it and it.getID then
                                active[it:getID()] = true
                            end
                        end
                    end
                end
            end
        end
    end
    return active
end

-- Construção do activeTransfers — SÓ os action.item da fila (código anterior
-- ao fix do queueList): os itens absorvidos no queueList ficam invisíveis.
local function buildActiveTransfers_old(q)
    local active = {}
    if q and q.queue then
        for i = 1, #q.queue do
            local act = q.queue[i]
            if act.item and act.item.getID then
                active[act.item:getID()] = true
            end
        end
    end
    return active
end

-- Construção do activeTransfers — fix ERRADO (q.action.queueList): q.action é
-- sempre nil no ISTimedActionQueue real, então o bloco nunca roda. CÓPIA
-- literal do código descommitado que ainda tinha o bug no jogo.
local function buildActiveTransfers_qaction(q)
    local active = {}
    if q then
        if q.action and q.action.item and q.action.item.getID then
            active[q.action.item:getID()] = true
        end
        if q.action and q.action.queueList then
            for i = 1, #q.action.queueList do
                local entry = q.action.queueList[i]
                if entry and entry.items then
                    for j = 1, #entry.items do
                        local it = entry.items[j]
                        if it and it.getID then
                            active[it:getID()] = true
                        end
                    end
                end
            end
        end
        if q.queue then
            for i = 1, #q.queue do
                local act = q.queue[i]
                if act.item and act.item.getID then
                    active[act.item:getID()] = true
                end
            end
        end
    end
    return active
end

-- Monta o cenário completo: 100 Twines empilhados na origem em (3,3).
local function setupScenario()
    local sourceInv = makeContainer("inventorymale", 12)
    -- Alvo = container de MUNDO (caixa), não chão: o chão ignora posição salva
    -- por design (fix do flicker no GridContainer:refresh) — num alvo de chão
    -- nenhum item jamais fica em (5,5) e o teste mediria 0 nas três asserções.
    local targetInv = makeContainer("crate", 90) -- 6x15
    local items = {}
    for i = 1, 100 do
        items[i] = makeItem("t" .. i, sourceInv)
    end
    sourceInv._items = items

    GridContainer.instances = {}
    local srcGC = GridContainer.getOrCreate(sourceInv, 0)
    srcGC:refresh()

    -- onMouseUp (singleStack): grava posição alvo + InTransit p/ todos
    local InTransit = {}
    local targetSig = GridContainer.containerSignature(targetInv)
    local sourceSig = GridContainer.containerSignature(sourceInv)
    for _, item in ipairs(items) do
        local md = item:getModData()
        md.gridX = 5
        md.gridY = 5
        md.gridContainer = targetSig
        InTransit[item:getID()] = {
            startedAt = 0,
            grid = nil,
            source = sourceInv,
            item = item,
            previousX = 3,
            previousY = 3,
            previousRot = false,
            previousContainer = sourceSig,
        }
    end
    return sourceInv, targetInv, srcGC, items, InTransit
end

-- Transferência sequencial (engine): move um item da origem pro alvo.
local function transferOne(sourceInv, targetInv, item)
    for i = 1, #sourceInv._items do
        if sourceInv._items[i] == item then
            table.remove(sourceInv._items, i)
            break
        end
    end
    table.insert(targetInv._items, item)
    item._md._container = targetInv
end

-- Conta quantos itens do alvo ficaram em (5,5) após o fluxo completo.
local function countAtTarget(targetInv, tx, ty)
    local tgtGC = GridContainer.getOrCreate(targetInv, 0)
    tgtGC:refresh()
    local n = 0
    for itemId, data in pairs(tgtGC.grids[1].items) do
        if data.x == tx and data.y == ty then
            n = n + 1
        end
    end
    return n
end

-- Roda o fluxo completo de transferência com uma política de activeTransfers.
local function runFlow(sourceInv, targetInv, srcGC, items, InTransit, buildActive)
    local q = buildActionQueue(items)

    -- Ação 1 (item t1) transfere; depois o engine reseta o action.item pro
    -- próximo da queueList (os demais ficam invisíveis a quem não varre o
    -- queueList — esse é o coração do bug).
    local transferOrder = {}
    for i = 1, 99 do transferOrder[i] = items[i] end
    transferOrder[100] = items[100] -- líder por último

    for idx, item in ipairs(transferOrder) do
        transferOne(sourceInv, targetInv, item)
        srcGC:refresh()

        -- A cada perform o engine avança action.item pro próximo item.
        q.queue[1].item = transferOrder[idx + 1]
        runInTransitLifecycle(InTransit, buildActive(q), nil, 100)
    end
end

-- ── CENÁRIO A: código ANTIGO (só action.item da fila) → bug esperado ────────
do
    local sourceInv, targetInv, srcGC, items, InTransit = setupScenario()
    runFlow(sourceInv, targetInv, srcGC, items, InTransit, buildActiveTransfers_old)
    local atTarget = countAtTarget(targetInv, 5, 5)
    H.ok(atTarget == 2,
        "ANTIGO: só 2 itens ficam em (5,5) [n=" .. atTarget .. "] (bug)")
end

-- ── CENÁRIO B: fix via q.action.queueList (código morto) → bug PERSISTE ─────
do
    local sourceInv, targetInv, srcGC, items, InTransit = setupScenario()
    runFlow(sourceInv, targetInv, srcGC, items, InTransit, buildActiveTransfers_qaction)
    local atTarget = countAtTarget(targetInv, 5, 5)
    H.ok(atTarget == 2,
        "q.action (nil real): bug PERSISTE, 2 itens em (5,5) [n=" .. atTarget .. "]")
end

-- ── CENÁRIO C: fix (activeTransfers varre q.queue[i].queueList) → OK ────────
do
    local sourceInv, targetInv, srcGC, items, InTransit = setupScenario()
    runFlow(sourceInv, targetInv, srcGC, items, InTransit, buildActiveTransfers)
    local atTarget = countAtTarget(targetInv, 5, 5)
    H.ok(atTarget == 100,
        "FIX: os 100 itens ficam em (5,5) [n=" .. atTarget .. "]")
end

H.finish()
