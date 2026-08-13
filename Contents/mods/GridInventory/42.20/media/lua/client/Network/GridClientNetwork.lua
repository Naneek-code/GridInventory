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
local function refreshContainerGrid(container, playerNum)
    if not container then return end
    local gc = GridContainer.getOrCreate(container, playerNum)
    gc:refresh()
    local function markPane(page)
        if page and page.inventoryPane and page.inventoryPane.gridContainerUis then
            for _, g in ipairs(page.inventoryPane.gridContainerUis) do
                if g.inventoryContainer == container then
                    page.inventoryPane.gridRefreshDirty = true
                end
            end
        end
    end
    markPane(getPlayerInventory(playerNum))
    markPane(getPlayerLoot(playerNum))
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

    sendClientCommand(player, GridProtocol.MODULE, GridProtocol.COMMANDS.REQUEST_MOVE, {
        itemId = itemId,
        ref = ref,
        x = tonumber(x),
        y = tonumber(y),
        rotated = rotated and true or false,
        gridContainer = gridContainer,
        manual = manual and true or nil,
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
            GridClientNetwork.applyServerSearch(args.containerKey, args.itemIds)
        end
    end
end

--- Aplica uma revelação confirmada pelo servidor no cache de sessão local.
--- O WIPE branco de descoberta NÃO é repetido aqui: o cliente autor já disparou
--- no markSearched local (antes do envio). O eco só confirma a sessão/persistência.
---@param containerKey string
---@param itemIds table lista de ids revelados
function GridClientNetwork.applyServerSearch(containerKey, itemIds)
    if not containerKey or not itemIds then return end
    local GridInventory_Search = require("System/GridInventory_Search")
    local playerNum = getPlayer() and getPlayer():getPlayerNum() or 0
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

-- Exposição GLOBAL pro shared (padrão do mod, ex.: GridInventory_InTransit):
-- o GridContainer:refresh roda em common/ e usa GridClientNetwork.sendItemMove
-- pra sincronizar os REQUEST_MOVE da consolidação de pilhas. No servidor e nos
-- testes o global não existe → o guard nil do shared simplesmente pula.
GridClientNetwork = GridClientNetwork

return GridClientNetwork
