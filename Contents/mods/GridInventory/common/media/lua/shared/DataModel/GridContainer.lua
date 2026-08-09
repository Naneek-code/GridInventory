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

-- Chão virtual: grid fixo (GetFloorContainer não existe no servidor, então a
-- validação de chão é bounds-only com estas dimensões).
GridContainer.FLOOR_W, GridContainer.FLOOR_H = 6, 15

--- Calcula as dimensões (w, h) do grid de um ItemContainer.
--- Compartilhado cliente/servidor: o SERVIDOR usa a MESMA matemática para
--- validar posições (bounds) e para não divergir da grid exibida no cliente.
---@param inventory ItemContainer
---@return number, number
function GridContainer.getGridSize(inventory)
    local cap = inventory:getCapacity()
    local w, h = 6, 6
    local invType = inventory:getType()
    local parent = inventory:getParent()

    if parent and instanceof(parent, "IsoDeadBody") then
        w, h = 6, 8 -- Cadáveres ganham grid 6x8 (48 slots) para respeitar o padrão de largura 6
    elseif invType == "inventorymale" or invType == "inventoryfemale" or invType == "inventory" or invType == "none" then
        w, h = 3, 4 -- Bolsos do jogador (12 slots)
    elseif invType == "floor" then
        w, h = GridContainer.FLOOR_W, GridContainer.FLOOR_H -- Chão (infinito visualmente limitado)
    elseif cap and cap > 0 then
        w = 6
        h = math.max(2, math.ceil(cap / 3))
        if h > 15 then h = 15 end
    else
        w, h = 4, 4
    end

    -- Verifica Overrides do GridDevTool (nil no servidor → check é seguro)
    if inventory:getContainingItem() then
        local fullType = inventory:getContainingItem():getFullType()
        if GridDevTool and GridDevTool.Overrides and GridDevTool.Overrides[fullType] then
            local override = GridDevTool.Overrides[fullType]
            if override.cols then w = override.cols end
            if override.rows then h = override.rows end
        end
    end

    return w, h
end

--- Chave de empilhamento de um item (nil = não-empilhável).
--- REGRA (ordem de prioridade):
---   1. Override explícito do GridDevTool (`stackable=true` força stack;
---      `stackable=false` força NÃO stack) — per-item, ajustável pelo dev.
---   2. Padrão: item LEVE (peso base < 1 por unidade) pode empilhar — caixa de
---      pregos (2.0) não, panos/rags (0.1) sim, munição/nails/bandagens sim.
---   3. O engine nunca empilha itens com CanStack=false (carregadores/clips).
--- NOTA: getMaxCount() NÃO existe no InventoryItem do B42 — não usar.
--- Compartilhado cliente/servidor: a mesma chave é usada na validação do servidor.
---@param item InventoryItem
---@return string|nil
function GridContainer.getStackableCompatKey(item)
    if not item then return nil end
    local fullType = item:getFullType()

    -- 1. Override explícito do DevTool (força stack / força não-stack)
    if GridDevTool and GridDevTool.Overrides and GridDevTool.Overrides[fullType] then
        local ov = GridDevTool.Overrides[fullType]
        if ov.stackable == true then
            return "stack:" .. fullType
        elseif ov.stackable == false then
            return nil
        end
    end

    -- 2. Regra padrão: item LEVE (peso base < 1) pode empilhar
    local weight = item.getWeight and tonumber(item:getWeight())
    local stackable = weight ~= nil and weight < 1

    -- 3. Engine não empilha (CanStack=false → carregadores/clips): nunca stacka
    if stackable and item.canStack and not item:canStack() then
        stackable = false
    end

    if stackable then
        return "stack:" .. fullType
    end
    return nil
end

--- Fallback curado de maxStack (unidades que empacotam numa caixa) — valores
--- confirmados nos recipes de pack/unpack do jogo. O parsing runtime dos
--- CraftRecipes (buildRecipeMaxStack) estende/sobrescreve isso automaticamente.
GridContainer.MAX_STACK_FALLBACK = {
    ["Base.Nails"] = 100, ["Base.Screws"] = 100, ["Base.NutsBolts"] = 100, ["Base.CapGunCap"] = 100,
    ["Base.Bullets9mm"] = 50, ["Base.Bullets45"] = 50, ["Base.Bullets38"] = 50, ["Base.Bullets357"] = 50,
    ["Base.Bullets44"] = 20, ["Base.308Bullets"] = 20, ["Base.556Bullets"] = 20, ["Base.3030Bullets"] = 20,
    ["Base.ShotgunShells"] = 25,
    ["Base.Money"] = 100,
    ["Base.BeerBottle"] = 6, ["Base.Wine"] = 6, ["Base.Wine2"] = 6,
    ["Base.EmptyJar"] = 6, ["Base.JarLid"] = 6,
}
-- Sem recipe/pack → teto de segurança de 1000 unidades (nunca pilha absurda).
GridContainer.STACK_LIMIT_DEFAULT = 1000

--- Tenta derivar maxStack de TODOS os recipes de categoria Packing: o output com
--- count > 1 (ex.: 100 pregos, 20 munições) é o limite da pilha daquele item.
--- Best-effort (pcall): se a API de craft mudar, cai pro fallback curado.
function GridContainer.buildRecipeMaxStack()
    local map = {}
    for k, v in pairs(GridContainer.MAX_STACK_FALLBACK) do
        map[k] = v
    end
    local ok, err = pcall(function()
        local cm = CraftRecipeManager
        if not cm or not cm.getAllCraftRecipes then return end
        local recipes = cm.getAllCraftRecipes()
        for i = 0, recipes:size() - 1 do
            local recipe = recipes:get(i)
            if recipe and recipe.getCategory and recipe:getCategory() == "Packing"
                and recipe.getOutputs then
                local outputs = recipe:getOutputs()
                for j = 0, outputs:size() - 1 do
                    local out = outputs:get(j)
                    if out and out.getIntAmount and out.getPossibleResultItems then
                        local amount = out:getIntAmount()
                        if amount and amount > 1 then
                            local items = out:getPossibleResultItems()
                            for k = 0, items:size() - 1 do
                                local it = items:get(k)
                                if it and it.getFullType then
                                    map[it:getFullType()] = amount
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    return map
end

--- Máximo de UNIDADES da pilha do item (ex.: 100 pregos). Ordem:
--- override maxStack do DevTool > recipe de pack (Auto) > fallback > ilimitado.
function GridContainer.getMaxStackUnits(item)
    if not item then return GridContainer.STACK_LIMIT_DEFAULT end
    local fullType = item:getFullType()

    -- 1. Override explícito do DevTool
    if GridDevTool and GridDevTool.Overrides and GridDevTool.Overrides[fullType] then
        local mv = GridDevTool.Overrides[fullType].maxStack
        if mv and tonumber(mv) then
            return math.max(1, math.floor(tonumber(mv)))
        end
    end

    -- 2. Auto: recipe de pack/unpack (derivado runtime) ou fallback curado
    if not GridContainer.recipeMaxStack then
        GridContainer.recipeMaxStack = GridContainer.buildRecipeMaxStack()
    end
    return GridContainer.recipeMaxStack[fullType]
        or GridContainer.MAX_STACK_FALLBACK[fullType]
        or GridContainer.STACK_LIMIT_DEFAULT
end

--- CompatKey + stackInfo ({limit, units}) de um item num único acesso.
---@return string|nil compatKey
---@return table|nil stackInfo
function GridContainer.getStackInfo(item)
    local compatKey = GridContainer.getStackableCompatKey(item)
    if not compatKey then return nil, nil end
    local limit = GridContainer.getMaxStackUnits(item)
    local units = (item.getCount and tonumber(item:getCount())) or 1
    return compatKey, { limit = limit, units = math.max(1, units) }
end

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

    local w, h = GridContainer.getGridSize(inventory)

    table.insert(self.grids, GridCore.new(w, h))

    GridContainer.instances[inventory] = self
    return self
end

--- Preenche um GridCore com os itens do container que POSSUEM posição salva.
--- Server-safe: não usa getPlayerHotbar/ISTimedActionQueue (só item:getModData()).
--- Usado pelo servidor para validar colisões de forma autoritativa.
---@param container ItemContainer
---@param grid GridCoreInstance
function GridContainer.buildOccupancy(container, grid)
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and item.getModData then
            local md = item:getModData()
            local sx = tonumber(md.gridX)
            local sy = tonumber(md.gridY)
            if sx and sy then
                local isRot = md.gridRot or false
                local w, h = ItemFootprint.getSize(item)
                local ew, eh = isRot and h or w, isRot and w or h
                -- CompatKey de pilha: itens compatíveis na MESMA posição empilham
                -- (respeitando o limite de unidades do maxStack).
                local compatKey, stackInfo = GridContainer.getStackInfo(item)
                grid:insertItem(item:getID(), sx, sy, ew, eh, isRot, item, compatKey, stackInfo)
            end
        end
    end
end

--- Valida (autoritativamente, lado servidor) se um item pode ser colocado em
--- (x, y) no grid do container: bounds + colisão com itens já posicionados.
--- Empilháveis (mesmo compatKey + mesmo retângulo) podem compartilhar célula.
---@param container ItemContainer
---@param item InventoryItem
---@param x number
---@param y number
---@param rotated boolean
---@return boolean
function GridContainer.validatePlacement(container, item, x, y, rotated)
    if not container or not item then return false end
    local w, h = GridContainer.getGridSize(container)
    local grid = GridCore.new(w, h)
    GridContainer.buildOccupancy(container, grid)
    local fw, fh = ItemFootprint.getSize(item)
    local ew, eh = rotated and fh or fw, rotated and fw or fh
    local compatKey, stackInfo = GridContainer.getStackInfo(item)
    return grid:canPlaceItem(item:getID(), x, y, ew, eh, item:getID(), compatKey, rotated, stackInfo)
end

--- Validação de CHÃO (container virtual inexistente no servidor): bounds-only
--- contra a grid do chão (6x15). Colisão fica por conta da autoridade final do
--- cliente ao renderizar; aqui só impedimos posições impossíveis/cheat.
function GridContainer.validateFloorPlacement(item, x, y, rotated)
    if not item then return false end
    local fw, fh = ItemFootprint.getSize(item)
    local ew, eh = rotated and fh or fw, rotated and fw or fh
    local compatKey, stackInfo = GridContainer.getStackInfo(item)
    return GridCore.new(GridContainer.FLOOR_W, GridContainer.FLOOR_H):canPlaceItem(item:getID(), x, y, ew, eh, item:getID(), compatKey, rotated, stackInfo)
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
    grid.stacks = {}
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
            local compatKey, stackInfo = GridContainer.getStackInfo(item)
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
                if savedX and savedY and grid:canPlaceItem(item:getID(), savedX, savedY, effectiveW, effectiveH, nil, compatKey, isRot, stackInfo) then
                    grid:insertItem(item:getID(), savedX, savedY, effectiveW, effectiveH, isRot, item, compatKey, stackInfo)
                    placed = true
                    break
                else
                    -- Fallback: posição sorteada (loot natural) para itens novos
                    -- sem posição salva; se não achar, Auto-Organize (top-left).
                    local freeX, freeY
                    local didRotate = false

                    if applyScatter then
                        freeX, freeY, didRotate = ScatterLayout.place(grid, item:getID(), w, h, seedKey, compatKey, stackInfo)
                    end

                    if not freeX then
                        freeX, freeY = grid:findFreeSpace(item:getID(), w, h, compatKey, stackInfo)
                        didRotate = false
                        if not freeX then
                            freeX, freeY = grid:findFreeSpace(item:getID(), h, w, compatKey, stackInfo)
                            if freeX and freeY then
                                didRotate = true
                            end
                        end
                    end
                    
                    if freeX and freeY then
                        local finalW = didRotate and h or w
                        local finalH = didRotate and w or h
                        
                        grid:insertItem(item:getID(), freeX, freeY, finalW, finalH, didRotate, item, compatKey, stackInfo)
                        
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
