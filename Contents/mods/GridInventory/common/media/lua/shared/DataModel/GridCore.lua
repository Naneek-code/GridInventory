--- GridCore.lua
--- Core mathematical representation of a 2D grid inventory.
--- 100% decoupled from Project Zomboid logic and UI for max testability.

local GridCore = {}

---@class GridCoreInstance
local GridCoreInstance = {}
GridCoreInstance.__index = GridCoreInstance

--- Creates a new empty grid
---@param width number
---@param height number
---@return GridCoreInstance
function GridCore.new(width, height)
    local self = setmetatable({}, GridCoreInstance)
    self.width = width
    self.height = height
    
    -- Matrix for quick spatial lookups: cells[x][y] = itemId
    self.cells = {}
    for x = 1, width do
        self.cells[x] = {}
        for y = 1, height do
            self.cells[x][y] = nil
        end
    end
    
    -- Dictionary for fast item lookups: items[itemId] = { x, y, w, h, rotated, compatKey, stackMemberOf }
    self.items = {}
    
    -- Dictionary for pending items (ghosts): ghostItems[itemId] = { x, y, w, h, rotated, itemObj, timeAdded, compatKey }
    self.ghostItems = {}
    
    -- Pilhas (stacks): stacks[leaderId] = { members = { [memberId] = true } }
    -- Vários itens COMPATÍVEIS (mesmo compatKey) podem ocupar a MESMA célula.
    -- As células sempre apontam para o LEADER; os members só existem em
    -- `items` (posição espelhada) e em `stacks[leader].members`.
    self.stacks = {}
    
    return self
end

--- Validates if a coordinate is within the grid boundaries
function GridCoreInstance:isWithinBounds(x, y, w, h)
    if x < 1 or y < 1 then return false end
    if (x + w - 1) > self.width then return false end
    if (y + h - 1) > self.height then return false end
    return true
end

--- Checks if a specific item can be placed at the given coordinates
---@param itemId string|number Unique identifier for the item
---@param x number X coordinate (1-indexed)
---@param y number Y coordinate (1-indexed)
---@param w number Width of the item
---@param h number Height of the item
---@param ignoreItemId string|number? Optional ID of an item to ignore during collision check (useful for moving items)
---@param compatKey string? Optional stacking key: se dois itens compartilham o
---   mesmo compatKey e o MESMO retângulo (x/y/w/h/rotated), podem ocupar a
---   mesma célula (pilha). Nil = item não-empilhável.
---@param isRotated boolean? Orientação do candidato (usada no match de pilha).
---@param stackInfo table? { limit = number, units = number } — limite de
---   UNIDADES da pilha e unidades deste item. Nil = sem limite (pilha infinita).
---@return boolean
function GridCoreInstance:canPlaceItem(itemId, x, y, w, h, ignoreItemId, compatKey, isRotated, stackInfo)
    x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    
    if not self:isWithinBounds(x, y, w, h) then
        return false
    end

    -- Candidato empilhável: permite sobreposição SOMENTE com uma pilha
    -- compatível (mesmo compatKey e retângulo exatamente igual).
    if compatKey then
        local occ = self.cells[x][y]
        if occ ~= nil and occ ~= itemId and occ ~= ignoreItemId then
            local occData = self.items[occ]
            if occData
                and occData.compatKey == compatKey
                and occData.x == x and occData.y == y
                and occData.w == w and occData.h == h
                and occData.rotated == (isRotated or false) then
                -- Retângulo inteiro deve pertencer ao MESMO líder (nada mais ali)
                local allLeader = true
                for cx = x, x + w - 1 do
                    for cy = y, y + h - 1 do
                        local o = self.cells[cx][cy]
                        if o ~= nil and o ~= occ and o ~= itemId and o ~= ignoreItemId then
                            allLeader = false
                            break
                        end
                    end
                    if not allLeader then break end
                end
                if allLeader then
                    -- Limite de UNIDADES da pilha (ex.: 100 pregos por caixa)
                    if stackInfo and occData.stackInfo then
                        local limit = occData.stackInfo.limit
                        local pileUnits = self:getPileUnits(occ)
                        if limit and (pileUnits + (stackInfo.units or 1)) > limit then
                            return false
                        end
                    end
                    return true
                end
            end
            -- Occupante presente mas não compatível (ou retângulo diferente)
            return false
        end
        -- Célula livre → cai no scan normal abaixo
    end

    for cx = x, x + w - 1 do
        for cy = y, y + h - 1 do
            local occupant = self.cells[cx][cy]
            if occupant ~= nil and occupant ~= ignoreItemId and occupant ~= itemId then
                return false
            end
        end
    end
    
    -- Verifica interseção com ghost items (transferências pendentes)
    if self.ghostItems then
        for gId, gData in pairs(self.ghostItems) do
            if gId ~= ignoreItemId and gId ~= itemId then
                local gx, gy, gw, gh = tonumber(gData.x), tonumber(gData.y), tonumber(gData.w), tonumber(gData.h)
                -- Ghost de pilha compatível com retângulo igual não bloqueia
                local compatibleGhost = compatKey and gData.compatKey == compatKey
                    and gx == x and gy == y and gw == w and gh == h
                if not compatibleGhost then
                    if x < gx + gw and x + w > gx and y < gy + gh and y + h > gy then
                        return false
                    end
                end
            end
        end
    end

    return true
end

--- Attempts to insert an item into the grid at a specific location
---@param compatKey string? Chave de empilhamento (ver canPlaceItem)
---@param stackInfo table? { limit, units } — limite e unidades da pilha (nil = sem limite)
---@return boolean true if inserted successfully, false otherwise
function GridCoreInstance:insertItem(itemId, x, y, w, h, isRotated, itemObj, compatKey, stackInfo)
    if not self:canPlaceItem(itemId, x, y, w, h, nil, compatKey, isRotated, stackInfo) then
        return false
    end

    if self.items[itemId] then
        self:removeItem(itemId)
    end
    
    if self.ghostItems[itemId] then
        self.ghostItems[itemId] = nil
    end

    -- Empilhar sobre um líder compatível existente (mesmo retângulo)?
    local occ = compatKey and self.cells[x][y] or nil
    if occ and occ ~= itemId then
        local occData = self.items[occ]
        if occData
            and occData.compatKey == compatKey
            and occData.x == x and occData.y == y
            and occData.w == w and occData.h == h
            and occData.rotated == (isRotated or false) then
            if not self.stacks[occ] then
                self.stacks[occ] = { members = {} }
            end
            self.stacks[occ].members[itemId] = true
            self.items[itemId] = {
                x = x,
                y = y,
                w = w,
                h = h,
                rotated = isRotated or false,
                itemObj = itemObj,
                compatKey = compatKey,
                stackInfo = stackInfo,
                stackMemberOf = occ
            }
            return true
        end
    end

    self.items[itemId] = {
        x = x,
        y = y,
        w = w,
        h = h,
        rotated = isRotated or false,
        itemObj = itemObj, -- Referência nativa para UI
        compatKey = compatKey,
        stackInfo = stackInfo
    }

    -- Líder novo: não pode herdar pilha velha (o GridContainer:refresh não
    -- recria o objeto; ele reusa e limpa items/cells, mas stacks precisa ser
    -- zerado por item — membros antigos virariam fantasma aqui).
    self.stacks[itemId] = nil

    -- Mark cells as occupied
    for cx = x, x + w - 1 do
        for cy = y, y + h - 1 do
            self.cells[cx][cy] = itemId
        end
    end

    return true
end

--- Removes an item from the grid (member ou leader de pilha são tratados)
---@return boolean true if removed, false if not found
function GridCoreInstance:removeItem(itemId)
    local itemData = self.items[itemId]
    if not itemData then
        return false
    end

    -- Membro de pilha: as células pertencem ao líder; só desregistra o membro.
    if itemData.stackMemberOf then
        local leader = itemData.stackMemberOf
        if self.stacks[leader] and self.stacks[leader].members then
            self.stacks[leader].members[itemId] = nil
            local left = 0
            for _ in pairs(self.stacks[leader].members) do left = left + 1 end
            if left == 0 then self.stacks[leader] = nil end
        end
        self.items[itemId] = nil
        return true
    end

    -- Free the cells
    for cx = itemData.x, itemData.x + itemData.w - 1 do
        for cy = itemData.y, itemData.y + itemData.h - 1 do
            if self.cells[cx][cy] == itemId then
                self.cells[cx][cy] = nil
            end
        end
    end

    -- Líder com membros: promove um membro a novo líder da pilha.
    if self.stacks[itemId] then
        local nextLeader = nil
        for mId in pairs(self.stacks[itemId].members) do
            nextLeader = mId
            break
        end
        if nextLeader then
            local mData = self.items[nextLeader]
            mData.stackMemberOf = nil
            local members = self.stacks[itemId].members
            members[itemId] = nil
            members[nextLeader] = nil
            local left = 0
            for _ in pairs(members) do left = left + 1 end
            if left > 0 then
                self.stacks[nextLeader] = { members = members }
            end
            for cx = itemData.x, itemData.x + itemData.w - 1 do
                for cy = itemData.y, itemData.y + itemData.h - 1 do
                    self.cells[cx][cy] = nextLeader
                end
            end
        end
        self.stacks[itemId] = nil
    end

    -- Remove from registry
    self.items[itemId] = nil
    return true
end

--- Gets the data for an item in the grid
function GridCoreInstance:getItemData(itemId)
    return self.items[itemId]
end

function GridCoreInstance:addGhostItem(itemId, itemObj, x, y, w, h, rotated, compatKey, stackInfo)
    self.ghostItems[itemId] = {
        itemObj = itemObj,
        x = tonumber(x),
        y = tonumber(y),
        w = tonumber(w),
        h = tonumber(h),
        rotated = rotated or false,
        compatKey = compatKey,
        stackInfo = stackInfo,
        timeAdded = getTimeInMillis()
    }
end

function GridCoreInstance:removeGhostItem(itemId)
    self.ghostItems[itemId] = nil
end

-- ============================================================================
-- PILHAS (stacks)
-- ============================================================================

--- True se o item é o líder de uma célula (não é membro de outra pilha).
function GridCoreInstance:isStackLeader(itemId)
    local data = self.items[itemId]
    return data and not data.stackMemberOf or false
end

--- Lista de itemIds na MESMA pilha (líder primeiro, depois os membros).
--- Se não for pilha, retorna { itemId }.
function GridCoreInstance:getStackMembers(itemId)
    local list = { itemId }
    local s = self.stacks[itemId]
    if s and s.members then
        for mId in pairs(s.members) do
            table.insert(list, mId)
        end
    end
    return list
end

--- Número de itens (objetos) na pilha do item (>= 1).
function GridCoreInstance:getStackSize(itemId)
    local s = self.stacks[itemId]
    local n = 1
    if s and s.members then
        for _ in pairs(s.members) do n = n + 1 end
    end
    return n
end

--- Total de UNIDADES na pilha (soma de stackInfo.units de líder + membros).
function GridCoreInstance:getPileUnits(leaderId)
    local total = 0
    local ld = self.items[leaderId]
    if ld and ld.stackInfo and ld.stackInfo.units then
        total = total + ld.stackInfo.units
    end
    local s = self.stacks[leaderId]
    if s and s.members then
        for mId in pairs(s.members) do
            local d = self.items[mId]
            if d and d.stackInfo and d.stackInfo.units then
                total = total + d.stackInfo.units
            end
        end
    end
    return total
end

--- Encontra o primeiro espaço livre para um item, priorizando top-left.
--- Com compatKey, um item empilhável também "cabe" numa célula ocupada por
--- pilha compatível (mesmo retângulo) — o scan usa canPlaceItem, que já
--- contempla stacking e o limite de unidades.
---@return number, number (x, y) or nil, nil if no space
function GridCoreInstance:findFreeSpace(itemId, w, h, compatKey, stackInfo)
    for y = 1, self.height do
        for x = 1, self.width do
            if self:canPlaceItem(itemId, x, y, w, h, nil, compatKey, false, stackInfo) then
                return x, y
            end
        end
    end
    return nil, nil
end

--- Procura uma PILHA COMPATÍVEL existente (mesmo compatKey + mesmo retângulo)
--- e retorna a posição dela. Nil se não houver. Diferente do findFreeSpace:
--- NÃO considera células livres — só pilhas já formadas. Respeita o limite.
---@return number, number, boolean x, y, rotated (do líder da pilha)
function GridCoreInstance:findCompatibleStack(itemId, w, h, compatKey, stackInfo)
    if not compatKey then return nil end
    for y = 1, self.height do
        for x = 1, self.width do
            local occ = self.cells[x][y]
            if occ and occ ~= itemId then
                local occData = self.items[occ]
                if occData
                    and occData.compatKey == compatKey
                    and occData.x == x and occData.y == y
                    and occData.w == w and occData.h == h then
                    -- Respeita o limite de unidades da pilha (pilha cheia = não cabe)
                    local fits = true
                    if stackInfo and occData.stackInfo then
                        local limit = occData.stackInfo.limit
                        if limit and (self:getPileUnits(occ) + (stackInfo.units or 1)) > limit then
                            fits = false
                        end
                    end
                    if fits then
                        return x, y, occData.rotated
                    end
                end
            end
        end
    end
    return nil
end

return GridCore
