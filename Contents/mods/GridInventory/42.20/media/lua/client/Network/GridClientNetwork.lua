--- GridClientNetwork.lua
--- Lado cliente do sync de posições server-mandatory:
---  - envia REQUEST_MOVE quando o jogador solta um item num grid (com as coords x,y);
---  - aplica SYNC_ITEM broadcastado pelo servidor (posição autoritativa de outros
---    jogadores / confirmação de volta);
---  - reverte a posição local se o servidor negar (ERROR: colisão/cheat).

local GridProtocol = require("Network/GridProtocol")
local GridContainer = require("DataModel/GridContainer")

local GridClientNetwork = {}

--- Encontra um item por ID nos containers que este cliente conhece:
--- inventário do jogador + containers dos grids abertos (inv e loot).
local function findItemRecursive(container, itemId)
    if not container or not itemId then return nil end
    if container.getItemWithID then
        local direct = container:getItemWithID(itemId)
        if direct then return direct end
    end
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local child = items:get(i)
        if child.getInventory and child:getInventory() then
            local found = findItemRecursive(child:getInventory(), itemId)
            if found then return found end
        end
    end
    return nil
end

local function getKnownContainers(playerNum)
    local seen = {}
    local list = {}
    local function add(container)
        if container and not seen[container] then
            seen[container] = true
            table.insert(list, container)
        end
    end
    local function addPane(pane)
        if pane and pane.gridContainerUis then
            for _, gridUi in ipairs(pane.gridContainerUis) do
                if gridUi.inventoryContainer then
                    add(gridUi.inventoryContainer)
                end
            end
        end
    end
    local pInv = getPlayerInventory(playerNum)
    local pLoot = getPlayerLoot(playerNum)
    addPane(pInv and pInv.inventoryPane)
    addPane(pLoot and pLoot.inventoryPane)
    return list
end

function GridClientNetwork.findItem(itemId)
    local player = getPlayer()
    if not player then return nil end
    local playerNum = player:getPlayerNum()

    local item = findItemRecursive(player:getInventory(), itemId)
    if item then return item end

    for _, container in ipairs(getKnownContainers(playerNum)) do
        item = findItemRecursive(container, itemId)
        if item then return item end
    end
    return nil
end

--- Re-renderiza o grid do container (e marca o pane pra rebuild de overflow).
--- COM DEBOUNCE: N mensagens SYNC_ITEM no mesmo instante (ex.: consolidação de
--- uma pilha inteira, ou vários jogadores looteando o mesmo container) agora
--- acumulam os containers pendentes e fazem UM refresh() por janela de
--- REFRESH_DEBOUNCE_MS — antes era 1 refresh() (remap O(n*W*H)) POR mensagem.
--- Os modData são gravados na hora em applyItemPosition (persistência intacta);
--- só o re-layout do cliente é adiado ~1 frame, imperceptível.
local REFRESH_DEBOUNCE_MS = 50
local _pendingRefreshes = {}   -- [container] = playerNum
local _pendingCount = 0        -- contador espelho (o PZ42/Kahlua não tem next())
local _lastRefreshRun = 0

local function flushPendingRefreshes(force)
    -- Short-circuit ANTES do getTimestampMs() (Java): sem pendências, o OnTick
    -- não precisa gastar nem a chamada de relógio a cada frame.
    if not force and _pendingCount == 0 then return end
    local now = getTimestampMs()
    if not force and now - _lastRefreshRun < REFRESH_DEBOUNCE_MS then
        return
    end
    if _pendingCount == 0 then
        _lastRefreshRun = now
        return
    end

    local function markPane(page, container)
        if page and page.inventoryPane and page.inventoryPane.gridContainerUis then
            for _, g in ipairs(page.inventoryPane.gridContainerUis) do
                if g.inventoryContainer == container then
                    page.inventoryPane.gridRefreshDirty = true
                end
            end
        end
    end

    for container, playerNum in pairs(_pendingRefreshes) do
        _pendingRefreshes[container] = nil
        _pendingCount = _pendingCount - 1
        local gc = GridContainer.getOrCreate(container, playerNum)
        gc:refresh()
        if GridInventory_Profiler and GridInventory_Profiler.enabled then
            GridInventory_Profiler.count("reflows")
        end
        markPane(getPlayerInventory(playerNum), container)
        markPane(getPlayerLoot(playerNum), container)
    end
    _lastRefreshRun = now
end

local function refreshContainerGrid(container, playerNum)
    if not container then return end
    if not _pendingRefreshes[container] then
        _pendingCount = _pendingCount + 1
    end
    _pendingRefreshes[container] = playerNum
    flushPendingRefreshes(false)
end

--- Marca um container pra re-render (gc:refresh + markPane), sem depender de
--- eco de rede. Usado pelo reorder no MESMO grid: em SP o sendItemMove retorna
--- cedo (não é client) e o poll 300ms não detecta (hash de itens não muda —
--- reorder só mexe em modData). Sem esse toque, o OverflowGridRender (snapshot)
--- fica stale até um rebuild forçado (trocar de container).
function GridClientNetwork.markGridChanged(container, playerNum)
    refreshContainerGrid(container, playerNum)
end

--- Exposto pro teste: força o flush dos refreshes pendentes.
function GridClientNetwork.flushPendingRefreshes()
    flushPendingRefreshes(true)
end

--- Tick: escoa o lote pendente final sem forçar (só roda se o debounce já
--- venceu) — cobre o caso de a última mensagem ter ficado pendente.
function GridClientNetwork.tickFlush()
    flushPendingRefreshes(false)
end

--- Envia a posição de um item no grid pro servidor (server-mandatory).
--- @param container ItemContainer container ALVO (o grid onde soltou)
--- @param itemId number|string
--- @param x number coordenada 1-indexada
--- @param y number
--- @param rotated boolean
--- @param gridContainer string|nil assinatura do container (valida a posição salva)
--- @param manual boolean|nil true se foi o jogador que escolheu a célula
---        (consolidação de pilhas nunca move itens manuais)
function GridClientNetwork.sendItemMove(container, itemId, x, y, rotated, gridContainer, manual)
    if not isClient() then return end
    local player = getPlayer()
    if not player or not container or itemId == nil then return end

    local ref = GridProtocol.buildContainerRef(container)
    if not ref then return end

    -- Origem (container atual do item): o servidor pode precisar encontrar o
    -- item AINDA na origem (a transferência física pode não ter completado).
    -- Sem isso, o REQUEST_MOVE ia pra fila de pendências, o item chegava ao
    -- destino SEM posição e era auto-posicionado em (1,1) (deslocando o item
    -- que já estava lá) até a posição (x,y) sincronizar.
    local sourceRef = nil
    local it = GridClientNetwork.findItem(itemId)
    if it and it.getContainer then
        local src = it:getContainer()
        if src then
            sourceRef = GridProtocol.buildContainerRef(src)
        end
    end

    sendClientCommand(player, GridProtocol.MODULE, GridProtocol.COMMANDS.REQUEST_MOVE, {
        itemId = itemId,
        ref = ref,
        sourceRef = sourceRef,
        x = tonumber(x),
        y = tonumber(y),
        rotated = rotated and true or false,
        gridContainer = gridContainer,
        manual = manual and true or nil,
    })
end

--- Envia um REORDER em LOTE pro servidor (swap/multi-drag no MESMO grid).
--- O drop no mesmo grid valida os alvos no cliente com movedSet (todos os itens
--- "saindo" juntos — A→célula de B é ok porque B também vai sair). Enviar um
--- REQUEST_MOVE por item faz o servidor validar CADA um isoladamente contra o
--- modData atual (B ainda na posição antiga) → ERROR → item volta pra posição
--- anterior (bug do MP). Este comando entrega TODOS os alvos de uma vez: o
--- servidor valida o lote junto (mesmo movedSet) e aplica all-or-nothing.
--- @param container ItemContainer container ALVO (o grid onde soltou)
--- @param targets table lista do GridReorder.computeTargets ({item, tx, ty, ew, eh})
--- @param gridContainer string|nil assinatura do container (valida a posição salva)
function GridClientNetwork.sendReorder(container, targets, gridContainer)
    if not isClient() then return end
    local player = getPlayer()
    if not player or not container or not targets or #targets == 0 then return end

    local ref = GridProtocol.buildContainerRef(container)
    if not ref then return end

    local moves = {}
    for _, t in ipairs(targets) do
        if t.item and t.item.itemObj and t.item.itemObj.getID then
            table.insert(moves, {
                itemId = t.item.itemObj:getID(),
                x = tonumber(t.tx),
                y = tonumber(t.ty),
                rotated = (t.item.rotated or false),
            })
        end
    end
    if #moves == 0 then return end

    sendClientCommand(player, GridProtocol.MODULE, GridProtocol.COMMANDS.REQUEST_REORDER, {
        ref = ref,
        gridContainer = gridContainer,
        manual = true, -- reorder = o jogador escolheu a célula (gridManual)
        moves = moves,
    })
end

--- Pede pro servidor LIMPAR a posição do item (multi-drag/auto-sort: a posição
--- será recalculada automaticamente; evita posição antiga fantasma no MP).
function GridClientNetwork.clearServerPosition(container, itemId)
    if not isClient() then return end
    local player = getPlayer()
    if not player or not container or itemId == nil then return end

    local ref = GridProtocol.buildContainerRef(container)
    if not ref then return end

    sendClientCommand(player, GridProtocol.MODULE, GridProtocol.COMMANDS.REQUEST_MOVE, {
        itemId = itemId,
        ref = ref,
        clear = true,
    })
end

--- Pede pro servidor TIRAR um item da MÃO do jogador (vestir item segurado).
--- O vanilla não sincroniza a mão vazia no MP (setPrimaryHandItem(nil) só
--- broadcasta no servidor); sem isso a mochila vestida continua na mão no 3D.
function GridClientNetwork.clearHandItem(itemId)
    if not isClient() then return end
    local player = getPlayer()
    if not player or itemId == nil then return end
    sendClientCommand(player, GridProtocol.MODULE, GridProtocol.COMMANDS.CLEAR_HAND, {
        itemId = itemId,
    })
end

--- Envia os overrides editados pro servidor (admin/devtool) — autoridade final.
function GridClientNetwork.sendOverrides(overrides)
    if not isClient() then return end
    local player = getPlayer()
    if not player or not overrides then return end
    sendClientCommand(player, GridProtocol.MODULE, GridProtocol.COMMANDS.REQ_OVERRIDES, {
        overrides = overrides,
    })
end

--- Pede os overrides do servidor (join): o servidor é a fonte da verdade.
function GridClientNetwork.requestOverrides()
    if not isClient() then return end
    local player = getPlayer()
    if not player then return end
    sendClientCommand(player, GridProtocol.MODULE, GridProtocol.COMMANDS.GET_OVERRIDES, {})
end

-- No início do jogo, pede os overrides do servidor (com um pequeno atraso para
-- garantir que o jogador local já existe para o sendClientCommand). Só em MP.
local overridesRequested = false
Events.OnGameStart.Add(function()
    if overridesRequested or not isClient() then return end
    overridesRequested = true
    local done = false
    Events.OnTick.Add(function()
        if not done and getPlayer() then
            done = true
            GridClientNetwork.requestOverrides()
        end
    end)
end)

--- Aplica os overrides vindos do servidor (broadcast) e recarrega os grids.
local function applyServerOverrides(overrides)
    if not GridDevTool then
        require("DevTool/GridOverrides")
    end
    if GridDevTool and GridDevTool.replaceOverrides then
        GridDevTool.replaceOverrides(overrides)
        local playerNum = getPlayer() and getPlayer():getPlayerNum() or 0
        local pInv = getPlayerInventory(playerNum)
        local pLoot = getPlayerLoot(playerNum)
        if pInv and pInv.inventoryPane then pInv.inventoryPane:refreshContainer() end
        if pLoot and pLoot.inventoryPane then pLoot.inventoryPane:refreshContainer() end
    end
end

--- Aplica a posição autoritativa vinda do servidor num item local.
function GridClientNetwork.applyItemPosition(itemId, x, y, rotated, gridContainer, manual)
    local item = GridClientNetwork.findItem(itemId)
    if not item then return end
    local md = item:getModData()
    md.gridX = tonumber(x)
    md.gridY = tonumber(y)
    md.gridRot = rotated and true or false
    if gridContainer ~= nil then
        md.gridContainer = gridContainer
    end
    md.gridManual = manual and true or nil
    if item.getContainer then
        refreshContainerGrid(item:getContainer(), getPlayer() and getPlayer():getPlayerNum() or 0)
    end
end

--- Remove a posição local de um item (usado na reversão de ERROR).
function GridClientNetwork.clearItemPosition(itemId)
    local item = GridClientNetwork.findItem(itemId)
    if not item then return end
    local md = item:getModData()
    md.gridX = nil
    md.gridY = nil
    md.gridRot = false
    md.gridContainer = nil
    if item.getContainer then
        refreshContainerGrid(item:getContainer(), getPlayer() and getPlayer():getPlayerNum() or 0)
    end
end

--- Recebe os broadcast/erros do Servidor.
local function OnServerCommand(module, command, args)
    if module ~= GridProtocol.MODULE then return end
    local player = getPlayer()
    if not player then return end

    if command == GridProtocol.COMMANDS.SYNC_ITEM then
        if GridInventory_Profiler and GridInventory_Profiler.enabled then
            GridInventory_Profiler.count("syncItems")
        end
        -- NÃO ignora o eco do próprio envio: o modData local pode ser
        -- sobrescrito pelo sync do container (com a posição ainda vazia)
        -- enquanto o REQUEST_MOVE está pendente no servidor. Aplicar o eco
        -- garante que o render final sempre casa com a posição autoritativa.
        if args.clear then
            GridClientNetwork.clearItemPosition(args.itemId)
        else
            GridClientNetwork.applyItemPosition(args.itemId, args.x, args.y, args.rotated, args.gridContainer, args.manual)
        end

    elseif command == GridProtocol.COMMANDS.ERROR then
        -- Servidor negou (colisão/cheat): reverte pra posição anterior (auto-fit).
        GridClientNetwork.clearItemPosition(args.itemId)

    elseif command == GridProtocol.COMMANDS.SYNC_OVERRIDES then
        -- Overrides do servidor (autoridade): aplica e recarrega grids.
        applyServerOverrides(args.overrides)

    elseif command == GridProtocol.COMMANDS.SYNC_SEARCH then
        -- Servidor confirmou/persistiu a revelação de itens (busca Tarkov).
        -- Aplica localmente no cache de sessão (o modData do jogador já vem
        -- do servidor). O eco do próprio envio também passa por aqui.
        if args and args.containerKey and args.itemIds then
            GridClientNetwork.applyServerSearch(args.containerKey, args.itemIds, args.sender)
        end
    end
end

--- Aplica uma revelação confirmada pelo servidor no cache de sessão local.
--- O WIPE branco de descoberta NÃO é repetido aqui: o cliente autor já disparou
--- no markSearched local (antes do envio). O eco só confirma a sessão/persistência.
--- A revelação é POR JOGADOR (modData do jogador que vasculhou): o servidor
--- broadcasta SYNC_SEARCH pra todos, mas cada cliente só aplica o eco do PRÓPRIO
--- jogador — a busca de outro jogador NÃO te revela os itens (senão 1 jogador
--- vasculhando liberava o container pra todos no coop).
---@param containerKey string
---@param itemIds table lista de ids revelados
---@param sender string|nil username do jogador que vasculhou (do broadcast)
function GridClientNetwork.applyServerSearch(containerKey, itemIds, sender)
    if not containerKey or not itemIds then return end
    local me = getPlayer()
    if sender and me and me.getUsername then
        -- Filtra pelo autor: só aplica se o broadcast for do próprio jogador.
        if tostring(sender) ~= tostring(me:getUsername()) then return end
    end
    local GridInventory_Search = require("System/GridInventory_Search")
    local playerNum = me and me.getPlayerNum and me:getPlayerNum() or 0
    for _, id in ipairs(itemIds) do
        GridInventory_Search.markSearchedSession(playerNum, containerKey, id, true)
    end
    -- re-renderiza os grids afetados
    local pInv = getPlayerInventory(playerNum)
    local pLoot = getPlayerLoot(playerNum)
    if pInv and pInv.inventoryPane then pInv.inventoryPane.gridRefreshDirty = true end
    if pLoot and pLoot.inventoryPane then pLoot.inventoryPane.gridRefreshDirty = true end
end

--- Envia pro servidor a revelação de itens (busca Tarkov): o servidor persiste
--- no modData do jogador e broadcasta — persistência real no MP.
---@param containerKey string
---@param itemIds table lista de ids revelados
function GridClientNetwork.sendSearchReveal(containerKey, itemIds)
    if not isClient() then return end
    local player = getPlayer()
    if not player or not containerKey or not itemIds or #itemIds == 0 then return end
    sendClientCommand(player, GridProtocol.MODULE, GridProtocol.COMMANDS.REQ_SEARCH, {
        containerKey = containerKey,
        itemIds = itemIds,
    })
end

Events.OnServerCommand.Add(OnServerCommand)

-- Garante o flush do debounce mesmo que parem de chegar mensagens (o lote
-- final pendente escoa no próximo tick em vez de ficar preso).
local tickFlushFn = GridClientNetwork.tickFlush
Events.OnTick.Add(function()
    tickFlushFn()
end)

-- Exposição GLOBAL pro shared (padrão do mod, ex.: GridInventory_InTransit):
-- o GridContainer:refresh roda em common/ e usa GridClientNetwork.sendItemMove
-- pra sincronizar os REQUEST_MOVE da consolidação de pilhas. No servidor e nos
-- testes o global não existe → o guard nil do shared simplesmente pula.
GridClientNetwork = GridClientNetwork

return GridClientNetwork
