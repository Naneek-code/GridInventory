--- GridContainer.lua
--- A ponte entre o mundo do Project Zomboid (ItemContainer) e o nosso GridCore matemático.
--- Responsável por instanciar grids, validar itens (ignorando equips/hotbar) e amarrar os bolsos.

local GridCore = require("DataModel/GridCore")
local ItemFootprint = require("Algorithm/ItemFootprint")
local ScatterLayout = require("Algorithm/ScatterLayout")

local GridContainer = {}
GridContainer.__index = GridContainer

-- Cache para não recriar as instâncias a cada frame
GridContainer.instances = {}

---@param inventory ItemContainer
---@param playerNum number
function GridContainer.getOrCreate(inventory, playerNum)
    if GridContainer.instances[inventory] then
        return GridContainer.instances[inventory]
    end

    local self = setmetatable({}, GridContainer)
    self.inventory = inventory
    self.playerNum = playerNum
    self.grids = {} -- Nossos sub-grids (bolsos e grid principal)
    
    local cap = inventory:getCapacity()
    local w, h = 6, 6
    local invType = inventory:getType()
    local parent = inventory:getParent()
    
    if parent and instanceof(parent, "IsoDeadBody") then
        w, h = 6, 8 -- Cadáveres ganham grid 6x8 (48 slots) para respeitar o padrão de largura 6
    elseif invType == "inventorymale" or invType == "inventoryfemale" or invType == "inventory" or invType == "none" then
        w, h = 3, 4 -- Bolsos do jogador (12 slots)
    elseif invType == "floor" then
        w, h = 6, 15 -- Chão (infinito visualmente limitado)
    elseif cap and cap > 0 then
        w = 6
        h = math.max(2, math.ceil(cap / 3))
        if h > 15 then h = 15 end
    else
        w, h = 4, 4
    end
    
    -- Verifica Overrides do GridDevTool
    if inventory:getContainingItem() then
        local fullType = inventory:getContainingItem():getFullType()
        if GridDevTool and GridDevTool.Overrides and GridDevTool.Overrides[fullType] then
            local override = GridDevTool.Overrides[fullType]
            if override.cols then w = override.cols end
            if override.rows then h = override.rows end
        end
    end
    
    table.insert(self.grids, GridCore.new(w, h))

    GridContainer.instances[inventory] = self
    return self
end

--- Filtra quais itens realmente devem ocupar espaço visual.
--- IGNORA magicamente itens anexados nas costas ou equipados, não importa em qual inventário estejam.
function GridContainer:_isItemValidForGrid(item)
    if item:isHidden() then return false end
    
    local player = getSpecificPlayer(self.playerNum)
    local isPlayerInv = self.inventory:isInCharacterInventory(player)
    
    if isPlayerInv then
        if item:isEquipped() then return false end
        
        local hotbar = getPlayerHotbar(self.playerNum)
        if hotbar and hotbar:isInHotbar(item) then
            return false
        end
    end
    
    -- Verifica se o item está na fila para ser equipado/vestido/anexado
    -- Isso evita que ele pisque no inventário (e caia no overflow) nos milisegundos
    -- entre a transferência pro bolso e a conclusão da ação de vestir.
    local actionQueue = ISTimedActionQueue.getTimedActionQueue(player)
    if actionQueue then
        local checkAction = function(act)
            if act and act.item == item and act.Type then
                local t = tostring(act.Type)
                if string.find(t, "Equip") or string.find(t, "Wear") or string.find(t, "Attach") then
                    return true
                end
            end
            return false
        end
        
        if checkAction(actionQueue.action) then return false end
        
        if actionQueue.queue then
            for i = 1, #actionQueue.queue do
                if checkAction(actionQueue.queue[i]) then return false end
            end
        end
    end

    return true
end

--- Tenta organizar todos os itens do container físico dentro da malha matemática.
function GridContainer:refresh()
    local hotbar = getPlayerHotbar(self.playerNum)
    if hotbar and hotbar.isRefreshingHotbar then
        -- O Zomboid está reconstruindo o Hotbar (ex: vestiu uma roupa nova).
        -- Durante este processo, itens anexados perdem temporariamente seu status.
        -- Abortamos o refresh do grid para não capturar esse estado transitório.
        return
    end

    -- Salva quem já estava no grid para dar prioridade e evitar que itens novos roubem a vaga
    local previouslyPlaced = {}
    for _, g in ipairs(self.grids) do
        for itemId, _ in pairs(g.items) do
            previouslyPlaced[itemId] = true
        end
    end

    -- 1. Limpa o grid atual para remapear do zero
    -- E remove grids de overflow que sobraram do último refresh!
    while #self.grids > 1 do
        table.remove(self.grids)
    end
    
    local grid = self.grids[1]
    grid.items = {}
    for x = 1, grid.width do
        for y = 1, grid.height do
            grid.cells[x][y] = nil
        end
    end

    local allItems = {}
    local javaItems = self.inventory:getItems()
    for i = 0, javaItems:size() - 1 do
        table.insert(allItems, javaItems:get(i))
    end

    -- PZ Engine Quirk: Zumbis mortos (IsoDeadBody) não guardam as roupas no getItems() padrão.
    local parent = self.inventory:getParent()
    if parent and instanceof(parent, "IsoDeadBody") then
        local wornItems = parent:getWornItems()
        if wornItems then
            for i = 0, wornItems:size() - 1 do
                local wornItem = wornItems:get(i):getItem()
                if wornItem and not self.inventory:contains(wornItem) then
                    table.insert(allItems, wornItem)
                end
            end
        end
    end
    
    -- Ordena os itens garantindo que os que já estavam na grade sejam processados primeiro!
    table.sort(allItems, function(a, b)
        local aPrev = previouslyPlaced[a:getID()] and 1 or 0
        local bPrev = previouslyPlaced[b:getID()] and 1 or 0
        -- Se ambos estavam (ou ambos não estavam), tenta usar o ID original pra manter consistência
        if aPrev == bPrev then
            return a:getID() < b:getID()
        end
        return aPrev > bPrev
    end)

    local unpositioned = {}

    -- Loot espalhado (natural) para containers recém-abertos: o sorteio é
    -- determinístico (mesmo layout em todos os clientes do MP — ver
    -- ScatterLayout.lua). Só afeta itens SEM posição salva.
    local applyScatter = ScatterLayout.shouldScatter(self.inventory, self.playerNum)
    local seedKey = ScatterLayout.buildSeedKey(self.inventory)

    -- 2. Itera sobre os itens reais do jogo
    for _, item in ipairs(allItems) do
        
        if self:_isItemValidForGrid(item) then
            local w, h = ItemFootprint.getSize(item)
            local placed = false
            
            -- Tenta encaixar no primeiro espaço livre
            for _, grid in ipairs(self.grids) do
                local modData = item:getModData()
                local savedX = tonumber(modData.gridX)
                local savedY = tonumber(modData.gridY)
                local isRot = modData.gridRot or false
                
                local effectiveW = isRot and h or w
                local effectiveH = isRot and w or h

                -- Tenta colocar na posição salva primeiro (Persistência)
                if savedX and savedY and grid:canPlaceItem(item:getID(), savedX, savedY, effectiveW, effectiveH) then
                    grid:insertItem(item:getID(), savedX, savedY, effectiveW, effectiveH, isRot, item)
                    placed = true
                    break
                else
                    -- Fallback: posição sorteada (loot natural) para itens novos
                    -- sem posição salva; se não achar, Auto-Organize (top-left).
                    local freeX, freeY
                    local didRotate = false

                    if applyScatter then
                        freeX, freeY, didRotate = ScatterLayout.place(grid, item:getID(), w, h, seedKey)
                    end

                    if not freeX then
                        freeX, freeY = grid:findFreeSpace(item:getID(), w, h)
                        didRotate = false
                        if not freeX then
                            freeX, freeY = grid:findFreeSpace(item:getID(), h, w)
                            if freeX and freeY then
                                didRotate = true
                            end
                        end
                    end
                    
                    if freeX and freeY then
                        local finalW = didRotate and h or w
                        local finalH = didRotate and w or h
                        
                        grid:insertItem(item:getID(), freeX, freeY, finalW, finalH, didRotate, item)
                        
                        -- Salva a nova posição gerada automaticamente
                        modData.gridX = freeX
                        modData.gridY = freeY
                        modData.gridRot = didRotate
                        
                        placed = true
                        break
                    end
                end
            end

            -- Se não coube em nenhum sub-grid (mochila cheia)
            if not placed then
                table.insert(unpositioned, item)
            end
        end
    end

    self.unpositioned = unpositioned
    return unpositioned
end

return GridContainer
