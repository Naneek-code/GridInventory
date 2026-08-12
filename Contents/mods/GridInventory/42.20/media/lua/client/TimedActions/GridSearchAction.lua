--- GridSearchAction.lua
--- Timed action da BUSCA de container do mundo (estilo Tarkov): enquanto roda,
--- revela progressivamente as pilhas de itens ocultos — 1 pilha por tick
--- (ms/pilha da sandbox option). Se o jogador para/cancela, o que já foi
--- revelado FICA salvo (a marcação é incremental no modData, não no perform).
--- Clicar de novo cria outra ação só com as pilhas ainda ocultas (retoma).

require "TimedActions/ISBaseTimedAction"
local GridInventory_Search = require("System/GridInventory_Search")
local GridSandboxOptions = require("GridSandboxOptions")

GridSearchAction = ISBaseTimedAction:derive("GridSearchAction")

function GridSearchAction:new(playerObj, gridRender, containerKey)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.character = playerObj
    o.gridRender = gridRender
    o.containerKey = containerKey
    o.playerNum = gridRender and gridRender.playerNum or (playerObj and playerObj:getPlayerNum()) or 0
    -- Andar CANCELA a busca (o personagem não fica preso; se o jogador se move,
    -- a ação para e mantém o que já foi revelado).
    o.stopOnWalk = true
    o.stopOnRun = true
    o.loopedAction = true
    o.started = false

    -- Pilhas ainda ocultas (líderes de pilha não vasculhados), na ordem de
    -- posição do grid (determinística) pra revelar da esquerda→direita/topo→baixo.
    o.hiddenLeaders = GridSearchAction._collectHiddenLeaders(gridRender, containerKey, o.playerNum)

    -- 1 tick por pilha: maxTime em unidades (~48/s), cada pilha = ms/pilha.
    local msPer = GridSandboxOptions.getSearchTimePerItem()
    o.revealed = 0
    o.total = #o.hiddenLeaders
    o.msPerStack = msPer
    if msPer <= 0 or o.total == 0 then
        -- Instantâneo: aplica tudo no perform (a ação quase não dura).
        o.maxTime = 1
    else
        -- ~48 unidades por segundo real; converte ms→unidades (1ms ≈ 48/1000 un).
        o.maxTime = math.max(1, math.ceil(o.total * msPer * (48 / 1000)))
    end
    return o
end

--- Coleta os líderes de pilha AINDA NÃO vasculhados do grid, ordenados por
--- posição (x asc, depois y asc).
---@param gridRender GridRender
---@param containerKey string
---@param playerNum number
---@return table lista de { itemId, itemObj }
function GridSearchAction._collectHiddenLeaders(gridRender, containerKey, playerNum)
    local list = {}
    if not gridRender or not gridRender.gridCore then return list end
    local items = gridRender.gridCore.items
    for itemId, data in pairs(items) do
        if data and not data.stackMemberOf and data.itemObj then
            -- Equipado/vestido (roupa em corpse): já visível, não precisa revelar.
            if not GridInventory_Search.isAlwaysRevealed(data.itemObj)
                and not GridInventory_Search.isSearched(playerNum, containerKey, data.itemObj:getID()) then
                table.insert(list, {
                    itemId = data.itemObj:getID(),
                    itemObj = data.itemObj,
                    x = data.x or 0,
                    y = data.y or 0,
                })
            end
        end
    end
    table.sort(list, function(a, b)
        if a.y == b.y then return a.x < b.x end
        return a.y < b.y
    end)
    return list
end

function GridSearchAction:isValid()
    if not self.character or not self.containerKey then return false end
    if self.character.isDead and self.character:isDead() then return false end
    return true
end

function GridSearchAction:waitToStart()
    return false
end

function GridSearchAction:update()
    ISBaseTimedAction.update(self)
    -- Revela progressivamente conforme o progresso (getJobDelta 0..1).
    -- ATENÇÃO: usar self.jobDelta (campo inexistente) = nil → nunca revelava;
    -- getJobDelta() é o método real (delega pro self.action). Protege se a
    -- action ainda não foi criada (self.action nil → getJobDelta quebraria).
    local progress = 0
    if self.action and self.action.getJobDelta then
        progress = self.action:getJobDelta() or 0
    end
    local target = math.floor(progress * self.total)
    while self.revealed < target and self.revealed < self.total do
        local h = self.hiddenLeaders[self.revealed + 1]
        if h and h.itemObj then
            GridInventory_Search.markSearched(self.character, self.containerKey, h.itemObj:getID())
        end
        self.revealed = self.revealed + 1
        -- Som one-shot curto a cada item/pilha revelado (feedback "achou algo").
        -- StoreItemPlayerInventory é um clip curto (não loopa). Evita o último
        -- item (a barra já completou) e a revelação em massa (instantânea).
        if self.character and self.character.getEmitter and self.revealed < self.total then
            self.character:getEmitter():playSound("StoreItemPlayerInventory")
        end
    end
end

function GridSearchAction:start()
    if self.character:isTimedActionInstant() then
        self:forceComplete()
    end
    -- Animação Loot IDÊNTICA ao ISInventoryTransferAction:doActionAnim — precisa
    -- do clearVariable + reportEvent("EventLootItem"), senão a animação Loot
    -- trava o personagem pra sempre (sem barra de progresso, preso até ESC).
    local cont = self.gridRender and self.gridRender.inventoryContainer
    self:setActionAnim("Loot")
    self:setAnimVariable("LootPosition", "")
    self:setOverrideHandModels(nil, nil)
    self.character:clearVariable("LootPosition")
    if cont and cont.getContainerPosition and cont:getContainerPosition() then
        self:setAnimVariable("LootPosition", cont:getContainerPosition())
    end
    if cont and cont.getType and cont:getType() == "freezer" and cont.getFreezerPosition and cont:getFreezerPosition() then
        self:setAnimVariable("LootPosition", cont:getFreezerPosition())
    end
    self.character:reportEvent("EventLootItem")
    -- SEM som de loop aqui: RummageInInventory é um loop contínuo que o vanilla
    -- não consegue parar (FIXME do próprio jogo). O feedback sonoro é o one-shot
    -- por item revelado no update (StoreItemPlayerInventory).
    ISBaseTimedAction.start(self)
end

function GridSearchAction:perform()
    -- Garante que tudo foi revelado (ação completou). No caso instantâneo
    -- (maxTime=1) o update pode não rodar; aqui revela o que faltar.
    if self.gridRender and self.gridRender.inventoryContainer then
        GridInventory_Search.revealAll(self.playerNum, self.containerKey,
            self.gridRender.inventoryContainer:getItems())
    end
    if self.action then
        self.action:stopTimedActionAnim()
        self.action:setLoopedAction(false)
    end
    ISBaseTimedAction.perform(self)
    self.started = false
end

function GridSearchAction:stop()
    ISBaseTimedAction.stop(self)
    self.started = false
end

return GridSearchAction
