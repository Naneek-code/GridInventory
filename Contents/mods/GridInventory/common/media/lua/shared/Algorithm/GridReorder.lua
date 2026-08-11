--- GridReorder.lua
--- Lógica pura de REORDENAR itens dentro do MESMO grid (drag&drop solto no
--- próprio grid): cálculo de alvos, detecção de no-op, revalidação e aplicação.
---
--- Separado do GridRender pra ser testável e compartilhado entre o caminho
--- IMEDIATO (SandboxOption ReorderTimeAction = instantâneo) e o caminho
--- ATRASADO (GridReorderAction — a animação de transferência dá ~0.5s pro
--- servidor processar no MP antes do broadcast das posições).

local GridReorder = {}

--- Calcula os alvos de um drop no mesmo grid (all-or-nothing).
--- @param gridCore GridCoreInstance
--- @param itemsData lista de GridInventory_GlobalDrag.itemsData (cada um com
---        id, originalW, originalH, rotated, grabOffsetX/Y, compatKey, stackInfo)
--- @param dropCol coluna do grid onde o mouse soltou
--- @param dropRow linha do grid onde o mouse soltou
--- @return targets (tabela {item, tx, ty, ew, eh}), movedSet — ou nil se algum
---         item não puder ser colocado (drop inválido).
function GridReorder.computeTargets(gridCore, itemsData, dropCol, dropRow)
    if not gridCore or not itemsData or not dropCol or not dropRow then return nil end
    local targets = {}
    local movedSet = {}
    for _, di in ipairs(itemsData) do
        movedSet[di.id] = true
    end
    for _, draggedItem in ipairs(itemsData) do
        local effectiveW = draggedItem.rotated and draggedItem.originalH or draggedItem.originalW
        local effectiveH = draggedItem.rotated and draggedItem.originalW or draggedItem.originalH
        local targetX = dropCol - draggedItem.grabOffsetX
        local targetY = dropRow - draggedItem.grabOffsetY
        if targetX < 1 then targetX = 1 end
        if targetY < 1 then targetY = 1 end
        if not gridCore:canPlaceItem(draggedItem.id, targetX, targetY, effectiveW, effectiveH,
                draggedItem.id, draggedItem.compatKey, draggedItem.rotated,
                draggedItem.stackInfo, movedSet) then
            return nil
        end
        table.insert(targets, {
            item = draggedItem, tx = targetX, ty = targetY,
            ew = effectiveW, eh = effectiveH
        })
    end
    return targets, movedSet
end

--- True se o drop não muda nada (cada item mantém posição E rotação atuais).
--- Evita animação/broadcast desnecessário pra drop "na mesma célula".
function GridReorder.isNoOp(gridCore, targets)
    if not targets then return true end
    for _, t in ipairs(targets) do
        local cur = gridCore and gridCore.items[t.item.id]
        if not cur or cur.x ~= t.tx or cur.y ~= t.ty
            or (cur.rotated or false) ~= (t.item.rotated or false) then
            return false
        end
    end
    return true
end

--- Revalida e aplica o reorder no gridCore (remove tudo antes, insere depois).
--- Revalida porque entre o drop e a aplicação (ação atrasada) o grid pode ter
--- mudado (item pego/removido por outro sistema) — se QUALQUER item falhar,
--- nada é movido (all-or-nothing, nunca perde item).
--- @return boolean true se aplicou, false se inválido (nada mudou).
function GridReorder.apply(gridCore, targets)
    if not gridCore or not targets or #targets == 0 then return false end
    local movedSet = {}
    for _, t in ipairs(targets) do
        movedSet[t.item.id] = true
    end
    for _, t in ipairs(targets) do
        local cur = gridCore.items[t.item.id]
        if not cur then
            return false
        end
        if not gridCore:canPlaceItem(t.item.id, t.tx, t.ty, t.ew, t.eh,
                t.item.id, t.item.compatKey, t.item.rotated,
                t.item.stackInfo, movedSet) then
            return false
        end
    end
    for _, t in ipairs(targets) do
        gridCore:removeItem(t.item.id)
    end
    for _, t in ipairs(targets) do
        gridCore:insertItem(t.item.id, t.tx, t.ty, t.ew, t.eh, t.item.rotated,
            t.item.itemObj, t.item.compatKey, t.item.stackInfo, movedSet)
    end
    return true
end

--- Tempo (em unidades da timed action, ~48 unidades por segundo real) para
--- reposicionar itens dentro do MESMO container. Espelha a fórmula do
--- ISInventoryTransferAction:new() pro caso "packing" (src == dest):
---   maxTime = base × peso(1..3) × capacityDelta, depois traits.
--- Base 120 dentro do inventário do personagem, 50 em container de mundo.
--- Usa o item MAIS PESADO do drag (pilha inteira custa como o mais pesado,
--- não a soma) — assim reposicionar um item custa o mesmo que o transfer
--- que o trouxe até aqui (consistência de tempo).
--- @param inventoryContainer container dono do grid
--- @param character IsoPlayer
--- @param targets lista de {item = {itemObj = ...}} do drag
--- @return number unidades de tempo da ação (0 = instantânea)
function GridReorder.computeTimeUnits(inventoryContainer, character, targets)
    local maxTime = 0
    if not inventoryContainer or not character then return 0 end
    local inCharacter = inventoryContainer.isInCharacterInventory
        and inventoryContainer:isInCharacterInventory(character)
    for _, t in ipairs(targets or {}) do
        local itemObj = t.item and t.item.itemObj
        local mt = inCharacter and 120 or 50
        local capacityDelta = 1.0
        if inCharacter then
            local cw = inventoryContainer.getCapacityWeight and inventoryContainer:getCapacityWeight()
            local mw = inventoryContainer.getMaxWeight and inventoryContainer:getMaxWeight()
            if mw and tonumber(mw) and mw > 0 then
                capacityDelta = (cw or 0) / mw
            end
            if capacityDelta < 0.4 then capacityDelta = 0.4 end
        end
        if itemObj and itemObj.getActualWeight then
            local w = itemObj:getActualWeight()
            if w > 3 then w = 3 end
            mt = mt * (w or 0) * capacityDelta
        end
        if character.hasTrait and CharacterTrait then
            if character:hasTrait(CharacterTrait.DEXTROUS) then
                mt = mt * 0.5
            end
            if character:hasTrait(CharacterTrait.ALL_THUMBS) then
                mt = mt * 2
            end
        end
        if mt > maxTime then maxTime = mt end
    end
    return maxTime
end

return GridReorder
