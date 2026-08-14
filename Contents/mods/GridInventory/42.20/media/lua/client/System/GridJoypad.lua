--- GridJoypad.lua
--- Suporte a controle (joypad/gamepad) para as grids do GridInventory.
---
--- O foco do joypad continua na ISInventoryPage (igual ao vanilla). A página
--- roteia os eventos (onJoypadDown / onJoypadDir*) para este módulo, que
--- mantém um CURSOR VIRTUAL (col,row) por jogador, ancorado num GridRender.
---
--- Navegação:
---   D-pad / analógico: move o cursor dentro do grid — célula a célula ou com
---   "snap" entre itens (estilo Tarkov, opção do mod). Na borda do grid o
---   cursor salta pro grid vizinho do flexbox (o mais próximo na direção);
---   sem vizinho na horizontal, alterna entre inv <-> loot (vanilla); na
---   vertical, faz wrap dentro do próprio grid.
---
--- Botões (despachados pela ISInventoryPage_Hijack):
---   A = contexto do item sob o cursor (mesmo menu do clique direito);
---   B = abrir/selecionar mochila sob o cursor;
---   X = pegar/transferir o item sob o cursor (inv -> loot / loot -> inv);
---   Y = fechar o inventário;
---   LB/RB = trocar container (respeita os 3 modos do vanilla).
---
--- Os globais GridInventory_joypadCursorMode (1=snap, 2=célula) e
--- GridInventory_joypadAnalogSpeed (0..100) são sincronizados pelo
--- GridModOptions (mesmo padrão do GridInventory_uiScale).

local GridJoypad = {}

GridJoypad.cursors = GridJoypad.cursors or {}

local DEFAULT_MODE = 1    -- 1 = snap entre itens, 2 = célula a célula
local DEFAULT_SPEED = 50

local function getCursorMode()
    local m = GridInventory_joypadCursorMode
    if m == 2 then return 2 end
    return 1
end

local function getAnalogSpeed()
    local s = tonumber(GridInventory_joypadAnalogSpeed)
    if s == nil then return DEFAULT_SPEED end
    if s < 0 then return 0 end
    if s > 100 then return 100 end
    return s
end

local function clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

--- Cria o estado de cursor de um jogador (se ainda não existir).
local function cursorFor(playerNum)
    local cursor = GridJoypad.cursors[playerNum]
    if not cursor then
        cursor = {
            container = nil,
            gridIndex = 1,
            grid = nil,
            col = 1,
            row = 1,
            accX = 0,
            accY = 0,
            pollTime = 0,
        }
        GridJoypad.cursors[playerNum] = cursor
    end
    return cursor
end

--- Limita o cursor às dimensões do grid.
function GridJoypad.clampCursor(cursor, grid)
    if not grid or not grid.gridCore then return end
    cursor.col = clamp(cursor.col or 1, 1, grid.gridCore.width)
    cursor.row = clamp(cursor.row or 1, 1, grid.gridCore.height)
end

--- Re-ancora o cursor num GridRender específico (mesma posição, se couber).
function GridJoypad.anchorCursorTo(playerNum, grid)
    local cursor = cursorFor(playerNum)
    cursor.container = grid.inventoryContainer
    cursor.gridIndex = grid.gridIndex or 1
    cursor.grid = grid
    GridJoypad.clampCursor(cursor, grid)
    local page = grid.parent and grid.parent.inventoryPage
    if page then
        GridJoypad.ensureVisible(playerNum, page, grid, cursor.col, cursor.row)
    end
end

--- Re-ancora o cursor no container ATIVO do painel da página.
--- Usado ao ganhar foco e após trocar container (LB/RB, mochila clicada).
function GridJoypad.reanchorToActive(playerNum, page)
    local pane = page and page.inventoryPane
    if not pane or not pane.gridContainerUis then return end
    local activeInv = pane.inventory
    if not activeInv then return end
    local cursor = GridJoypad.cursors[playerNum]
    for _, g in ipairs(pane.gridContainerUis) do
        if not g.isOverflow and g.inventoryContainer == activeInv then
            GridJoypad.anchorCursorTo(playerNum, g)
            return
        end
    end
    -- Grid do container ativo ainda não nasceu (refresh pendente do
    -- refreshContainer): guarda o alvo; o resolveCursor re-ancora quando existir.
    if cursor then
        cursor.container = activeInv
        cursor.gridIndex = 1
        cursor.grid = nil
    end
end

--- Página ganhou foco do joypad: ancora o cursor no grid do container ativo.
function GridJoypad.anchorOnFocus(playerNum, page)
    GridJoypad.reanchorToActive(playerNum, page)
end

--- Resolve o GridRender vivo do cursor. Re-ancora se o grid atual foi
--- destruído (refreshContainer) ou se ainda não há cursor.
function GridJoypad.resolveCursor(playerNum, page)
    local pane = page and page.inventoryPane
    if not pane or not pane.gridContainerUis then return nil end
    local cursor = cursorFor(playerNum)

    -- Grid atual ainda vivo no painel?
    if cursor.grid then
        for _, g in ipairs(pane.gridContainerUis) do
            if g == cursor.grid then
                return cursor
            end
        end
    end

    -- Re-ancora no mesmo container/index (sobrevive ao rebuild das grids).
    if cursor.container then
        for _, g in ipairs(pane.gridContainerUis) do
            if g.inventoryContainer == cursor.container
                and (cursor.gridIndex or 1) == (g.gridIndex or 1) then
                cursor.grid = g
                GridJoypad.clampCursor(cursor, g)
                return cursor
            end
        end
    end

    -- Fallback: grid do container ativo do painel.
    local activeInv = pane.inventory
    for _, g in ipairs(pane.gridContainerUis) do
        if not g.isOverflow and g.inventoryContainer == activeInv then
            cursor.container = g.inventoryContainer
            cursor.gridIndex = g.gridIndex or 1
            cursor.grid = g
            GridJoypad.clampCursor(cursor, g)
            return cursor
        end
    end
    return nil
end

--- O cursor deste jogador está sobre `grid` (usado pelo render)?
function GridJoypad.isCursorOn(grid)
    local playerNum = grid.playerNum
    local cursor = GridJoypad.cursors[playerNum]
    if not cursor then return false end
    if cursor.grid ~= grid then
        -- Re-resolve: o grid pode ter sido reconstruído (refreshContainer).
        local page = grid.parent and grid.parent.inventoryPage
        if not page then return false end
        GridJoypad.resolveCursor(playerNum, page)
        cursor = GridJoypad.cursors[playerNum]
        if not cursor or cursor.grid ~= grid then return false end
    end
    -- Só desenha com o painel como foco atual (menu de contexto aberto esconde).
    local focus = getFocusForPlayer(playerNum)
    return focus == (grid.parent and grid.parent.inventoryPage)
end

--- Varre na direção (dx,dy) a partir da célula atual procurando o PRÓXIMO
--- item (pula o item que o cursor está em cima — move "de item em item").
--- Retorna a célula de entrada do item achado (borda da direção).
function GridJoypad.scanForItem(grid, fromCol, fromRow, dx, dy)
    if not grid or not grid.gridCore or not grid.gridCore.cells then return nil end
    local skipId = grid.gridCore.cells[fromCol] and grid.gridCore.cells[fromCol][fromRow]
    local c, r = fromCol + dx, fromRow + dy
    while c >= 1 and c <= grid.gridCore.width and r >= 1 and r <= grid.gridCore.height do
        local id = grid.gridCore.cells[c] and grid.gridCore.cells[c][r]
        if id and id ~= skipId then
            local d = grid.gridCore.items[id]
            if d and d.itemObj then
                if dx == 1 then
                    return d.x, r
                elseif dx == -1 then
                    return d.x + d.w - 1, r
                elseif dy == 1 then
                    return c, d.y
                else
                    return c, d.y + d.h - 1
                end
            end
        end
        c = c + dx
        r = r + dy
    end
    return nil
end

--- Procura o item mais próximo na COLUNA (vertical=true) ou LINHA do grid,
--- partindo da célula (col,row). Retorna célula do item (sem mudança se vazio).
function GridJoypad.snapToLineItem(grid, col, row, vertical)
    if not grid or not grid.gridCore or not grid.gridCore.cells then return col, row end
    local bestD, bestC, bestR = math.huge, col, row
    if vertical then
        for r = 1, grid.gridCore.height do
            local id = grid.gridCore.cells[col] and grid.gridCore.cells[col][r]
            if id then
                local d = grid.gridCore.items[id]
                if d and d.itemObj then
                    local dist = math.abs(r - row)
                    if dist < bestD then
                        bestD, bestC, bestR = dist, col, r
                    end
                end
            end
        end
    else
        for c = 1, grid.gridCore.width do
            local id = grid.gridCore.cells[c] and grid.gridCore.cells[c][row]
            if id then
                local d = grid.gridCore.items[id]
                if d and d.itemObj then
                    local dist = math.abs(c - col)
                    if dist < bestD then
                        bestD, bestC, bestR = dist, c, row
                    end
                end
            end
        end
    end
    return bestC, bestR
end

--- Acha o grid vizinho do painel na direção (dx,dy) — o mais próximo no eixo,
--- com sobreposição no eixo perpendicular (layout real do flexbox).
function GridJoypad.findNeighbor(grid, dx, dy)
    local pane = grid.parent
    if not pane or not pane.gridContainerUis then return nil end
    local gx = grid.baseX or grid:getX()
    local gy = grid.baseY or grid:getY()
    local gRight = gx + grid.width
    local gBottom = gy + grid.height
    local best, bestGap = nil, math.huge
    for _, h in ipairs(pane.gridContainerUis) do
        if h ~= grid and h:getIsVisible() then
            local hx = h.baseX or h:getX()
            local hy = h.baseY or h:getY()
            local hRight = hx + h.width
            local hBottom = hy + h.height
            local gap, ok
            if dx == 1 then
                gap = hx - gRight
                ok = gap >= 0 and (hy < gBottom and hBottom > gy)
            elseif dx == -1 then
                gap = gx - hRight
                ok = gap >= 0 and (hy < gBottom and hBottom > gy)
            elseif dy == 1 then
                gap = hy - gBottom
                ok = gap >= 0 and (hx < gRight and hRight > gx)
            else
                gap = gy - hBottom
                ok = gap >= 0 and (hx < gRight and hRight > gx)
            end
            if ok and gap < bestGap then
                best, bestGap = h, gap
            end
        end
    end
    return best
end

--- Rolagem do pane para manter a célula (col,row) do grid visível.
function GridJoypad.ensureVisible(playerNum, page, grid, col, row)
    local pane = page and page.inventoryPane
    if not pane or not grid or not pane.setYScroll then return end
    local cellX = (grid.baseX or grid:getX()) + grid.gridPadding + ((col - 1) * grid.cellSize)
    local cellY = (grid.baseY or grid:getY()) + grid.gridPadding + (grid.headerH or 0) + ((row - 1) * grid.cellSize)
    local cellH = grid.cellSize

    local viewTop = 0 - pane:getYScroll()
    local paneH = pane.height or pane:getHeight()
    if cellY < viewTop then
        pane:setYScroll(0 - (cellY - 8))
    elseif cellY + cellH > viewTop + paneH - 4 then
        pane:setYScroll(0 - (cellY + cellH - paneH))
    end

    if pane.setXScroll then
        local viewLeft = 0 - pane:getXScroll()
        local paneW = pane.width or pane:getWidth()
        if cellX < viewLeft then
            pane:setXScroll(0 - (cellX - 8))
        elseif cellX + grid.cellSize > viewLeft + paneW - 4 then
            pane:setXScroll(0 - (cellX + grid.cellSize - paneW))
        end
    end
end

--- Move o cursor na direção (dx,dy): célula/snap dentro do grid, e na borda
--- navega para o grid vizinho, alterna inv<->loot ou faz wrap (vanilla).
function GridJoypad.handleDir(playerNum, page, dx, dy)
    local cursor = GridJoypad.resolveCursor(playerNum, page)
    if not cursor or not cursor.grid then return false end
    local grid = cursor.grid

    local nc = cursor.col + dx
    local nr = cursor.row + dy
    local inBounds = nc >= 1 and nc <= grid.gridCore.width
        and nr >= 1 and nr <= grid.gridCore.height

    if not inBounds then
        return GridJoypad.boundary(playerNum, page, cursor, grid, dx, dy)
    end

    -- Snap entre itens (opção): pulando direto pro próximo item na direção.
    if getCursorMode() == 1 then
        if dx ~= 0 then
            local sc, sr = GridJoypad.scanForItem(grid, cursor.col, cursor.row, dx, 0)
            if sc then nc, nr = sc, sr end
        elseif dy ~= 0 then
            local sc, sr = GridJoypad.scanForItem(grid, cursor.col, cursor.row, 0, dy)
            if sc then nc, nr = sc, sr end
        end
    end

    cursor.col, cursor.row = nc, nr
    GridJoypad.ensureVisible(playerNum, page, grid, nc, nr)
    return true
end

--- Navegação na BORDA do grid: vizinho no painel -> inv/loot (horizontal) ->
--- wrap dentro do próprio grid (vertical).
function GridJoypad.boundary(playerNum, page, cursor, grid, dx, dy)
    -- 1) Grid vizinho no mesmo painel (mais próximo na direção do flexbox).
    local neighbor = GridJoypad.findNeighbor(grid, dx, dy)
    if neighbor then
        GridJoypad.anchorCursorTo(playerNum, neighbor)
        local nc, nr = cursor.col, cursor.row
        if dx == 1 then
            nc, nr = 1, clamp(nr, 1, neighbor.gridCore.height)
            if getCursorMode() == 1 then nc, nr = GridJoypad.snapToLineItem(neighbor, 1, nr, true) end
        elseif dx == -1 then
            nc, nr = neighbor.gridCore.width, clamp(nr, 1, neighbor.gridCore.height)
            if getCursorMode() == 1 then nc, nr = GridJoypad.snapToLineItem(neighbor, neighbor.gridCore.width, nr, true) end
        elseif dy == 1 then
            nc, nr = clamp(nc, 1, neighbor.gridCore.width), 1
            if getCursorMode() == 1 then nc, nr = GridJoypad.snapToLineItem(neighbor, nc, 1, false) end
        else
            nc, nr = clamp(nc, 1, neighbor.gridCore.width), neighbor.gridCore.height
            if getCursorMode() == 1 then nc, nr = GridJoypad.snapToLineItem(neighbor, nc, neighbor.gridCore.height, false) end
        end
        cursor.col, cursor.row = nc, nr
        GridJoypad.ensureVisible(playerNum, page, neighbor, nc, nr)
        return true
    end

    -- 2) Horizontal sem vizinho: alterna inv <-> loot (vanilla).
    if dx ~= 0 then
        local inv = getPlayerInventory(playerNum)
        local loot = getPlayerLoot(playerNum)
        local other = nil
        if page == loot then
            other = inv
        elseif page == inv then
            other = loot
        end
        if other then
            setJoypadFocus(playerNum, other)
            return true
        end
    end

    -- 3) Wrap dentro do próprio grid (mesma linha/coluna, outro extremo).
    local nc, nr = cursor.col, cursor.row
    if dy == 1 then
        nc, nr = cursor.col, 1
        if getCursorMode() == 1 then nc, nr = GridJoypad.snapToLineItem(grid, nc, 1, true) end
    elseif dy == -1 then
        nc, nr = cursor.col, grid.gridCore.height
        if getCursorMode() == 1 then nc, nr = GridJoypad.snapToLineItem(grid, nc, grid.gridCore.height, true) end
    elseif dx == 1 then
        nc, nr = 1, cursor.row
        if getCursorMode() == 1 then nc, nr = GridJoypad.snapToLineItem(grid, 1, nr, false) end
    elseif dx == -1 then
        nc, nr = grid.gridCore.width, cursor.row
        if getCursorMode() == 1 then nc, nr = GridJoypad.snapToLineItem(grid, grid.gridCore.width, nr, false) end
    end
    cursor.col, cursor.row = nc, nr
    GridJoypad.ensureVisible(playerNum, page, grid, nc, nr)
    return true
end

--- Item sob o cursor. Retorna (grid, itemObj, itemData).
function GridJoypad.itemAtCursor(playerNum, page)
    local cursor = GridJoypad.resolveCursor(playerNum, page)
    if not cursor or not cursor.grid or not cursor.grid.gridCore then return nil, nil, nil end
    local id = cursor.grid.gridCore.cells[cursor.col] and cursor.grid.gridCore.cells[cursor.col][cursor.row]
    if id then
        local d = cursor.grid.gridCore.items[id]
        if d and d.itemObj then
            return cursor.grid, d.itemObj, d
        end
    end
    return cursor.grid, nil, nil
end

--- Botão A: contexto do item sob o cursor (mesmo menu do clique direito).
function GridJoypad.openContext(playerNum, page)
    if JoypadState.disableInvInteraction then return end
    if UIManager.getSpeedControls() and UIManager.getSpeedControls():getCurrentGameSpeed() == 0 then return end
    local playerObj = getSpecificPlayer(playerNum)
    if playerObj and playerObj:isAsleep() then return end

    local cursor = GridJoypad.resolveCursor(playerNum, page)
    if not cursor or not cursor.grid then return end
    local grid = cursor.grid
    if grid:isUnderCollapsedPage() then return end
    if grid:isLocked() then return end

    -- BUSCA (Tarkov): item oculto (ou célula vazia num container a vasculhar)
    -- inicia/retoma a vasculhada, sem menu.
    if grid:needsSearch() then
        local id = grid.gridCore.cells[cursor.col] and grid.gridCore.cells[cursor.col][cursor.row]
        local d = id and grid.gridCore.items[id]
        if (not id) or (d and d.itemObj and grid:isItemHidden(d.itemObj)) then
            grid:startSearch()
            return
        end
    end

    local itemObj = GridJoypad.itemAtCursor(playerNum, page)
    if not itemObj then return end

    local inv = itemObj:getContainer()
    local isInPlayerInv = inv and inv:isInCharacterInventory(getSpecificPlayer(playerNum)) or false
    local menu = ISInventoryPaneContextMenu.createMenu(playerNum, isInPlayerInv,
        { itemObj }, grid:getAbsoluteX() + 64, grid:getAbsoluteY() + 64, page)
    if menu then
        menu.origin = page
        menu.mouseOver = 1
        if menu.numOptions and menu.numOptions > 1 then
            setJoypadFocus(playerNum, menu)
        end
    end
end

--- Botão X: pegar/transferir o item sob o cursor (inv -> loot / loot -> inv).
function GridJoypad.grab(playerNum, page)
    if not page or not page.inventoryPane then return end
    if JoypadState.disableGrab then return end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or playerObj:isAsleep() then return end
    local itemObj = GridJoypad.itemAtCursor(playerNum, page)
    if not itemObj then return end

    -- Item pesado no loot: equipa em vez de tentar carregar (vanilla).
    if not page.onCharacter and isForceDropHeavyItem(itemObj) then
        ISInventoryPaneContextMenu.equipHeavyItem(playerObj, itemObj)
        return
    end

    if page.onCharacter then
        ISInventoryPaneContextMenu.onPutItems({ itemObj }, playerNum)
    else
        ISInventoryPaneContextMenu.onGrabItems({ itemObj }, playerNum)
    end
end

--- Botão B: se o item sob o cursor é uma mochila/container, abre/seleciona o
--- grid do conteúdo dela (ou seleciona o container no painel vanilla).
function GridJoypad.activateB(playerNum, page)
    local itemObj = GridJoypad.itemAtCursor(playerNum, page)
    if not itemObj then return end
    local innerInv = itemObj.getInventory and itemObj:getInventory()
    if not innerInv then return end
    local pane = page.inventoryPane
    if pane and pane.gridContainerUis then
        for _, g in ipairs(pane.gridContainerUis) do
            if not g.isOverflow and g.inventoryContainer == innerInv then
                GridJoypad.anchorCursorTo(playerNum, g)
                return
            end
        end
    end
    -- Sem grid interno renderizado (modo single-container): seleciona o
    -- container vanilla (abre a grid dele no frame seguinte).
    if page.backpacks then
        for _, btn in ipairs(page.backpacks) do
            if btn.inventory == innerInv then
                page:selectContainer(btn)
                return
            end
        end
    end
end

--- Polling do analógico (por frame, quando o painel tem foco): move o cursor
--- com o stick na velocidade da opção do mod.
function GridJoypad.pollAnalog(playerNum, page)
    local focus = getFocusForPlayer(playerNum)
    if focus ~= page then return end
    local joypadData = getJoypadData(playerNum)
    if not joypadData or joypadData.id == nil then return end

    local ax = getJoypadAimingAxisX and getJoypadAimingAxisX(joypadData.id) or 0
    local ay = getJoypadAimingAxisY and getJoypadAimingAxisY(joypadData.id) or 0
    local dead = 0.35
    local mx = math.abs(ax) > dead and ax or 0
    local my = math.abs(ay) > dead and ay or 0

    local cursor = GridJoypad.resolveCursor(playerNum, page)
    if not cursor then return end

    if mx == 0 and my == 0 then
        cursor.accX, cursor.accY = 0, 0
        return
    end

    local now = getTimestampMs()
    local last = cursor.pollTime or now
    local dt = clamp((now - last) / 1000, 0.001, 0.05)
    cursor.pollTime = now

    local speed = getAnalogSpeed() / 100
    local rate = math.max(0.05, 0.3 * speed) -- segundos por célula (velocidade máx)
    local mag = math.max(math.abs(mx), math.abs(my))
    local stepPerSec = (1 / rate) * (0.4 + 0.6 * mag)

    cursor.accX = (cursor.accX or 0) + mx * stepPerSec * dt
    cursor.accY = (cursor.accY or 0) + my * stepPerSec * dt

    while math.abs(cursor.accX) >= 1 do
        local step = cursor.accX >= 0 and 1 or -1
        GridJoypad.handleDir(playerNum, page, step, 0)
        cursor.accX = cursor.accX - step
    end
    while math.abs(cursor.accY) >= 1 do
        local step = cursor.accY >= 0 and 1 or -1
        GridJoypad.handleDir(playerNum, page, 0, step)
        cursor.accY = cursor.accY - step
    end
end

return GridJoypad
