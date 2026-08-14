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
    
    -- Pilhas (stacks): stacks[leaderId] = { members = { [memberId] = true },
    --                                          units = <total de unidades> }
    -- Vários itens COMPATÍVEIS (mesmo compatKey) podem ocupar a MESMA célula.
    -- As células sempre apontam para o LEADER; os members só existem em
    -- `items` (posição espelhada) e em `stacks[leader].members`.
    -- `units` é o CACHE do getPileUnits (soma de stackInfo.units do líder +
    -- membros) — mantido incrementalmente em insertItem/removeItem pra manter
    -- o getPileUnits O(1) (sem iterar a pilha toda a cada render/frame).
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
--- True se um item ocupante deve ser ignorado pela checagem de colisão:
--- - o próprio item sendo movido (itemId);
--- - o ignoreItemId simples (item único em movimento);
--- - OU qualquer item no ignoreSet (conjunto de itens movidos JUNTOS — ex.:
---   arrastar uma PILHA inteira: os membros ainda estão na origem, mas vão
---   sair, então o alvo pode sobrepor a origem sem "colidir" com eles).
local function isIgnored(id, itemId, ignoreItemId, ignoreSet)
    if id == nil then return false end
    if id == itemId or id == ignoreItemId then return true end
    if ignoreSet and ignoreSet[id] then return true end
    return false
end

function GridCoreInstance:canPlaceItem(itemId, x, y, w, h, ignoreItemId, compatKey, isRotated, stackInfo, ignoreSet)
    x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    
    if not self:isWithinBounds(x, y, w, h) then
        return false
    end

    -- Candidato empilhável: permite sobreposição SOMENTE com uma pilha
    -- compatível (mesmo compatKey e retângulo exatamente igual).
    if compatKey then
        local occ = self.cells[x][y]
        if occ ~= nil and not isIgnored(occ, itemId, ignoreItemId, ignoreSet) then
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
                        if o ~= nil and o ~= occ and not isIgnored(o, itemId, ignoreItemId, ignoreSet) then
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
            if occupant ~= nil and not isIgnored(occupant, itemId, ignoreItemId, ignoreSet) then
                return false
            end
        end
    end
    
    -- Verifica interseção com ghost items (transferências pendentes)
    if self.ghostItems then
        for gId, gData in pairs(self.ghostItems) do
            if not isIgnored(gId, itemId, ignoreItemId, ignoreSet) then
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
---@param ignoreSet table? set de itemIds movidos juntos (pilha inteira)
---@return boolean true if inserted successfully, false otherwise
function GridCoreInstance:insertItem(itemId, x, y, w, h, isRotated, itemObj, compatKey, stackInfo, ignoreSet)
    if not self:canPlaceItem(itemId, x, y, w, h, nil, compatKey, isRotated, stackInfo, ignoreSet) then
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
                local occUnits = occData.stackInfo and occData.stackInfo.units or 0
                self.stacks[occ] = { members = {}, units = occUnits }
            end
            self.stacks[occ].members[itemId] = true
            self.stacks[occ].units = self.stacks[occ].units + (stackInfo and stackInfo.units or 0)
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
            self.stacks[leader].units = self.stacks[leader].units - (itemData.stackInfo and itemData.stackInfo.units or 0)
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
            -- Cache de units: o líder removido sai da pilha; o promovido já
            -- estava contabilizado como membro, então só subtrai as units do
            -- líder que saiu.
            local promotedUnits = self.stacks[itemId].units
                - (itemData.stackInfo and itemData.stackInfo.units or 0)
            local left = 0
            for mId, _ in pairs(members) do
                left = left + 1
                -- CRÍTICO: os membros restantes continuam apontando pro líder
                -- ANTIGO (itemId) no stackMemberOf — sem isso pilhas com 3+
                -- quebram ao mover (membros órfãos/duplicados em stacks).
                if self.items[mId] then
                    self.items[mId].stackMemberOf = nextLeader
                end
            end
            if left > 0 then
                self.stacks[nextLeader] = { members = members, units = promotedUnits }
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
--- O(1): usa o cache incremental `stacks[leader].units` mantido por
--- insertItem/removeItem/relocatePile — NÃO itera os membros a cada chamada
--- (antes era O(nº de membros) e rodava a cada frame no render + no BFS de
--- consolidação; com pilhas de até 1000 objetos o custo era absurdo).
function GridCoreInstance:getPileUnits(leaderId)
    local s = self.stacks[leaderId]
    if s then
        return s.units
    end
    local ld = self.items[leaderId]
    if ld and ld.stackInfo then
        return ld.stackInfo.units or 1
    end
    return 0
end

--- Move uma pilha INTEIRA (líder + membros) pra cima de outra pilha compatível
--- (mesmo compatKey + mesmo retângulo x/y/w/h/rotated), virando membros do
--- líder alvo. Usado pela consolidação de stacks virtuais (ex.: 5×20 pregos →
--- 1 pilha de 100). All-or-nothing: nunca divide pilha.
---@param sourceLeaderId id do líder da pilha que será absorvida
---@param targetLeaderId id do líder da pilha alvo (não pode ser membro)
---@return table|nil lista dos ids movidos (líder primeiro, depois membros) ou
---         nil se não foi possível (incompatível / cheia / não líder).
function GridCoreInstance:relocatePile(sourceLeaderId, targetLeaderId)
    local src = self.items[sourceLeaderId]
    local dst = self.items[targetLeaderId]
    if not src or not dst then return nil end
    -- Só líderes participam (alvo nunca é membro; origem precisa ser líder).
    if src.stackMemberOf or dst.stackMemberOf then return nil end
    if sourceLeaderId == targetLeaderId then return nil end
    if not src.compatKey then return nil end
    -- Compatibilidade: mesmo compatKey e MESMO retângulo (w/h/rotated). As
    -- posições são diferentes por definição (são pilhas separadas) — só o
    -- formato do footprint precisa casar pra caber na MESMA célula.
    if src.compatKey ~= dst.compatKey then return nil end
    if src.w ~= dst.w or src.h ~= dst.h
        or (src.rotated or false) ~= (dst.rotated or false) then
        return nil
    end
    -- Limite de unidades do alvo: a pilha inteira precisa caber.
    local limit = dst.stackInfo and dst.stackInfo.limit
    if limit and (self:getPileUnits(targetLeaderId) + self:getPileUnits(sourceLeaderId)) > limit then
        return nil
    end
    -- Snapshot dos itens (líder primeiro, depois membros) antes de remover.
    local ids = { sourceLeaderId }
    local stack = self.stacks[sourceLeaderId]
    if stack and stack.members then
        for mId in pairs(stack.members) do table.insert(ids, mId) end
    end
    local snap = {}
    for _, id in ipairs(ids) do
        local d = self.items[id]
        snap[id] = { itemObj = d.itemObj, stackInfo = d.stackInfo }
    end
    -- Remove todos da origem (membros primeiro → o líder não promove ninguém).
    for i = #ids, 1, -1 do
        self:removeItem(ids[i])
    end
    -- Reinsere tudo como membro da pilha alvo (mesmo rect + compatKey → empilha).
    for _, id in ipairs(ids) do
        if not self:insertItem(id, dst.x, dst.y, dst.w, dst.h, dst.rotated,
            snap[id].itemObj, src.compatKey, snap[id].stackInfo) then
            return nil
        end
    end
    return ids
end

--- Encontra o primeiro espaço livre para um item, priorizando top-left.
--- Com compatKey, um item empilhável também "cabe" numa célula ocupada por
--- pilha compatível (mesmo retângulo) — o scan usa canPlaceItem, que já
--- contempla stacking e o limite de unidades.
---@param isRotated boolean? Orientação do candidato (importante pra achar pilha
---   rotacionada "em pé" — ex.: 1x2 precisa casar com pilha 1x2 rotacionada).
---@return number, number (x, y) or nil, nil if no space
function GridCoreInstance:findFreeSpace(itemId, w, h, compatKey, stackInfo, isRotated)
    for y = 1, self.height do
        for x = 1, self.width do
            if self:canPlaceItem(itemId, x, y, w, h, nil, compatKey, isRotated or false, stackInfo) then
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
