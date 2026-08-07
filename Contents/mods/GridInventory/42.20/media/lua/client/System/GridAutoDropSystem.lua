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
    for _, grid in ipairs(gridContainer.grids) do
        local fx, fy = grid:findFreeSpace(item:getID(), w, h)
        if not fx then
            fx, fy = grid:findFreeSpace(item:getID(), h, w)
        end
        if fx and fy then return true end
    end
    return false
end

local function getInventoryHash(inv)
    local hash = 0
    local items = inv:getItems()
    local size = items:size()
    for i=0, size-1 do
        hash = hash + items:get(i):getID()
    end
    return tostring(size) .. "_" .. tostring(hash)
end

function GridAutoDropSystem.OnTick()
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
            
            local currentHash = getInventoryHash(inv)
            if currentHash ~= gridContainer.lastAutoDropHash then
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
                
                print("[AutoDrop] Processando item: " .. tostring(item:getName()) .. " do container " .. tostring(sourceInv:getType()))
                
                -- Se o item não está mais no container (foi consumido em um craft, comido, etc), ignoramos!
                if not sourceInv:contains(item) then
                    print("[AutoDrop] Item fantasma (consumido). Ignorando.")
                    handled = true
                end
                
                -- Tenta transferir pra outra mochila que tenha espaço
                if not handled then
                    for _, targetInv in ipairs(containers) do
                    if targetInv ~= sourceInv and targetInv:isItemAllowed(item) and canItemFitInContainer(item, targetInv, playerNum) then
                        print("[AutoDrop] Coube na mochila " .. tostring(targetInv:getType()))
                        local transfer = ISInventoryTransferAction:new(playerObj, item, sourceInv, targetInv, 1)
                        -- Importante: forçamos a engine a rodar o transfer rápido já que é AutoDrop
                        transfer.maxTime = 0
                        ISTimedActionQueue.add(transfer)
                        handled = true
                        break
                    end
                    end
                end
                
                -- Se não coube em nenhuma, joga no chão
                if not handled then
                    print("[AutoDrop] Nao coube em lugar nenhum. Jogando no chao!")
                    if not (instanceof(item, "Moveable") and item:getSpriteGrid() == nil and not item:CanBeDroppedOnFloor()) then
                        item:setFavorite(false) -- Overflow perde o favorito!
                        local transfer = ISInventoryTransferAction:new(playerObj, item, sourceInv, floorContainer, 1)
                        transfer.maxTime = 0
                        ISTimedActionQueue.add(transfer)
                    else
                        print("[AutoDrop] Item não pode ser jogado no chao (Moveable grid)")
                    end
                end
            end
        end
    end
end

Events.OnTick.Add(GridAutoDropSystem.OnTick)

return GridAutoDropSystem
