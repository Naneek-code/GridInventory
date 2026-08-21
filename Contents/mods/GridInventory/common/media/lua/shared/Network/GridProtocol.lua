--- GridProtocol.lua
--- Define os nomes dos comandos de rede e as chaves de ModData.
--- Também implementa a referência de CONTAINER (containerRef): um descritor
--- serializável de um ItemContainer que o cliente envia pro servidor e que o
--- servidor consegue re-resolver (mesmo mundo, mesma API). Usado no fluxo
--- "item → posição no grid" server-mandatory do multiplayer.

local GridProtocol = {}

GridProtocol.MODULE = "GridInventory"

GridProtocol.COMMANDS = {
    REQUEST_MOVE = "ReqMove",       -- Cliente pede para o servidor gravar a posição no grid
    REQUEST_REORDER = "ReqReorder", -- Reorder em LOTE (swap/multi-drag no MESMO grid):
                                    -- todos os alvos num comando; servidor valida o
                                    -- lote junto (movedSet) e aplica all-or-nothing.
    SYNC_ITEM    = "SyncItem",      -- Servidor broadcasta a posição autoritativa pros clientes
    ERROR        = "ErrorMsg",      -- Servidor nega (colisão/cheat) e o cliente reverte
    GET_OVERRIDES = "GetOverrides", -- Cliente pede os overrides do servidor (no join)
    REQ_OVERRIDES = "ReqOverrides", -- Cliente envia overrides editados (admin/devtool)
    SYNC_OVERRIDES = "SyncOverrides", -- Servidor broadcasta os overrides (autoridade)
    CLEAR_HAND   = "ClearHand",     -- Cliente pede pro servidor tirar um item da MÃO (vestir da mão)
    REQ_SEARCH   = "ReqSearch",     -- Cliente revela um item (busca Tarkov) — servidor persiste
    SYNC_SEARCH  = "SyncSearch",    -- Servidor broadcasta a revelação (persistente) pros clientes
}

-- Chaves para salvar coisas no banco de dados do jogo
GridProtocol.MODDATA_KEYS = {
    GLOBAL_WORLD_GRIDS = "GridInventory_WorldGrids", -- (reservado)
    ITEM_POS           = "GridInventory_ItemPos",    -- posição autoritativa server-side (mapa por itemId)
}

-- ============================================================================
-- CONTAINER REF
-- ============================================================================

--- Monta um containerRef serializável a partir de um ItemContainer (lado cliente).
--- O ref identifica ONDE o container mora no mundo, para o servidor re-resolver.
--- `depth` limita a recursão de bolsa-em-bolsa (proteção contra ciclo).
function GridProtocol.buildContainerRef(container, depth)
    if not container then return nil end
    depth = depth or 0

    -- Mochila/bolsa: o container é o inventário de um ITEM. O ref carrega o
    -- containerRef do container PAI (ref.parent) pra o servidor resolver ONDE
    -- a bolsa está (inventário do jogador, chão, armário, veículo ou outra
    -- bolsa) e depois achar a bolsa por itemId dentro do pai.
    local containingItem = container:getContainingItem()
    if containingItem then
        local ref = { type = "item", itemId = containingItem:getID() }
        if depth < GridProtocol.MAX_REF_DEPTH then
            local itemContainer = containingItem.getContainer and containingItem:getContainer()
            ref.parent = GridProtocol.buildContainerRef(itemContainer, depth + 1)
        end
        return ref
    end

    local parent = container:getParent()

    -- Inventário de um jogador
    if parent and instanceof(parent, "IsoPlayer") then
        return { type = "player" }
    end

    -- Bolsa largada no chão (IsoWorldInventoryObject): inclui a square pra o
    -- servidor re-resolvê-la de qualquer square (não só a do jogador).
    if parent and instanceof(parent, "IsoWorldInventoryObject") then
        local it = parent:getItem()
        local ref = { type = "worlditem", itemId = it and it:getID() }
        local sq = parent.getSquare and parent:getSquare()
        if sq and sq.getX then
            ref.x, ref.y, ref.z = sq:getX(), sq:getY(), sq:getZ()
        end
        return ref
    end

    -- Veículo: um veículo tem VÁRIOS containers (porta-malas, luva, bancos).
    -- O `container:getType()` É o id da parte (ex.: "GloveBox", "TruckBed") —
    -- o vanilla resolve via vehicle:getPartById(container:getType()).
    if parent and instanceof(parent, "BaseVehicle") then
        return {
            type = "vehicle",
            vehicleId = parent.getId and parent:getId() or nil,
            containerType = container.getType and container:getType() or nil,
        }
    end

    -- Objeto no mundo (caixa, prateleira, cadáver, etc.)
    if parent and parent.getSquare then
        local sq = parent:getSquare()
        local idx = -1
        if sq and sq.getObjects then
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                if objs:get(i) == parent then idx = i break end
            end
        end
        return {
            type = "object",
            x = sq and sq:getX(), y = sq and sq:getY(), z = sq and sq:getZ(),
            objIndex = idx,
            spriteName = parent.getSprite and parent:getSprite():getName() or nil,
        }
    end

    -- Container de chão virtual (GetFloorContainer)
    if container:getType() == "floor" then
        return { type = "floor" }
    end

    return nil
end

--- Profundidade máxima de aninhamento de containerRef (bolsa em bolsa em bolsa).
GridProtocol.MAX_REF_DEPTH = 8

--- Encontra um item recursivamente dentro de um ItemContainer (e sub-bolsas).
function GridProtocol.findItemInTree(container, itemId)
    if not container or not itemId then return nil end
    if container.getItemWithID then
        local direct = container:getItemWithID(itemId)
        if direct then return direct end
    end
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local child = items:get(i)
        if child.getInventory and child:getInventory() then
            local found = GridProtocol.findItemInTree(child:getInventory(), itemId)
            if found then return found end
        end
    end
    return nil
end

--- Resolve um containerRef de volta para um ItemContainer (lado servidor).
--- contextPlayer = jogador que enviou o comando (para inventários/vezinhaça).
--- `depth` limita a recursão de bolsa-em-bolsa (proteção contra ciclo).
function GridProtocol.resolveContainerRef(ref, contextPlayer, depth)
    if not ref or not ref.type then return nil end
    depth = depth or 0
    local cell = getCell()
    local playerInv = contextPlayer and contextPlayer.getInventory and contextPlayer:getInventory()

    if ref.type == "player" then
        return playerInv
    end

    if ref.type == "floor" then
        -- O container de chão é virtual por jogador (GetFloorContainer). O que
        -- importa pro servidor é a SQUARE do jogador: os itens do chão moram nos
        -- IsoWorldInventoryObject da square. Retornamos nil e deixamos o findItem
        -- varrer a square do jogador (fallback).
        return nil
    end

    if ref.type == "item" then
        -- Bolsa: o ref carrega o containerRef do PAI. Resolve o pai primeiro e
        -- procura a bolsa (itemId) dentro dele — cobre bolsa no inventário do
        -- jogador, no chão, em armário, em veículo ou em outra bolsa.
        if ref.parent and depth < GridProtocol.MAX_REF_DEPTH then
            local parentContainer = GridProtocol.resolveContainerRef(ref.parent, contextPlayer, depth + 1)
            if parentContainer then
                local bag = GridProtocol.findItemInTree(parentContainer, ref.itemId)
                if bag and bag.getInventory then return bag:getInventory() end
            end
        end
        -- Fallback (refs antigos sem .parent): inventário do jogador + square.
        local bag = ref.itemId and playerInv and GridProtocol.findItemInTree(playerInv, ref.itemId)
        if bag and bag.getInventory then return bag:getInventory() end
        local sq
        if ref.x ~= nil and cell then
            sq = cell:getGridSquare(ref.x, ref.y, ref.z)
        end
        if not sq and contextPlayer then
            sq = contextPlayer.getSquare and contextPlayer:getSquare()
        end
        if sq and sq.getObjects and ref.itemId then
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                if o and o.getItem then
                    local oi = o:getItem()
                    if oi and oi.getID and oi:getID() == ref.itemId then
                        local inv = oi.getInventory and oi:getInventory()
                        if inv then return inv end
                    end
                end
            end
        end
        return nil
    end

    if ref.type == "worlditem" then
        -- Bolsa no chão: mesmo fallback do tipo "item" (procura na square).
        local sq
        if ref.x ~= nil and cell then
            sq = cell:getGridSquare(ref.x, ref.y, ref.z)
        end
        if not sq and contextPlayer then
            sq = contextPlayer.getSquare and contextPlayer:getSquare()
        end
        if sq and sq.getObjects and ref.itemId then
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local o = objs:get(i)
                if o and o.getItem then
                    local oi = o:getItem()
                    if oi and oi.getID and oi:getID() == ref.itemId then
                        local inv = oi.getInventory and oi:getInventory()
                        if inv then return inv end
                    end
                end
            end
        end
        return nil
    end

    if ref.type == "object" then
        local sq = cell and cell:getGridSquare(ref.x, ref.y, ref.z)
        if not sq then return nil end
        local obj = nil
        if ref.objIndex and ref.objIndex >= 0 and sq.getObjects and ref.objIndex < sq:getObjects():size() then
            obj = sq:getObjects():get(ref.objIndex)
        end
        if not obj and ref.spriteName then
            local objs = sq:getObjects()
            for i = 0, objs:size() - 1 do
                local c = objs:get(i)
                if c.getSprite and c:getSprite() and c:getSprite():getName() == ref.spriteName then
                    obj = c
                    break
                end
            end
        end
        if obj then
            -- Cadáver (IsoDeadBody): o inventário é via getInventory(), não
            -- getContainer() (mesmo padrão do GridContainer.getGridSize/refresh).
            if instanceof and instanceof(obj, "IsoDeadBody") then
                if obj.getInventory then return obj:getInventory() end
                return nil
            end
            if obj.getContainer then
                return obj:getContainer()
            end
        end
        return nil
    end

    if ref.type == "vehicle" then
        -- B42: API vanilla (ISTransferAction): container:getParent() é o
        -- BaseVehicle e o container:getType() é o id da parte — resolve com
        -- vehicle:getPartById(containerType):getItemContainer().
        local veh
        if ref.vehicleId then
            veh = getVehicleById and getVehicleById(ref.vehicleId)
        end
        if not veh and ref.keyId then
            veh = getVehicleByKeyId and getVehicleByKeyId(ref.keyId)
        end
        if not veh then return nil end
        if ref.containerType and veh.getPartById then
            local part = veh:getPartById(ref.containerType)
            if part and part.getItemContainer then
                local inv = part:getItemContainer()
                if inv then return inv end
            end
        end
        return nil
    end

    return nil
end

return GridProtocol
