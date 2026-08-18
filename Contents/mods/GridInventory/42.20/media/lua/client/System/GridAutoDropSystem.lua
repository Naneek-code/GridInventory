--- GridAutoDropSystem.lua
--- Sistema que vigia o jogador e, quando ele não estiver fazendo nenhuma ação,
--- joga todos os itens do "overflow" (unpositioned) no chão para evitar guardar itens invisíveis.

local GridContainer = require("DataModel/GridContainer")
local ItemFootprint = require("Algorithm/ItemFootprint")
require "TimedActions/ISTimedActionQueue"
require "TimedActions/ISInventoryTransferAction"

local GridAutoDropSystem = {}

local function getAllEquippedContainers(playerObj)
    local containers = {}
    table.insert(containers, playerObj:getInventory())
    local wornItems = playerObj:getWornItems()
    for i = 0, wornItems:size()-1 do
        local wornItem = wornItems:get(i):getItem()
        if wornItem:IsInventoryContainer() then
            table.insert(containers, wornItem:getInventory())
        end
    end
    return containers
end

local function canItemFitInContainer(item, invContainer, playerNum)
    local gridContainer = GridContainer.instances[invContainer]
    if not gridContainer then return false end
    
    local playerObj = getSpecificPlayer(playerNum)
    if not invContainer:hasRoomFor(playerObj, item) then
        return false
    end
    
    local w, h = ItemFootprint.getSize(item)
    local compatKey, stackInfo = GridContainer.getStackInfo(item)
    for _, grid in ipairs(gridContainer.grids) do
        local fx, fy = grid:findFreeSpace(item:getID(), w, h, compatKey, stackInfo, false)
        if not fx then
            fx, fy = grid:findFreeSpace(item:getID(), h, w, compatKey, stackInfo, true)
        end
        if fx and fy then return true end
    end
    return false
end

-- Hash barato: se a CONTAGEM de itens não mudou desde a última checagem,
-- assume-se que o conteúdo não mudou (o caso comum) e evita varrer os IDs
-- de todos os itens a cada tick. Retorna nil quando nada precisa refrescar.
local function getInventoryHash(inv, gridContainer)
    local items = inv:getItems()
    local size = items:size()
    if gridContainer.lastAutoDropSize == size then
        return nil
    end
    gridContainer.lastAutoDropSize = size
    local hash = 0
    for i=0, size-1 do
        hash = hash + items:get(i):getID()
    end
    return tostring(size) .. "_" .. tostring(hash)
end

-- Throttle de tempo: a varredura (hash de todos os containers equipados) só
-- roda a cada 300ms, nunca a cada tick. O OnTick continua sendo o gatilho,
-- mas o trabalho caro fica limitado no tempo.
local CHECK_INTERVAL_MS = 300
local _lastCheck = 0

-- Função compartilhada (sem closure): a transferência de auto-drop do chão é
-- sempre válida. Evita alocar uma closure nova por item jogado no chão.
local function floorTransferAlwaysValid()
    return true
end

function GridAutoDropSystem.OnTick()
    local now = getTimestampMs()
    if now - _lastCheck < CHECK_INTERVAL_MS then return end
    _lastCheck = now

    local playerNum = 0 -- Suporte apenas local multiplayer 0 por enquanto
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or playerObj:isDead() then return end

    local actionQueueObj = ISTimedActionQueue.getTimedActionQueue(playerObj)
    local isIdle = not actionQueueObj or (not actionQueueObj.action and (not actionQueueObj.queue or #actionQueueObj.queue == 0))

    if isIdle then
        local containers = getAllEquippedContainers(playerObj)
        local allUnpositioned = {}
        
        -- Coleta TODOS os unpositioned de TODAS as mochilas
        for _, inv in ipairs(containers) do
            local gridContainer = GridContainer.instances[inv] or GridContainer.getOrCreate(inv, playerNum)
            
            local currentHash = getInventoryHash(inv, gridContainer)
            if currentHash and currentHash ~= gridContainer.lastAutoDropHash then
                gridContainer.lastAutoDropHash = currentHash
                gridContainer:refresh()
            end
            
            if gridContainer and gridContainer.unpositioned and #gridContainer.unpositioned > 0 then
                for _, item in ipairs(gridContainer.unpositioned) do
                    table.insert(allUnpositioned, {item = item, sourceInv = inv})
                end
                -- Limpa a lista local
                gridContainer.unpositioned = {}
            end
        end
        
        if #allUnpositioned > 0 then
            local floorContainer = ISInventoryPage.GetFloorContainer(playerNum)
            if not floorContainer then return end
            
            for _, data in ipairs(allUnpositioned) do
                local item = data.item
                local sourceInv = data.sourceInv
                local handled = false
                
                -- Se o item não está mais no container (foi consumido em um craft, comido, etc), ignoramos!
                if not sourceInv:contains(item) then
                    handled = true
                end
                
                -- Tenta transferir pra outra mochila que tenha espaço
                -- Moveables ficam de fora deste passo: o sistema de placement (Cursor/SpriteProps)
                -- só reconhece Moveables nas mãos, então guardar em mochila os deixaria "presos"
                -- sem forma de instalar depois.
                if not handled and not instanceof(item, "Moveable") then
                    for _, targetInv in ipairs(containers) do
                        if targetInv ~= sourceInv and targetInv:isItemAllowed(item) and canItemFitInContainer(item, targetInv, playerNum) then
                            local transfer = ISInventoryTransferAction:new(playerObj, item, sourceInv, targetInv, 1)
                            transfer.maxTime = 0
                            ISTimedActionQueue.add(transfer)
                            handled = true
                            break
                        end
                    end
                end
                
                -- Se não coube em nenhuma, joga no chão
                if not handled then
                    if not (instanceof(item, "Moveable") and item:getSpriteGrid() == nil and not item:CanBeDroppedOnFloor()) then
                        item:setFavorite(false) -- Overflow perde o favorito!
                        local transfer = ISInventoryTransferAction:new(playerObj, item, sourceInv, floorContainer, 1)
                        transfer.maxTime = 0

                        -- O limite de peso do chão (50kg) existe pra frear transferências manuais,
                        -- não pra travar o AutoDrop. Se o item já não coube em nenhuma mochila, ele
                        -- TEM que ir pro chão -- então ignoramos a validação de capacidade só pra
                        -- essa transferência específica.
                        transfer.isValid = floorTransferAlwaysValid

                        ISTimedActionQueue.add(transfer)
                    else -- Equipa o item na mao
                        local primary = playerObj:getPrimaryHandItem()
                        local secondary = playerObj:getSecondaryHandItem()

                        if primary then
                            playerObj:setPrimaryHandItem(nil)
                        end
                        if secondary and secondary ~= primary then
                            playerObj:setSecondaryHandItem(nil)
                        end

                        item:setFavorite(false)
                        playerObj:setPrimaryHandItem(item)
                    end
                end
            end
        end
    end
end

Events.OnTick.Add(GridAutoDropSystem.OnTick)

return GridAutoDropSystem
