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
function GridProtocol.buildContainerRef(container)
    if not container then return nil end

    -- Mochila/bolsa: o container é o inventário de um ITEM
    local containingItem = container:getContainingItem()
    if containingItem then
        return { type = "item", itemId = containingItem:getID() }
    end

    local parent = container:getParent()

    -- Inventário de um jogador
    if parent and instanceof(parent, "IsoPlayer") then
        return { type = "player" }
    end

    -- Bolsa largada no chão (IsoWorldInventoryObject)
    if parent and instanceof(parent, "IsoWorldInventoryObject") then
        local it = parent:getItem()
        return { type = "worlditem", itemId = it and it:getID() }
    end

    -- Veículo
    if parent and instanceof(parent, "BaseVehicle") then
        return { type = "vehicle", keyId = parent:getKeyId() }
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
function GridProtocol.resolveContainerRef(ref, contextPlayer)
    if not ref or not ref.type then return nil end
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
        local bag = ref.itemId and playerInv and GridProtocol.findItemInTree(playerInv, ref.itemId)
        return bag and bag:getInventory()
    end

    if ref.type == "worlditem" then
        -- Bolsa no chão: procura pelo item na square do jogador (fallback cobre).
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
        if obj and obj.getContainer then
            return obj:getContainer()
        end
        return nil
    end

    if ref.type == "vehicle" then
        -- B42: resolução de veículo por keyId via getVehicleByKeyId (se disponível).
        local veh = ref.keyId and getVehicleByKeyId and getVehicleByKeyId(ref.keyId)
        return veh and veh.getContainer and veh:getContainer() or nil
    end

    return nil
end

return GridProtocol
