--- GridServerNetwork.lua
--- O Juiz! É OBRIGATÓRIO no servidor (server-mandatory): o servidor resolve o
--- container, valida a posição (bounds + colisão) e grava a posição
--- autoritativa no modData do item. Broadcasta pros clientes e persiste no save
--- (modData de item é salvo no mundo). Traffic mínimo: 1 comando por drop.

if not isServer() then return end

local GridProtocol = require("Network/GridProtocol")
local GridCore = require("DataModel/GridCore")
local GridContainer = require("DataModel/GridContainer")

local GridServerNetwork = {}

--- Admin check (B42): role/capability. Fail-closed — sem confirmação, não edita.
function GridServerNetwork.isAdmin(player)
    if not player then return false end
    if player.getRole then
        local role = player:getRole()
        if role then
            if role.hasCapability and Capability and Capability.Admin then
                return role:hasCapability(Capability.Admin)
            end
            if role.getName then
                local n = tostring(role:getName() or ""):lower()
                if string.find(n, "admin") then return true end
            end
        end
    end
    if player.getAccessLevel then
        local al = player:getAccessLevel()
        if al and tostring(al):lower() == "admin" then return true end
    end
    return false
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
    if not args or not args.itemId or args.x == nil or args.y == nil then return "invalid" end

    local item = findItem(player, args.ref, args.itemId)
    if not item then return "notfound" end

    -- Itens equipados/vestidos não vivem em grids → ignora.
    if item.isEquipped and item:isEquipped() then return "invalid" end

    local x, y = tonumber(args.x), tonumber(args.y)
    local rotated = args.rotated and true or false

    -- Multi-drag/auto-sort: o servidor apenas LIMPA a posição (auto-fit recalcula).
    if args.clear then
        local md = item:getModData()
        md.gridX = nil
        md.gridY = nil
        md.gridRot = false
        sendServerCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.SYNC_ITEM, {
            itemId = item:getID(),
            clear = true,
            sender = player:getUsername(),
        })
        return "ok"
    end

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

    -- Broadcast pros clientes (incluindo o autor — que ignora o eco).
    sendServerCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.SYNC_ITEM, {
        itemId = item:getID(),
        x = x,
        y = y,
        rotated = rotated,
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
