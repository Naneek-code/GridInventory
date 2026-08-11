--- GridInventory_BagDrop.lua
--- Drag n drop "put in" (sem feedback visual): soltar sobre o FOOTPRINT de uma
--- bolsa DENTRO do grid transfere o item arrastado para dentro dela, e soltar
--- sobre o HEADER do grid transfere pro próprio container do grid (ex.: o grid
--- da mochila selecionada). É um fallback invisível: nada é renderizado — se o
--- usuário jogar o item ali por intuição, o drop cai no auto-slot do container.
---
--- O botão da coluna de mochilas (vanilla) continua funcionando por conta
--- própria: o dropItemsInContainer do vanilla valida (isItemAllowed + peso) e
--- o wrapper handledByBag abaixo impede o GridRender:onMouseUp de reposicionar
--- itens que o vanilla já moveu. NÃO há mais detecção customizada de botão
--- aqui (o feedback "put in" das colunas foi removido por mostrar PUT-IN até
--- pra item que não cabe — o vanilla já recusa).

local GridClientNetwork = require("Network/GridClientNetwork")
require "TimedActions/ISInventoryTransferAction"

GridInventory_BagDrop = GridInventory_BagDrop or {}
GridInventory_InTransit = GridInventory_InTransit or {}

-- Mesmo valor do GridRender.lua (GRID_PADDING = 10). Evita require circular
-- (GridRender já depende deste módulo).
local CELL_PADDING = 10

local function pagesOf(playerNum)
    local pages = {}
    if playerNum == nil then
        for p = 0, getNumActivePlayers() - 1 do
            local inv = getPlayerInventory(p)
            local loot = getPlayerLoot(p)
            if inv then table.insert(pages, inv) end
            if loot then table.insert(pages, loot) end
        end
    else
        local inv = getPlayerInventory(playerNum)
        local loot = getPlayerLoot(playerNum)
        if inv then table.insert(pages, inv) end
        if loot then table.insert(pages, loot) end
    end
    return pages
end

local function dragPlayerNum(drag)
    return (drag and drag.sourceGrid and drag.sourceGrid.playerNum) or 0
end

--- Alvo de put-in DENTRO de UM grid sob o cursor: item-bolsa (footprint).
--- { kind = "item", grid, item, target, data } ou nil. Não cobre o header
--- (sem feedback visual no header — o drop lá é invisível por decisão).
function GridInventory_BagDrop.bagAtPoint(grid)
    if not grid or not grid.gridCore or not grid.getGridCellAtMouse
        or not grid:getIsVisible() or not grid:isPointOver(getMouseX(), getMouseY()) then
        return nil
    end
    local gx = grid:getMouseX()
    local gy = grid:getMouseY()
    if gy <= CELL_PADDING + (grid.headerH or 0) then return nil end
    local col, row = grid:getGridCellAtMouse(gx, gy)
    if not col or not row then return nil end
    local cellRow = grid.gridCore.cells[col]
    local itemId = cellRow and cellRow[row]
    local data = itemId and grid.gridCore.items[itemId]
    local item = data and data.itemObj
    if not (item and item.getInventory and item:getInventory()) then return nil end
    return { kind = "item", grid = grid, item = item, target = item:getInventory(), data = data }
end

--- Alvo de put-in sob o cursor:
---  - item-bolsa (footprint): { kind = "item",   grid, page, item, target, data }
---  - header do grid:         { kind = "header", grid, page, target }
function GridInventory_BagDrop.findBagItemUnderMouse(playerNum)
    local mx = getMouseX()
    local my = getMouseY()

    -- Janelas flutuantes de bolsas ficam POR CIMA das páginas: primeiro os
    -- alvos delas. A barra de título da janela = put-in pro container da
    -- própria bolsa; o footprint de bolsa DENTRO do grid da janela = put-in
    -- pra essa bolsa interna. (O feedback visual já funciona lá — o gridUi é
    -- um GridRender —; o que faltava era a detecção + transferência.)
    local floating = GridInventory_FloatingGrid and GridInventory_FloatingGrid[playerNum]
    if floating then
        for _, win in ipairs(floating) do
            if win and win:getIsVisible() and not win.isStackPicker and win:isPointOver(mx, my) then
                local ly = win:getMouseY()
                if ly < (win.titleH or 26) and win.bagInventory then
                    return { kind = "header", grid = win.gridUi, page = nil, target = win.bagInventory }
                end
                if win.gridUi and win.gridUi:isPointOver(mx, my) then
                    local bag = GridInventory_BagDrop.bagAtPoint(win.gridUi)
                    if bag then
                        bag.page = nil
                        return bag
                    end
                end
            end
        end
    end

    for _, page in ipairs(pagesOf(playerNum)) do
        if page and page:getIsVisible() and not page.isCollapsed
            and page.inventoryPane and page.inventoryPane.gridContainerUis then
            for _, grid in ipairs(page.inventoryPane.gridContainerUis) do
                if grid and grid.gridCore and grid:getIsVisible() and grid:isPointOver(mx, my) then
                    local gy = grid:getMouseY()
                    local headerH = grid.headerH or 0

                    -- Header do grid = alvo de put-in pro container dele.
                    if headerH > 0 and gy >= CELL_PADDING and gy <= CELL_PADDING + headerH then
                        if grid.inventoryContainer then
                            return { kind = "header", grid = grid, page = page, target = grid.inventoryContainer }
                        end
                    end

                    -- Célula com item-bolsa (qualquer célula do footprint).
                    local bag = GridInventory_BagDrop.bagAtPoint(grid)
                    if bag then
                        bag.page = page
                        return bag
                    end
                end
            end
        end
    end
    return nil
end

--- Alvo de put-in sob o cursor (bolsa em grid ou header do grid).
function GridInventory_BagDrop.findBagUnderMouse(playerNum)
    return GridInventory_BagDrop.findBagItemUnderMouse(playerNum)
end

function GridInventory_BagDrop.getTarget(bag)
    return bag and bag.target or nil
end

--- Container de bolsa ANINHADA NO MUNDO: o vanilla recusa transferir itens pra
--- dentro dele (o engine não deixa mexer em bolsa dentro de bolsa em container
--- de objeto do mundo — cadáver, veículo, mobília). Bolsa aninhada dentro do
--- INVENTÁRIO do jogador funciona normalmente. Regra espelhada do vanilla:
--- o conteúdo só é acessível se a bolsa está direto num container raiz OU se
--- a raiz da árvore inteira é o inventário do personagem.
---@param target ItemContainer container alvo (put-in/header/grid)
---@param playerObj IsoPlayer|nil
function GridInventory_BagDrop.isNestedLocked(target, playerObj)
    if not target or not target.getContainingItem or not playerObj then return false end
    local bagItem = target:getContainingItem()
    if not bagItem then return false end
    local bagContainer = bagItem:getContainer()
    if not bagContainer then return false end
    -- Bolsa direto num container raiz (inventário do jogador, cadáver, chão,
    -- veículo): acessível normalmente — não é a restrição de aninhamento.
    if not bagContainer:getContainingItem() then return false end
    -- Bolsa dentro de outra bolsa: só é acessível se a raiz da árvore for o
    -- inventário do personagem (bolsa em bolsa no inv do jogador funciona).
    if target.getOutermostContainer and target:getOutermostContainer() == playerObj:getInventory() then
        return false
    end
    return true
end

--- Transfere os itens do drag para o alvo da `bag`. Idempotente: se nada
--- transferiu, o drag NÃO é zerado e retorna false.
---@param page ISInventoryPage
---@param bag table { kind, page, target, ... }
---@return boolean true se pelo menos um item foi transferido
function GridInventory_BagDrop.transferToBag(page, bag)
    local drag = GridInventory_GlobalDrag
    if not drag or not drag.itemsData then return false end
    local target = GridInventory_BagDrop.getTarget(bag)
    if not target then return false end

    local sourceGrid = drag.sourceGrid
    local pane = page and page.inventoryPane
    local playerObj = getSpecificPlayer(page and page.player or dragPlayerNum(drag))
    local transferred = 0

    -- Bolsa aninhada NO MUNDO: o engine recusa a transferência — nem tentar
    -- (o autoSlot deixaria o item com posição fantasma no grid do alvo).
    if GridInventory_BagDrop.isNestedLocked(target, playerObj) then return false end

    -- Guarda do multi-select (mesma regra do canTransfer): a bolsa arrastada
    -- junto com outros itens não vira alvo de put-in no próprio footprint —
    -- o drop dessa seleção é posicionamento de grid.
    local bagItem = target:getContainingItem()
    if bagItem then
        for _, dData in ipairs(drag.itemsData) do
            if dData.itemObj == bagItem then return false end
        end
    end

    for _, dData in ipairs(drag.itemsData) do
        local item = dData and dData.itemObj
        if item and item.getContainer and item:getContainer() ~= target
            and not target:isInside(item)
            and item ~= target:getContainingItem()
            and target:isItemAllowed(item) then
            -- Mesma regra do vanilla (ISInventoryPage:canPutIn): favorito só
            -- vai pra container que está no inventário do personagem.
            if not (item:isFavorite() and not target:isInCharacterInventory(playerObj)) then
                local md = item:getModData()
                md.gridX = nil
                md.gridY = nil
                md.gridRot = false
                md.gridContainer = nil

                GridInventory_InTransit[item:getID()] = {
                    startedAt = getTimeInMillis(),
                    grid = sourceGrid,
                    source = item:getContainer(),
                    item = item,
                }

                GridClientNetwork.clearServerPosition(target, item:getID())

                if pane then
                    pane:transferItemsByWeight({ item }, target)
                else
                    -- Sem pane (janela flutuante): transferência instantânea via
                    -- ISInventoryTransferAction (mesmo padrão do AutoDrop).
                    local src = item:getContainer()
                    if src and playerObj then
                        local transfer = ISInventoryTransferAction:new(playerObj, item, src, target, 1)
                        transfer.maxTime = 0
                        ISTimedActionQueue.add(transfer)
                    end
                end
                transferred = transferred + 1
            end
        end
    end

    if transferred > 0 then
        if sourceGrid then sourceGrid.selectedItems = {} end
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
    end
    return transferred > 0
end

--- Se TODOS os itens arrastados podem entrar na bolsa (mesmas regras do
--- transferToBag). Só controla o FEEDBACK visual (drawPutInFeedback) — o drop
--- real é validado na transferência.
function GridInventory_BagDrop.canTransfer(bag)
    local drag = GridInventory_GlobalDrag
    if not drag or not drag.itemsData or #drag.itemsData == 0 then return false end
    local target = GridInventory_BagDrop.getTarget(bag)
    if not target then return false end
    -- Multi-select (bolsa + itens): a bolsa em trânsito não é alvo de put-in —
    -- o drop é posicionamento de grid, senão os itens companheiros seriam
    -- jogados pra dentro dela ao soltar sobre o próprio footprint.
    local bagItem = target:getContainingItem()
    if bagItem then
        for _, dData in ipairs(drag.itemsData) do
            if dData.itemObj == bagItem then return false end
        end
    end
    local playerObj = getSpecificPlayer((drag.sourceGrid and drag.sourceGrid.playerNum) or 0)
    -- Bolsa aninhada no mundo: sem feedback de put-in (o drop lá é recusado
    -- pelo engine — mostra o estado travado do grid em vez do "Put in").
    if GridInventory_BagDrop.isNestedLocked(target, playerObj) then return false end
    for _, dData in ipairs(drag.itemsData) do
        local item = dData and dData.itemObj
        if not (item and item.getContainer
                and item:getContainer() ~= target
                and not target:isInside(item)
                and item ~= target:getContainingItem()
                and target:isItemAllowed(item)) then
            return false
        end
        -- Mesma regra do vanilla (ISInventoryPage:canPutIn): favorito só vai
        -- pra container que está no inventário do personagem.
        if item:isFavorite() and not target:isInCharacterInventory(playerObj) then
            return false
        end
    end
    return true
end

--- Feedback visual de put-in DENTRO de um grid: mouse sobre o footprint de uma
--- bolsa que aceita o drag → destaque verde + label "Put in". Nada no header
--- (o drop no header é invisível por decisão) e nada se o item não pode entrar.
function GridInventory_BagDrop.drawPutInFeedback(grid)
    if not GridInventory_GlobalDrag or not GridInventory_GlobalDrag.itemsData then return end
    local bag = GridInventory_BagDrop.bagAtPoint(grid)
    if not bag or bag.kind ~= "item" or not bag.data then return end
    if not GridInventory_BagDrop.canTransfer(bag) then return end

    local cell = grid.cellSize or 32
    local px = CELL_PADDING + ((bag.data.x - 1) * cell)
    local py = CELL_PADDING + (grid.headerH or 0) + ((bag.data.y - 1) * cell)
    local pw = bag.data.w * cell
    local ph = bag.data.h * cell

    -- Footprint verde da bolsa: deixa claro que o item vai ENTRAR nela.
    grid:drawRect(px, py, pw, ph, 0.30, 0.30, 0.95, 0.40)
    grid:drawRectBorder(px, py, pw, ph, 0.95, 0.45, 1.0, 0.65)

    local label = getText("IGUI_InvPanel_PutIn") or "Put in"
    local tw = getTextManager():MeasureStringX(UIFont.Small, label)
    grid:drawRect(px + pw/2 - tw/2 - 4, py - 18, tw + 8, 16, 0.75, 0, 0, 0)
    grid:drawText(label, px + pw/2 - tw/2, py - 17, 1, 1, 1, 1, UIFont.Small)
end

--- Chamado todo frame por quem detecta o mouse solto: se houver drag ativo e
--- o mouse estiver sobre uma bolsa/header, transfere e retorna true.
--- Idempotente com o vanilla (dropItemsInContainer): se já transferiu, o
--- GridInventory_GlobalDrag já foi zerado e este caminho não faz nada.
---@param playerNum number|nil jogador dono do drag (filtra as páginas)
---@param bag table|nil bolsa já calculada (evita procurar 2x no mesmo frame)
---@return boolean true se transferiu (o drag global foi zerado)
function GridInventory_BagDrop.tryHandleMouseUp(playerNum, bag)
    if not GridInventory_GlobalDrag or not GridInventory_GlobalDrag.itemsData then return false end
    if isMouseButtonDown(0) then return false end

    bag = bag or GridInventory_BagDrop.findBagUnderMouse(playerNum)
    if not bag then return false end

    -- page pode ser nil (alvos da janela flutuante) — o transferToBag já
    -- resolve o jogador pelo sourceGrid do drag e usa ISInventoryTransferAction.
    return GridInventory_BagDrop.transferToBag(bag.page, bag)
end

-- Caminho vanilla: se o engine rotear o mouseUp pro botão da bolsa, o
-- dropItemsInContainer vanilla transfere e depois chama onMouseUp(0,0) no
-- grid origem (que só limpa o estado global). O marcador blindaria qualquer
-- caminho que tentasse reposicionar itens que o vanilla já moveu.
local og_dropItemsInContainer = ISInventoryPage.dropItemsInContainer
function ISInventoryPage:dropItemsInContainer(button)
    if GridInventory_GlobalDrag then
        GridInventory_GlobalDrag.handledByBag = button.inventory
    end
    return og_dropItemsInContainer(self, button)
end

return GridInventory_BagDrop
