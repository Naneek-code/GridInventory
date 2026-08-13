--- GridServerNetwork.lua
--- O Juiz! É OBRIGATÓRIO no servidor (server-mandatory): o servidor resolve o
--- container, valida a posição (bounds + colisão) e grava a posição
--- autoritativa no modData do item. Broadcasta pros clientes e persiste no save
--- (modData de item é salvo no mundo). Traffic mínimo: 1 comando por drop.

if not isServer() then return end

local GridProtocol = require("Network/GridProtocol")
local GridCore = require("DataModel/GridCore")
local GridContainer = require("DataModel/GridContainer")
local GridAdmin = require("System/GridAdmin")

local GridServerNetwork = {}

--- Admin check (B42): role/capability. Fail-closed — sem confirmação, não edita.
function GridServerNetwork.isAdmin(player)
    return GridAdmin.isAdmin(player)
end

-- Fila de pendências: movimentos que chegaram antes do transfer terminar no
-- servidor. Retry curto e bounded para não virar monstro no servidor.
local pendingMoves = {}
local PENDING_RETRIES = 30   -- ~30 ticks
local PENDING_DELAY_MS = 100

--- Encontra o item onde quer que ele esteja acessível ao jogador:
--- 1. árvore do inventário do jogador (cobre reorganizar e loot→inv);
--- 2. container resolvido pelo ref (caixas, prateleiras, bolsas);
--- 3. fallback bounded: square atual do jogador (chão + objetos + cadáveres).
local function findItem(player, ref, itemId)
    local item = GridProtocol.findItemInTree(player:getInventory(), itemId)
    if item then return item end

    local container = GridProtocol.resolveContainerRef(ref, player)
    if container then
        item = GridProtocol.findItemInTree(container, itemId)
        if item then return item end
    end

    local sq = player:getSquare()
    if sq and sq.getObjects then
        local objs = sq:getObjects()
        for i = 0, objs:size() - 1 do
            local obj = objs:get(i)
            if obj and obj.getItem and obj:getItem() and obj:getItem():getID() == itemId then
                return obj:getItem()
            end
            if obj and obj.getContainer and obj:getContainer() then
                item = GridProtocol.findItemInTree(obj:getContainer(), itemId)
                if item then return item end
            end
        end
    end
    return nil
end

--- Executa um movimento. Retorna "ok" | "notfound" | "invalid".
local function processMove(player, args)
    if not args or not args.itemId then return "invalid" end

    local item = findItem(player, args.ref, args.itemId)
    if not item then return "notfound" end

    -- Itens equipados/vestidos não vivem em grids → ignora.
    if item.isEquipped and item:isEquipped() then return "invalid" end

    -- Multi-drag/auto-sort: o servidor apenas LIMPA a posição (auto-fit recalcula).
    -- O clear NÃO manda x/y — por isso vem ANTES da checagem de coordenadas.
    if args.clear then
        local md = item:getModData()
        md.gridX = nil
        md.gridY = nil
        md.gridRot = false
        md.gridContainer = nil
        sendServerCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.SYNC_ITEM, {
            itemId = item:getID(),
            clear = true,
            sender = player:getUsername(),
        })
        return "ok"
    end

    if args.x == nil or args.y == nil then return "invalid" end

    local x, y = tonumber(args.x), tonumber(args.y)
    local rotated = args.rotated and true or false

    -- VALIDAÇÃO AUTORITATIVA contra o container ALVO (resolvido do ref), não o
    -- container atual do item — que ainda pode ser a origem durante o transfer
    -- (ex.: inv→chão valida na grid do chão, não na do inventário 3x4).
    local valid = false
    if args.ref and args.ref.type == "floor" then
        valid = GridContainer.validateFloorPlacement(item, x, y, rotated)
    else
        local target = GridProtocol.resolveContainerRef(args.ref, player)
        if not target then
            target = item.getContainer and item:getContainer()
        end
        valid = target and GridContainer.validatePlacement(target, item, x, y, rotated) or false
    end

    if not valid then
        sendServerCommand(player, GridProtocol.MODULE, GridProtocol.COMMANDS.ERROR, {
            itemId = item:getID(),
        })
        return "invalid"
    end

    local md = item:getModData()
    md.gridX = x
    md.gridY = y
    md.gridRot = rotated
    if args.gridContainer ~= nil then
        md.gridContainer = args.gridContainer
    end
    -- Posição MANUAL (jogador escolheu a célula): a consolidação de pilhas do
    -- cliente nunca move itens manuais — persiste no modData (server-mandatory).
    if args.manual ~= nil then
        md.gridManual = args.manual and true or nil
    end

    -- Broadcast pros clientes (incluindo o autor — que ignora o eco).
    sendServerCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.SYNC_ITEM, {
        itemId = item:getID(),
        x = x,
        y = y,
        rotated = rotated,
        gridContainer = md.gridContainer,
        manual = md.gridManual,
        sender = player:getUsername(),
    })
    return "ok"
end

local function OnClientCommand(module, command, player, args)
    if module ~= GridProtocol.MODULE then return end
    if not player then return end

    -- Overrides do DevTool: cliente (admin) PEDE ou ENVIA os overrides.
    if command == GridProtocol.COMMANDS.GET_OVERRIDES then
        if GridDevTool and GridDevTool.Overrides then
            sendServerCommand(player, GridProtocol.MODULE, GridProtocol.COMMANDS.SYNC_OVERRIDES, {
                overrides = GridDevTool.Overrides,
            })
        end
        return
    end

    if command == GridProtocol.COMMANDS.REQ_OVERRIDES then
        -- SEGURANÇA: só ADMIN pode alterar os overrides do servidor. O cliente
        -- pode até forjar o comando; o servidor decide (fail-closed).
        if not GridServerNetwork.isAdmin(player) then return end
        if GridDevTool and args and args.overrides then
            GridDevTool.replaceOverrides(args.overrides)
            -- Broadcasta a versão sanitizada pro servidor inteiro (autoridade).
            sendServerCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.SYNC_OVERRIDES, {
                overrides = GridDevTool.Overrides,
                sender = player:getUsername(),
            })
        end
        return
    end

    -- Cliente vestiu um item que estava NA MÃO: o vanilla não sincroniza a mão
    -- vazia (setPrimaryHandItem(nil) só broadcasta no servidor). O servidor é
    -- autoridade — tira o item da mão aqui e broadcasta (Equip), senão todos os
    -- clientes continuam renderizando a mochila na mão após vestir.
    if command == GridProtocol.COMMANDS.CLEAR_HAND then
        if args and args.itemId then
            local primary = player.getPrimaryHandItem and player:getPrimaryHandItem()
            local secondary = player.getSecondaryHandItem and player:getSecondaryHandItem()
            local cleared = false
            if primary and primary:getID() == args.itemId then
                player:removeFromHands(primary)
                cleared = true
            elseif secondary and secondary:getID() == args.itemId then
                player:removeFromHands(secondary)
                cleared = true
            end
            if cleared and sendEquip then
                sendEquip(player)
            end
        end
        return
    end

    -- Busca Tarkov: o cliente revelou itens de um container. O servidor é a
    -- fonte da verdade — grava no modData do JOGADOR (persiste no save, por
    -- jogador) e broadcasta pros clientes. Sem isso, no MP o estado morria no
    -- cliente e ao relogar tudo precisava ser vasculhado de novo.
    -- O estado é POR ITEM (itemId -> true, plano): mover um item revelado de
    -- um container pra outro NÃO o esconde de novo. Formato antigo
    -- (container -> {itens}) é migrado na primeira gravação.
    if command == GridProtocol.COMMANDS.REQ_SEARCH then
        if args and args.itemIds then
            local md = player.getModData and player:getModData()
            if md then
                local root = md["GridInventory_Searched"]
                if not root then root = {} md["GridInventory_Searched"] = root end
                -- Migra formato antigo (chave com valor tabela = containerKey).
                local oldFormat = false
                for _, v in pairs(root) do
                    if type(v) == "table" then oldFormat = true break end
                end
                if oldFormat then
                    local flat = {}
                    for k, v in pairs(root) do
                        if type(v) == "table" then
                            for id in pairs(v) do flat[tostring(id)] = true end
                        else
                            flat[k] = true
                        end
                    end
                    for k in pairs(root) do root[k] = nil end
                    for id in pairs(flat) do root[id] = true end
                end
                for _, id in ipairs(args.itemIds) do
                    root[tostring(id)] = true
                end
                -- Broadcast (incluindo o autor — que ignora o eco local).
                sendServerCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.SYNC_SEARCH, {
                    containerKey = args.containerKey,
                    itemIds = args.itemIds,
                    sender = player:getUsername(),
                })
            end
        end
        return
    end

    if command ~= GridProtocol.COMMANDS.REQUEST_MOVE then return end

    local status = processMove(player, args)
    if status == "notfound" then
        -- Item ainda em trânsito (transfer não terminou no servidor): enfileira.
        local pending = pendingMoves[player] or {}
        pending[args.itemId] = {
            args = args,
            player = player,
            retries = 0,
            lastTry = getTimestampMs(),
        }
        pendingMoves[player] = pending
    end
end

Events.OnClientCommand.Add(OnClientCommand)

Events.OnTick.Add(function()
    local now = getTimestampMs()
    for player, pending in pairs(pendingMoves) do
        for itemId, p in pairs(pending) do
            if now - (p.lastTry or 0) >= PENDING_DELAY_MS then
                p.lastTry = now
                p.retries = p.retries + 1
                local status = processMove(p.player, p.args)
                if status ~= "notfound" then
                    pending[itemId] = nil
                elseif p.retries >= PENDING_RETRIES then
                    pending[itemId] = nil
                end
            end
        end
        local count = 0
        for _ in pairs(pending) do count = count + 1 end
        if count == 0 then
            pendingMoves[player] = nil
        end
    end
end)

return GridServerNetwork
