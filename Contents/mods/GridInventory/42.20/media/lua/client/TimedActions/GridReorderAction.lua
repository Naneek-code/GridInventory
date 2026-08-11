--- GridReorderAction.lua
--- Timed action pro REORDER de itens dentro do MESMO grid (drop do próprio
--- grid em outra célula). Antes o movimento acontecia no frame do drop;
--- com essa ação o personagem faz a animação de transferência e a aplicação
--- (remove/insere + broadcast) só roda no perform — ~0.5s depois.
---
--- MP: o atraso dá uma janela pro servidor processar/broadcastar as posições
--- antes de qualquer movimento seguinte, reduzindo corrida/desync.
---
--- A animação espelha o ISInventoryTransferAction: dentro do inventário do
--- personagem usa "TransferItemOnSelf" (packing), em container de mundo usa
--- "Loot" com LootPosition.

require "TimedActions/ISBaseTimedAction"
local GridReorder = require("Algorithm/GridReorder")

GridReorderAction = ISBaseTimedAction:derive("GridReorderAction")

function GridReorderAction:new(playerObj, gridRender, targets)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.character = playerObj
    o.gridRender = gridRender
    o.gridCore = gridRender and gridRender.gridCore
    o.inventoryContainer = gridRender and gridRender.inventoryContainer
    o.targets = targets or {}
    o.stopOnWalk = true
    o.stopOnRun = true
    o.loopedAction = true
    -- Tempo COPIA o ISInventoryTransferAction (GridReorder.computeTimeUnits):
    -- custa o mesmo que mover o item de/para esse container (peso × delta de
    -- capacidade × traits), não um valor fixo — senão reposicionar um item de
    -- 0.1 custaria mais que o transfer que o trouxe até aqui. maxTime é em
    -- UNIDADES, não ms reais: o timer da ação acumula GameTime.getMultiplier()
    -- por tick = ~48 unidades por segundo real (segundos reais × speed × 48).
    o.maxTime = GridReorder.computeTimeUnits(o.inventoryContainer, playerObj, o.targets)
    o.loopSound = nil
    o.started = false
    return o
end

function GridReorderAction:isValid()
    if not self.character or not self.gridCore then return false end
    if self.character.isDead and self.character:isDead() then return false end
    return true
end

function GridReorderAction:waitToStart()
    return false
end

function GridReorderAction:update()
    ISBaseTimedAction.update(self)
end

function GridReorderAction:start()
    if self.character:isTimedActionInstant() then
        self:forceComplete()
    end
    self:startActionAnim()
    if self.character.getEmitter then
        self.loopSound = self.character:getEmitter():playSound("RummageInInventory")
    end
    ISBaseTimedAction.start(self)
end

--- Animação: dentro do inventário do personagem usa a de packing/despacking
--- (TransferItemOnSelf); em container de mundo usa Loot com LootPosition.
function GridReorderAction:startActionAnim()
    local cont = self.inventoryContainer
    if cont and cont.isInCharacterInventory and cont:isInCharacterInventory(self.character) then
        self:setActionAnim("TransferItemOnSelf")
    else
        self:doActionAnim(cont)
    end
end

function GridReorderAction:doActionAnim(cont)
    self:setActionAnim("Loot")
    self:setAnimVariable("LootPosition", "")
    self:setOverrideHandModels(nil, nil)
    if cont and cont.getContainerPosition and cont:getContainerPosition() then
        self:setAnimVariable("LootPosition", cont:getContainerPosition())
    end
    if cont and cont.getType and cont:getType() == "freezer" and cont.getFreezerPosition and cont:getFreezerPosition() then
        self:setAnimVariable("LootPosition", cont:getFreezerPosition())
    end
end

function GridReorderAction:perform()
    if self.gridRender and self.gridRender.performGridReorder then
        self.gridRender:performGridReorder(self.targets)
    end
    if self.action then
        self.action:stopTimedActionAnim()
        self.action:setLoopedAction(false)
    end
    self:stopLoopingSound()
    ISBaseTimedAction.perform(self)
    self.started = false
end

function GridReorderAction:stop()
    self:stopLoopingSound()
    ISBaseTimedAction.stop(self)
    self.started = false
end

function GridReorderAction:stopLoopingSound()
    if self.loopSound and self.character and self.character.getEmitter then
        self.character:getEmitter():stopSound(self.loopSound)
        self.loopSound = nil
    end
end

return GridReorderAction
