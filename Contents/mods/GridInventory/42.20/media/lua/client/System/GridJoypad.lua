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
--- O cursor se move célula a célula (D-pad) — sem snap entre itens.

local GridJoypad = {}

-- GridContainer é um MÓDULO (require), não um global — sem ele o compatKey do
-- grab fica nil e o reorder do MESMO grid não stacka (canPlaceItem pula o
-- branch de empilhamento).
local okGC, GridContainer = pcall(require, "DataModel/GridContainer")

GridJoypad.cursors = GridJoypad.cursors or {}

--- Modo NAVEGAÇÃO (bumper segurado): segurar o bumper ~250ms entra num modo
--- em que o D-pad pula de grid em grid com um overlay de ícones estilo
--- building/crafting; soltar o bumper confirma a posição. O bumper segurado
--- escolhe o painel: LB = INV, RB = LOOT (o foco vai pro painel do bumper ao
--- ativar, se ainda não estiver nele). O tap (< 250ms) — decidido no SOLTAR —
--- continua trocando inv<->loot / ciclando container: segurar o bumper pra
--- navegar NÃO dispara mais a ação de troca/ciclo no meio do aperto.
GridJoypad.navs = GridJoypad.navs or {}

--- Modo PAPERDOLL (LB+RB segurados): navegação por slots do PaperDoll.
GridJoypad.pds = GridJoypad.pds or {}

--- DRAG de joypad (A = pegar/soltar, X = rotacionar, B = cancelar/contexto).
--- Reusa GridInventory_GlobalDrag (ghost/preview) com o flag `joypad=true`;
--- o drop (soltar com A) é cometido chamando o onMouseUp do grid do cursor com
--- as coordenadas de tela da célula — reaproveita TODA a lógica de drop existente
--- (mesmo grid, cross-grid, pilha única, paperdoll, put-in).
GridJoypad.drag = { active = false, playerNum = nil }

--- Modo PEEL/HOLD do A sobre uma PILHA: apertar A numa pilha não pega tudo na
--- hora — registra o press e aguarda. O tap (< A_HOLD_MS, decidido no release)
--- pega 1 item; tap repetido sobre a MESMA pilha acumula (+1); segurar A
--- (>= A_HOLD_MS) pega a pilha inteira. O polling é feito no GridJoypad.pollA.
GridJoypad.aPress = { active = false, playerNum = nil }

--- STACK PICKER aberto pelo controle (Select = Joypad.Back): quando ativo, o
--- D-pad navega a lista da janela em vez de mover o cursor das grids.
GridJoypad.picker = { playerNum = nil }

local NAV_HOLD_MS = 250
--- Tempo de hold do A pra pegar a pilha inteira (tap abaixo disso = 1 item).
local A_HOLD_MS = 300
local DPAID_TEXTURES = {
    ["left"] = "DPadLeft",
    ["right"] = "DPadRight",
    ["up"] = "DPadUp",
    ["down"] = "DPadDown",
}

local function clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

--- Debug do joypad: `GridInventory_joypadDebug = true` no console liga os prints.
local function joyDebug(...)
    if GridInventory_joypadDebug then
        print("[GridJoypad]", ...)
    end
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
    joyDebug("anchorCursorTo p" .. playerNum .. " -> ", tostring(grid.name or grid.inventoryContainer),
        "@", cursor.col, cursor.row)
    if page then
        GridJoypad.ensureVisible(playerNum, page, grid, cursor.col, cursor.row)
    end
end

--- Re-ancora o cursor no container ATIVO do painel da página.
--- Usado ao ganhar foco e após trocar container (LB/RB, mochila clicada).
--- `home` (ciclo de container): entra em (1,1) do grid, como o switchFocus.
function GridJoypad.reanchorToActive(playerNum, page, home)
    local pane = page and page.inventoryPane
    if not pane or not pane.gridContainerUis then return end
    local activeInv = pane.inventory
    if not activeInv then return end
    local cursor = GridJoypad.cursors[playerNum]
    for _, g in ipairs(pane.gridContainerUis) do
        if not g.isOverflow and g.inventoryContainer == activeInv then
            joyDebug("reanchorToActive p" .. playerNum .. " ativo=" .. tostring(activeInv)
                .. " home=" .. tostring(home) .. " -> grid ", tostring(g.name or g.inventoryContainer))
            GridJoypad.anchorCursorTo(playerNum, g)
            if home then
                cursor.col, cursor.row = 1, 1
                GridJoypad.ensureVisible(playerNum, page, g, cursor.col, cursor.row)
            end
            return
        end
    end
    -- Grid do container ativo ainda não nasceu (refresh pendente do
    -- refreshContainer): guarda o alvo; o resolveCursor re-ancora quando existir.
    if cursor then
        joyDebug("reanchorToActive: grid do ativo (" .. tostring(activeInv)
            .. ") não existe ainda; guarda alvo")
        cursor.container = activeInv
        cursor.gridIndex = 1
        cursor.grid = nil
    end
end

--- Página ganhou foco do joypad: ancora o cursor no grid do container ativo.
function GridJoypad.anchorOnFocus(playerNum, page)
    GridJoypad.reanchorToActive(playerNum, page)
end

--- LB/RB: se a página JÁ é o painel alvo, cicla pro próximo container do
--- painel (vanilla selectNextContainer) e re-ancora o cursor nele; senão troca
--- o foco pro painel alvo com o cursor em (1,1) (switchFocus home).
--- O re-press do bumper no painel alvo não fica mais preso re-anchorando o
--- cursor em (1,1) do MESMO container — ele avança pro container seguinte, o
--- que deixa o cursor alcançar as outras grids do painel.
function GridJoypad.shoulderCycle(playerNum, page, targetPage)
    if not targetPage then return end
    if page == targetPage then
        if targetPage.selectNextContainer then
            targetPage:selectNextContainer()
        end
        GridJoypad.reanchorToActive(playerNum, targetPage, true)
    else
        GridJoypad.switchFocus(playerNum, page, targetPage, true)
    end
end

--- Resolve o GridRender vivo do cursor. Re-ancora se o grid atual foi
--- destruído (refreshContainer) ou se ainda não há cursor.
--- `preserve` (render): NUNCA força o cursor pro container ATIVO do painel.
--- Sem ele, o render do painel OPOSTO sequestraria o cursor de volta pro grid
--- do container selecionado quando ele está num grid não-ativo (mochila/chão) —
--- o usuário via o cursor "jogado de volta pro 1,1 do container alvo".
function GridJoypad.resolveCursor(playerNum, page, preserve)
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
                if cursor.grid ~= g then
                    joyDebug("resolveCursor RE-ANCORA por container: ", cursor.container,
                        "@", cursor.col, cursor.row)
                end
                cursor.grid = g
                GridJoypad.clampCursor(cursor, g)
                return cursor
            end
        end
    end

    -- Fallback: grid do container ativo do painel. SÓ para movimento
    -- (handleDir/navDir); o render usa preserve pra não sequestrar o cursor.
    if not preserve then
        local activeInv = pane.inventory
        for _, g in ipairs(pane.gridContainerUis) do
            if not g.isOverflow and g.inventoryContainer == activeInv then
                joyDebug("resolveCursor FALLBACK p" .. playerNum .. " -> ativo "
                    .. tostring(activeInv), tostring(g.name or g.inventoryContainer))
                cursor.container = g.inventoryContainer
                cursor.gridIndex = g.gridIndex or 1
                cursor.grid = g
                GridJoypad.clampCursor(cursor, g)
                return cursor
            end
        end
    end
    return nil
end

--- O cursor deste jogador está sobre `grid` (usado pelo render)?
function GridJoypad.isCursorOn(grid)
    local playerNum = grid.playerNum
    -- Modo PaperDoll ativo: o cursor das grids fica escondido.
    if GridJoypad.isPaperdollActive(playerNum) then return false end
    local cursor = GridJoypad.cursors[playerNum]
    if not cursor then return false end
    if cursor.grid ~= grid then
        -- Re-resolve SEM FORÇAR o container ativo (preserve=true): só re-acha o
        -- MESMO grid se ele foi reconstruído (refreshContainer). O render não
        -- pode sequestrar o cursor pro container selecionado quando ele está
        -- num grid não-ativo do painel.
        local page = grid.parent and grid.parent.inventoryPage
        if not page then return false end
        GridJoypad.resolveCursor(playerNum, page, true)
        cursor = GridJoypad.cursors[playerNum]
        if not cursor or cursor.grid ~= grid then return false end
    end
    -- Só desenha com o painel como foco atual (menu de contexto aberto esconde).
    local focus = getFocusForPlayer(playerNum)
    return focus == (grid.parent and grid.parent.inventoryPage)
end

--- O cursor virtual está VISÍVEL neste momento (ancorado num grid do painel
--- com foco)? Usado pelo tooltip pra suprimir o tooltip do mouse quando o
--- joypad está controlando o cursor.
function GridJoypad.isCursorVisible(playerNum)
    local cursor = GridJoypad.cursors[playerNum]
    if not cursor or not cursor.grid then return false end
    local page = cursor.grid.parent and cursor.grid.parent.inventoryPage
    if not page then return false end
    return getFocusForPlayer(playerNum) == page
end

--- Acha o grid vizinho do painel na direção (dx,dy).
--- Usa o CENTRO do retângulo de cada grid (estilo ISPanelJoypad do vanilla):
--- o candidato precisa estar estritamente além do grid na direção dominante
--- (dx ou dy), e o melhor é o de menor distância no eixo dominante, com a
--- distância no outro eixo como desempate. Isso cobre o flexbox em várias
--- linhas (grid de baixo alcançável pela borda de baixo do grid de cima), o
--- que a checagem antiga (overlap vertical completo) não cobria — era a causa
--- do "cursor cego" no multi-grid com bolsa + inv principal do jogador.
---
--- FALLBACK: grids EMPILHADAS na vertical com o mesmo centro X (ddx==0 indo
--- pra direita/esquerda, ex.: o chão nascendo logo abaixo do grid do container
--- com a mesma largura) são excluídas pelo filtro estrito, e o cursor caía no
--- switchFocus pro OUTRO painel em vez de ir pro chão. Se não há candidato
--- estrito na horizontal, o fallback aceita o grid com o mesmo centro X — assim
--- a pilha vertical ainda é alcançável sem "pular pra trás" nem quebrar o
--- alternar inv<->loot num painel de grid único.
--- Nota: visibilidade é decidida por flag Lua (`joypadHidden`), nunca pelo
--- Java — grids em gridContainerUis estão sempre renderizadas.
function GridJoypad.findNeighbor(grid, dx, dy)
    local pane = grid.parent
    if not pane or not pane.gridContainerUis then return nil end
    local gx = grid.baseX or grid:getX()
    local gy = grid.baseY or grid:getY()
    local gcX = gx + grid.width / 2
    local gcY = gy + grid.height / 2
    local best, bestScore = nil, math.huge
    local fallback, fallbackScore = nil, math.huge
    for _, h in ipairs(pane.gridContainerUis) do
        if h ~= grid and h.joypadHidden ~= true then
            local hx = h.baseX or h:getX()
            local hy = h.baseY or h:getY()
            local hcX = hx + h.width / 2
            local hcY = hy + h.height / 2
            local ddx = hcX - gcX
            local ddy = hcY - gcY
            -- Precisa estar estritamente além na direção dominante (na direção
            -- do movimento o candidato não pode estar "atrás" do grid atual).
            local isAhead = true
            if dx == 1 and ddx <= 0 then isAhead = false end
            if dx == -1 and ddx >= 0 then isAhead = false end
            if dy == 1 and ddy <= 0 then isAhead = false end
            if dy == -1 and ddy >= 0 then isAhead = false end
            local score
            if dx ~= 0 then
                score = math.abs(ddx) * 1000 + math.abs(ddy)
            else
                score = math.abs(ddy) * 1000 + math.abs(ddx)
            end
            if isAhead then
                if score < bestScore then
                    best, bestScore = h, score
                end
            else
                -- Fallback SÓ na HORIZONTAL: grid empilhado na VERTICAL com o
                -- mesmo centro X (ddx==0) que o filtro estrito exclui — ex.: o
                -- chão nascendo abaixo do grid do container com a mesma
                -- largura. Na VERTICAL não há fallback: um grid na MESMA linha
                -- não é alcançável pra cima/baixo (senão o cursor "pularia de
                -- lado" em vez de ir pro grid de baixo).
                if dx ~= 0 and math.abs(ddx) < 1 then
                    if score < fallbackScore then
                        fallback, fallbackScore = h, score
                    end
                end
            end
        end
    end
    return best or fallback
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
    -- Sobre um FOOTPRINT: salta pra borda do item na direção (ex.: um item 6x1
    -- anda de UMA vez até a célula após o fim dele, em vez de 6 toques).
    if grid.gridCore and grid.gridCore.cells then
        local id = grid.gridCore.cells[cursor.col] and grid.gridCore.cells[cursor.col][cursor.row]
        if id then
            local d = grid.gridCore.items[id]
            if d and d.x and d.y and d.w and d.h then
                if dx == 1 then nc = d.x + d.w
                elseif dx == -1 then nc = d.x - 1
                elseif dy == 1 then nr = d.y + d.h
                elseif dy == -1 then nr = d.y - 1 end
            end
        end
    end
    local inBounds = nc >= 1 and nc <= grid.gridCore.width
        and nr >= 1 and nr <= grid.gridCore.height

    if not inBounds then
        return GridJoypad.boundary(playerNum, page, cursor, grid, dx, dy)
    end

    cursor.col, cursor.row = nc, nr
    GridJoypad.ensureVisible(playerNum, page, grid, nc, nr)
    return true
end

--- Navegação na BORDA do grid: vizinho no painel -> inv/loot (horizontal) ->
--- wrap dentro do próprio grid (vertical). Com `noWrap=true` (modo navegação
--- do RB segurado) o wrap é suprimido: na vertical sem vizinho o cursor
--- simplesmente não se move.
function GridJoypad.boundary(playerNum, page, cursor, grid, dx, dy, noWrap)
    -- 1) Grid vizinho no mesmo painel (mais próximo na direção do flexbox).
    local neighbor = GridJoypad.findNeighbor(grid, dx, dy)
    if neighbor then
        joyDebug("boundary p" .. playerNum .. " (" .. dx .. "," .. dy .. ") vizinho: ",
            tostring(grid.name or grid.inventoryContainer), " -> ",
            tostring(neighbor.name or neighbor.inventoryContainer))
        GridJoypad.anchorCursorTo(playerNum, neighbor)
        -- Modo NAVEGAÇÃO (noWrap): o grid alvo vira o container SELECIONADO do
        -- painel (mesmo fluxo de clicar no botão da mochila — destaque na
        -- coluna de containers, outline, etc). Só quando muda de container.
        if noWrap and page and page.selectButtonForContainer
            and neighbor.inventoryContainer
            and page.inventoryPane
            and neighbor.inventoryContainer ~= page.inventoryPane.inventory then
            pcall(page.selectButtonForContainer, page, neighbor.inventoryContainer)
        end
        local nc, nr = cursor.col, cursor.row
        if noWrap then
            -- Modo NAVEGAÇÃO: posição PADRONIZADA (1,1) do grid alvo, pra
            -- memória muscular (não entra "do lado de onde veio").
            nc, nr = 1, 1
        elseif dx == 1 then
            nc, nr = 1, clamp(nr, 1, neighbor.gridCore.height)
        elseif dx == -1 then
            nc, nr = neighbor.gridCore.width, clamp(nr, 1, neighbor.gridCore.height)
        elseif dy == 1 then
            nc, nr = clamp(nc, 1, neighbor.gridCore.width), 1
        else
            nc, nr = clamp(nc, 1, neighbor.gridCore.width), neighbor.gridCore.height
        end
    cursor.col, cursor.row = nc, nr
    if GridInventory_joypadDebug and GridJoypad.drag.active then
        print("[GridJoypad] handleDir durante drag: cursor=", cursor.col, cursor.row)
    end
    GridJoypad.ensureVisible(playerNum, page, grid, nc, nr)
    return true
end

    -- 2) Horizontal sem vizinho: alterna inv <-> loot (vanilla). O cursor
    -- pula pro lado de entrada do painel alvo (acompanha a troca de foco).
    -- No modo NAVEGAÇÃO (noWrap) entra em (1,1) — comportamento padronizado.
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
            return GridJoypad.switchFocus(playerNum, page, other, noWrap and true or false)
        end
    end

    -- 3) Wrap dentro do próprio grid (mesma linha/coluna, outro extremo).
    if noWrap then return false end
    local nc, nr = cursor.col, cursor.row
    if dy == 1 then
        nc, nr = cursor.col, 1
    elseif dy == -1 then
        nc, nr = cursor.col, grid.gridCore.height
    elseif dx == 1 then
        nc, nr = 1, cursor.row
    elseif dx == -1 then
        nc, nr = grid.gridCore.width, cursor.row
    end
    cursor.col, cursor.row = nc, nr
    GridJoypad.ensureVisible(playerNum, page, grid, nc, nr)
    return true
end

--- Troca o foco do joypad inv <-> loot e posiciona o cursor virtual.
--- `home=true` (LB/RB): cursor em (1,1) do grid do container ativo do painel
--- alvo. `home=false` (borda do grid): o cursor entra pelo lado de ENTRADA do
--- painel — vindo do inv (à esquerda) entra no loot pela coluna 1; vindo do
--- loot (à direita) entra no inv pela última coluna.
function GridJoypad.switchFocus(playerNum, fromPage, toPage, home)
    if not toPage then return false end
    setJoypadFocus(playerNum, toPage)
    joyDebug("switchFocus p" .. playerNum .. " -> ", tostring(toPage.onCharacter ~= nil and (toPage.onCharacter and "inv" or "loot") or toPage),
        " home=" .. tostring(home))

    local pane = toPage.inventoryPane
    if not pane or not pane.gridContainerUis then return true end
    local activeInv = pane.inventory
    local cursor = cursorFor(playerNum)
    local target = nil
    for _, g in ipairs(pane.gridContainerUis) do
        if not g.isOverflow and g.inventoryContainer == activeInv then
            target = g
            break
        end
    end
    if not target then
        -- Grid do container ativo ainda não nasceu (refresh pendente): guarda o
        -- alvo; o resolveCursor re-ancora quando existir.
        cursor.container = activeInv
        cursor.gridIndex = 1
        cursor.grid = nil
        return true
    end

    cursor.container = activeInv
    cursor.gridIndex = target.gridIndex or 1
    cursor.grid = target
    local enterCol = 1
    local enterRow = 1
    if not home then
        local fromX = fromPage and (fromPage:getX() or 0) or 0
        local toX = toPage:getX() or fromX
        if toX <= fromX then enterCol = target.gridCore.width end
        enterRow = clamp(cursor.row or 1, 1, target.gridCore.height)
    end
    cursor.col = enterCol
    cursor.row = enterRow
    GridJoypad.ensureVisible(playerNum, toPage, target, cursor.col, cursor.row)
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

--- Item sob o cursor (só o item, sem o grid). Conveniência pros botões.
function GridJoypad.itemAtCursorOnly(playerNum, page)
    local _, itemObj = GridJoypad.itemAtCursor(playerNum, page)
    return itemObj
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

    local itemObj = GridJoypad.itemAtCursorOnly(playerNum, page)
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

--- O drag de joypad está ativo?
function GridJoypad.isDragging(playerNum)
    return GridJoypad.drag.active == true
end

--- Monta a ENTRADA de drag de um itemData do grid (sem alocar fora do loop).
--- Rotação = mData.rotated (flag do grid, confiável). O tamanho BASE é o par
--- d.w/d.h desrotacionado (ItemFootprint.getSize retorna o footprint ATUAL).
local function buildItemEntry(mData, mId)
    local rotated = mData.rotated or false
    local baseW, baseH = mData.w, mData.h
    if rotated then
        baseW, baseH = mData.h, mData.w
    end
    local compatKey = nil
    local stackInfo = nil
    local itemObj = mData.itemObj
    if GridContainer and GridContainer.getStackableCompatKey and itemObj then
        local okCK, ck = pcall(GridContainer.getStackableCompatKey, itemObj)
        if okCK then compatKey = ck end
        local okSI, si = pcall(function()
            return select(2, GridContainer.getStackInfo(itemObj))
        end)
        if okSI then stackInfo = si end
    end
    return {
        id = mId,
        itemObj = itemObj,
        originalX = mData.x,
        originalY = mData.y,
        originalW = baseW,
        originalH = baseH,
        grabOffsetX = 0,
        grabOffsetY = 0,
        rotated = rotated,
        compatKey = compatKey,
        stackInfo = stackInfo,
    }
end

--- Inicia o GridInventory_GlobalDrag do joypad a partir de uma lista de ids de
--- membros. `stackPeelLeaderId` (opcional) marca o drag como "peel de pilha":
--- com ele setado, um A sobre a MESMA pilha acumula +1 em vez de soltar.
local function startDrag(playerNum, grid, anchorId, memberIds, stackPeelLeaderId)
    local itemsData = {}
    local itemsMap = {}
    for _, mId in ipairs(memberIds) do
        local mData = grid.gridCore.items[mId]
        if mData and mData.itemObj then
            table.insert(itemsData, buildItemEntry(mData, mId))
            itemsMap[mId] = true
        end
    end
    if #itemsData == 0 then return false end
    GridInventory_GlobalDrag = {
        itemsData = itemsData,
        itemsMap = itemsMap,
        anchorId = anchorId,
        sourceGrid = grid,
        joypad = true,
    }
    -- IMPORTANTE: NÃO setar ISMouseDrag aqui — o vanilla ISInventoryPane:update
    -- resolve o drag quando o mouse não está segurado (onMouseUp), o que
    -- AUTOCOLOCARIA o item no próximo frame. O ISMouseDrag é setado só
    -- transitoriamente no placeDrag (pro drop cross-grid do onMouseUp).
    GridJoypad.drag = {
        active = true,
        playerNum = playerNum,
        startedAt = getTimestampMs(),
        stackPeelLeaderId = stackPeelLeaderId,
        stackPeelGrid = stackPeelLeaderId and grid or nil,
    }
    return true
end

--- TAP na pilha: pega UM membro (o 2º, preservando o líder) e marca o drag
--- como peel pra permitir acumular (+1) com novos taps.
local function peelOne(playerNum, grid, leaderId)
    local members = grid.gridCore:getStackMembers(leaderId)
    if #members <= 1 then
        startDrag(playerNum, grid, leaderId, { leaderId }, nil)
        return
    end
    local peelId = members[2]
    startDrag(playerNum, grid, peelId, { peelId }, leaderId)
    joyDebug("peelOne: pegou 1 item da pilha (", tostring(peelId), ")")
end

--- Acumula +1 item da pilha no drag atual (membro ainda não peelado).
--- Pula o LÍDER (members[1]) enquanto houver membros: o líder representa a
--- pilha no render do grid — se ele entra no drag, o grid esconde a pilha
--- inteira (some) mesmo ainda havendo itens. Só pega o líder quando é o
--- último item restante.
local function addStackMember(playerNum, grid, leaderId)
    local itemsMap = GridInventory_GlobalDrag and GridInventory_GlobalDrag.itemsMap
    if not itemsMap then return end
    local members = grid.gridCore:getStackMembers(leaderId)
    for i = 2, #members do
        local mId = members[i]
        if not itemsMap[mId] then
            local mData = grid.gridCore.items[mId]
            if mData and mData.itemObj then
                table.insert(GridInventory_GlobalDrag.itemsData, buildItemEntry(mData, mId))
                itemsMap[mId] = true
                joyDebug("addStackMember: +1 (", tostring(mId), ")")
            end
            return
        end
    end
    -- Sem membros disponíveis: pega o próprio líder (último item da pilha).
    if not itemsMap[leaderId] then
        local mData = grid.gridCore.items[leaderId]
        if mData and mData.itemObj then
            table.insert(GridInventory_GlobalDrag.itemsData, buildItemEntry(mData, leaderId))
            itemsMap[leaderId] = true
            joyDebug("addStackMember: +1 líder (", tostring(leaderId), ")")
        end
    end
end

--- HOLD com peel ativo: pega todo o RESTANTE da pilha (membros ainda não
--- peelados + o líder). O grid some (pilha esvaziada), o que é o esperado.
local function addRestOfStack(playerNum, grid, leaderId)
    local itemsMap = GridInventory_GlobalDrag and GridInventory_GlobalDrag.itemsMap
    if not itemsMap then return end
    local members = grid.gridCore:getStackMembers(leaderId)
    for i = 2, #members do
        local mId = members[i]
        if not itemsMap[mId] then
            local mData = grid.gridCore.items[mId]
            if mData and mData.itemObj then
                table.insert(GridInventory_GlobalDrag.itemsData, buildItemEntry(mData, mId))
                itemsMap[mId] = true
            end
        end
    end
    if not itemsMap[leaderId] then
        local mData = grid.gridCore.items[leaderId]
        if mData and mData.itemObj then
            table.insert(GridInventory_GlobalDrag.itemsData, buildItemEntry(mData, leaderId))
            itemsMap[leaderId] = true
        end
    end
    joyDebug("addRestOfStack: pegou o restante da pilha")
end

--- Botão A: PEGA o item sob o cursor (inicia o drag — o item fica preso no
--- cursor) ou, se já arrastando, SOLTA na célula do cursor (place).
--- Pilhas: tap = 1 item, tap repetido na mesma pilha = +1, hold = todos.
function GridJoypad.grab(playerNum, page)
    if GridJoypad.drag.active then
        -- Guarda de TEMPO: o engine pode re-enviar o A em rajada no mesmo
        -- instante (2º A imediato = mesmo clique). Um A deliberado de place
        -- (depois de mover o cursor) vem > 300ms depois. Não exige movimento —
        -- só descarta o eco imediato do clique.
        if GridJoypad.drag.startedAt and getTimestampMs() - GridJoypad.drag.startedAt < 300 then
            joyDebug("grab -> place IGNORADO (eco imediato do A, ",
                tostring(getTimestampMs() - GridJoypad.drag.startedAt), "ms)")
            return
        end
        -- Peel de pilha ativo: se o cursor ainda está sobre a MESMA pilha da
        -- origem, o A registra o press (tap = +1, hold = restante) em vez de
        -- soltar ou acumular +1 imediatamente.
        if GridJoypad.drag.stackPeelLeaderId then
            local cursor = GridJoypad.resolveCursor(playerNum, page)
            local cgrid = cursor and cursor.grid
            if cgrid and cgrid.gridCore and cgrid.gridCore.cells then
                local cid = cgrid.gridCore.cells[cursor.col] and cgrid.gridCore.cells[cursor.col][cursor.row]
                if cid == GridJoypad.drag.stackPeelLeaderId and cgrid == GridJoypad.drag.stackPeelGrid then
                    GridJoypad.aPress = {
                        active = true,
                        playerNum = playerNum,
                        pressTime = getTimestampMs(),
                        grid = cgrid,
                        leaderId = cid,
                        held = false,
                        mode = "add",
                    }
                    joyDebug("grab: peel ativo — aguardando tap(+1)/hold(restante)")
                    return
                end
            end
        end
        joyDebug("grab -> PLACE (A de novo após mover)")
        GridJoypad.placeDrag(playerNum, page)
        return
    end
    if not page or not page.inventoryPane then return end
    if JoypadState.disableGrab then return end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or playerObj:isAsleep() then return end
    local cursor = GridJoypad.resolveCursor(playerNum, page)
    if not cursor or not cursor.grid then return end
    local grid = cursor.grid
    if grid:isLocked() then return end

    local id = grid.gridCore.cells[cursor.col] and grid.gridCore.cells[cursor.col][cursor.row]
    if not id then return end
    local d = grid.gridCore.items[id]
    if not d or not d.itemObj or d.stackMemberOf then return end

    -- PILHA (mais de 1 objeto): não pega na hora — registra o press do A e
    -- aguarda tap/hold no pollA. Tap = 1 item, hold = pilha inteira.
    local stackSize = 1
    if grid.gridCore.getStackSize then
        stackSize = grid.gridCore:getStackSize(id) or 1
    end
    if stackSize > 1 then
        GridJoypad.aPress = {
            active = true,
            playerNum = playerNum,
            pressTime = getTimestampMs(),
            grid = grid,
            leaderId = id,
            held = false,
        }
        joyDebug("grab: pilha — aguardando tap/hold do A")
        return
    end

    -- Item normal: monta o drag na hora (comportamento original).
    if startDrag(playerNum, grid, id, { id }, nil) then
        joyDebug("grab INICIOU drag de ", tostring(d.itemObj or id),
            " t=" .. tostring(getTimestampMs()), " cursor=", cursor.col, cursor.row)
    end
end

--- Polling do press do A (chamado no update da página): resolve tap vs hold na
--- pilha. Hold (>= A_HOLD_MS) pega a pilha inteira; o release antes disso
--- (tap) pega 1 item.
function GridJoypad.pollA(playerNum, page)
    local ap = GridJoypad.aPress
    if not ap or not ap.active or ap.playerNum ~= playerNum then return end

    local joypadData = getJoypadData(playerNum)
    if not joypadData or joypadData.id == nil then
        GridJoypad.aPress = { active = false, playerNum = nil }
        return
    end

    local aDown = JoypadButton.A:isDown(joypadData.id)
    local now = getTimestampMs()

    if ap.held then
        -- Hold já consumido: só aguarda o release pra liberar o próximo press.
        if not aDown then
            GridJoypad.aPress = { active = false, playerNum = nil }
        end
        return
    end

    if not aDown then
        -- Soltou antes do hold → TAP: pega 1 item (peel) ou +1 (peel ativo).
        local grid, leaderId = ap.grid, ap.leaderId
        local mode = ap.mode
        GridJoypad.aPress = { active = false, playerNum = nil }
        if grid and leaderId and grid.gridCore and grid.gridCore.items[leaderId] then
            if mode == "add" then
                addStackMember(playerNum, grid, leaderId)
            else
                peelOne(playerNum, grid, leaderId)
            end
        end
        return
    end

    if now - ap.pressTime >= A_HOLD_MS then
        -- HOLD: pega a pilha inteira (peel inicial) ou todo o RESTANTE
        -- (peel ativo).
        ap.held = true
        local grid, leaderId = ap.grid, ap.leaderId
        local mode = ap.mode
        if grid and leaderId and grid.gridCore and grid.gridCore.items[leaderId] then
            if mode == "add" then
                addRestOfStack(playerNum, grid, leaderId)
                joyDebug("grab: HOLD — pegou o restante da pilha")
            else
                local members = grid.gridCore:getStackMembers(leaderId)
                startDrag(playerNum, grid, leaderId, members, nil)
                joyDebug("grab: HOLD — pegou a pilha inteira")
            end
        end
    end
end

-- ============================================================================
-- STACK PICKER no controle (Select = Joypad.Back)
-- ============================================================================

--- Select (Joypad.Back): abre o STACK PICKER sobre a pilha do cursor, com
--- navegação D-pad dentro da janela (A tira o item destacado, B fecha).
--- Retorna true se abriu.
function GridJoypad.openStackPicker(playerNum, page)
    if not page or not page.inventoryPane then return false end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or playerObj:isAsleep() then return false end
    local cursor = GridJoypad.resolveCursor(playerNum, page)
    if not cursor or not cursor.grid then return false end
    local grid = cursor.grid
    if not grid.gridCore or not grid.gridCore.cells then return false end
    local id = grid.gridCore.cells[cursor.col] and grid.gridCore.cells[cursor.col][cursor.row]
    if not id then return false end
    local d = grid.gridCore.items[id]
    if not d or not d.itemObj or d.stackMemberOf then return false end

    local stackSize = 1
    if grid.gridCore.getStackSize then
        stackSize = grid.gridCore:getStackSize(id) or 1
    end
    if stackSize <= 1 then return false end
    if not GridInventory_openStackPicker then return false end

    -- Cancela qualquer press pendente do A (não deixar um hold do A disparar o
    -- drag enquanto o picker está aberto).
    GridJoypad.aPress = { active = false, playerNum = nil }

    -- Posição de tela do CENTRO da célula do cursor VIRTUAL (não do mouse) —
    -- o picker abre sobre a pilha selecionada pelo controle.
    local sx = grid:getAbsoluteX() + grid.gridPadding + ((cursor.col - 0.5) * grid.cellSize)
    local sy = grid:getAbsoluteY() + grid.gridPadding + (grid.headerH or 0) + ((cursor.row - 0.5) * grid.cellSize)

    GridInventory_openStackPicker(playerNum, grid, id, true, sx, sy)
    GridJoypad.picker = { playerNum = playerNum }
    joyDebug("openStackPicker: abriu o picker da pilha ", tostring(id))
    return true
end

--- True se o stack picker do controle está ativo (o D-pad/A/B devem navegar a
--- janela em vez de mover o cursor das grids).
function GridJoypad.isPickerActive(playerNum)
    local sp = GridInventory_StackPicker and GridInventory_StackPicker[playerNum]
    return GridJoypad.picker and GridJoypad.picker.playerNum == playerNum
        and sp ~= nil and sp:getIsVisible() and sp.stackMode ~= nil
end

--- Fecha o stack picker do controle (B).
function GridJoypad.closePicker(playerNum)
    GridJoypad.picker = { playerNum = nil }
    local sp = GridInventory_StackPicker and GridInventory_StackPicker[playerNum]
    if sp then sp:close() end
end

--- D-pad no picker: move a linha destacada (delta = ±1).
function GridJoypad.pickerMove(playerNum, delta)
    local sp = GridInventory_StackPicker and GridInventory_StackPicker[playerNum]
    if sp and sp.joyMove then sp:joyMove(delta) end
end

--- A no picker: tira 1 item da linha destacada.
function GridJoypad.pickerTake(playerNum)
    local sp = GridInventory_StackPicker and GridInventory_StackPicker[playerNum]
    if sp and sp.joyTake then sp:joyTake() end
end

--- Reorder DENTRO do MESMO grid (drop na célula do cursor): caminho DIRETO
--- via GridReorder, respeitando o sandbox ReorderTimeAction (se timed, usa a
--- GridReorderAction com animação; senão instantâneo).
local function reorderInGrid(playerNum, grid, dropCol, dropRow)
    if not grid or not grid.gridCore then return end
    local GridReorder = require "Algorithm/GridReorder"
    local itemsData = GridInventory_GlobalDrag and GridInventory_GlobalDrag.itemsData
    if not itemsData or #itemsData == 0 then return end
    local targets = GridReorder.computeTargets(grid.gridCore, itemsData, dropCol, dropRow)
    if not targets then
        joyDebug("reorderInGrid: targets=nil (drop inválido em ", dropCol, dropRow, ")")
        return
    end
    if GridReorder.isNoOp(grid.gridCore, targets) then
        joyDebug("reorderInGrid: no-op (mesma posição)")
        return
    end
    local okGSO, GridSandboxOptions = pcall(require, "GridSandboxOptions")
    if okGSO and GridSandboxOptions and GridSandboxOptions.isReorderTimed() then
        local playerObj = getSpecificPlayer(playerNum)
        local okRA, GridReorderAction = pcall(require, "TimedActions/GridReorderAction")
        if playerObj and okRA and GridReorderAction and ISTimedActionQueue then
            ISTimedActionQueue.add(GridReorderAction:new(playerObj, grid, targets))
            joyDebug("reorderInGrid: timed action (GridReorderAction) em ", dropCol, dropRow)
        else
            grid:performGridReorder(targets)
        end
    else
        grid:performGridReorder(targets)
        joyDebug("reorderInGrid: reorder instantâneo em ", dropCol, dropRow)
    end
end

--- SOLTA o item arrastado na célula do cursor. No MESMO grid usa o reorder
--- direto (GridReorder); em outro grid usa o onMouseUp (cross-container).
function GridJoypad.placeDrag(playerNum, page)
    local cursor = GridJoypad.resolveCursor(playerNum, page)
    if not cursor or not cursor.grid then
        GridJoypad.cancelDrag(playerNum)
        return
    end
    local grid = cursor.grid
    local sourceGrid = GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid

    -- MESMO grid (reorder): caminho direto, sem onMouseUp. Também trata o caso
    -- de o grid ter sido RECONSTRUÍDO durante o drag (sourceGrid stale) — se o
    -- container é o MESMO, é reorder, não transfer.
    local sameContainer = sourceGrid and grid
        and sourceGrid.inventoryContainer == grid.inventoryContainer
    if grid == sourceGrid or sameContainer then
        joyDebug("placeDrag: reorder no mesmo grid em ", cursor.col, cursor.row)
        reorderInGrid(playerNum, grid, cursor.col, cursor.row)
        if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid then
            GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
        end
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
        GridJoypad.drag = { active = false, playerNum = nil }
        return
    end

    -- Centro da célula do cursor em coordenadas LOCAIS do grid — o
    -- getGridCellAtMouse (usado no onMouseUp) converte de (x - gridPadding),
    -- então passar coords de tela daria célula errada (fora do grid) e o drop
    -- não moveria nada.
    local sx = grid.gridPadding + ((cursor.col - 0.5) * grid.cellSize)
    local sy = grid.gridPadding + (grid.headerH or 0) + ((cursor.row - 0.5) * grid.cellSize)
    -- Estados que o onMouseUp ramifica e que não se aplicam ao joypad:
    grid.clickedItemId = nil
    grid.draggingMarquis = false
    grid.ctrlStackPeel = nil
    joyDebug("placeDrag chamando onMouseUp em ", tostring(grid.name or grid.inventoryContainer),
        "@", cursor.col, cursor.row, " t=" .. tostring(getTimestampMs()))
    -- ISMouseDrag SÓ transitoriamente pro drop (o drop cross-grid do onMouseUp
    -- precisa dele; mas não pode ficar setado durante o drag — o vanilla
    -- autocoloca o item se o mouse não está segurado).
    local dragItems = GridInventory_GlobalDrag and GridInventory_GlobalDrag.itemsData
    if dragItems and #dragItems > 0 then
        ISMouseDrag.dragging = { dragItems[1].itemObj }
        ISMouseDrag.draggingFocus = grid
    end
    if grid.onMouseUp then
        grid:onMouseUp(sx, sy)
    end
    -- Limpeza de segurança (se o onMouseUp retornou cedo sem zerar o drag).
    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid then
        GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
    end
    GridInventory_GlobalDrag = nil
    ISMouseDrag.dragging = nil
    ISMouseDrag.draggingFocus = nil
    GridJoypad.drag = { active = false, playerNum = nil }
end

--- CANCELA o drag (o item volta pra origem — nunca foi removido do container).
function GridJoypad.cancelDrag(playerNum)
    joyDebug("cancelDrag p" .. playerNum)
    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid then
        GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
    end
    GridInventory_GlobalDrag = nil
    ISMouseDrag.dragging = nil
    ISMouseDrag.draggingFocus = nil
    GridJoypad.drag = { active = false, playerNum = nil }
end

--- Botão X (SEM drag): transferência RÁPIDA do item sob o cursor (inv -> loot /
--- loot -> inv) — o comportamento vanilla original.
function GridJoypad.quickTransfer(playerNum, page)
    if not page or not page.inventoryPane then return end
    if JoypadState.disableGrab then return end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or playerObj:isAsleep() then return end
    local itemObj = GridJoypad.itemAtCursorOnly(playerNum, page)
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

--- Botão X: ROTACIONA o item arrastado (o footprint gira, o ghost acompanha).
function GridJoypad.rotate(playerNum, page)
    if not GridJoypad.drag.active or not GridInventory_GlobalDrag then return end
    local anchorData = nil
    for _, d in ipairs(GridInventory_GlobalDrag.itemsData) do
        if d.id == GridInventory_GlobalDrag.anchorId then
            anchorData = d
            break
        end
    end
    if anchorData and anchorData.itemObj then
        anchorData.rotated = not (anchorData.rotated or false)
        if anchorData.itemObj.setRotated then
            anchorData.itemObj:setRotated(anchorData.rotated)
        end
    end
end

--- Botão B: se arrastando, CANCELA o drag; senão, abre o menu de contexto do
--- item sob o cursor (migrado do A).
function GridJoypad.activateB(playerNum, page)
    if GridJoypad.drag.active then
        GridJoypad.cancelDrag(playerNum)
        return
    end
    GridJoypad.openContext(playerNum, page)
end

-- ============================================================================
-- MODO NAVEGAÇÃO (RB segurado)
-- ============================================================================
-- Segurar o RB (R1) por NAV_HOLD_MS entra num modo em que o D-pad pula de
-- grid em grid do painel (flexbox) e, nas bordas horizontais, pro painel
-- OPOSTO (inv <-> loot), SEM wrap vertical. Um overlay de ícones D-pad é
-- desenhado no render da página (renderNavOverlay), e soltar o RB confirma a
-- posição do cursor (endNav). Um tap (< 250ms) continua sendo a troca
-- inv<->loot normal (onJoypadDown já trata).

--- Estado de navegação do jogador (cria se não existir).
function GridJoypad.navFor(playerNum)
    local nav = GridJoypad.navs[playerNum]
    if not nav then
        nav = {
            active = false,
            pressTime = nil,
            pending = nil, -- bumper apertado aguardando o release (tap ou nav)
            pdArmed = false, -- paperdoll: ambos bumpers soltos => bumper sozinho sai
        }
        GridJoypad.navs[playerNum] = nav
    end
    return nav
end

--- O modo navegação está ativo pra este jogador?
function GridJoypad.isNavActive(playerNum)
    local nav = GridJoypad.navs[playerNum]
    return nav ~= nil and nav.active == true
end

--- Encerra o modo navegação (o cursor permanece onde está — posição confirmada).
function GridJoypad.endNav(playerNum)
    local nav = GridJoypad.navs[playerNum]
    if nav then
        nav.active = false
        nav.pressTime = nil
        nav.pending = nil
        nav.pdArmed = false
    end
end

--- Bumper (LB/RB) PRESSIONADO: registra o aperto. A ação (trocar/ciclar
--- container) NÃO roda aqui — o pollNav decide: hold >= NAV_HOLD_MS ativa o
--- modo navegação no painel atual; release sem ativar o modo roda a ação (tap).
function GridJoypad.bumperDown(playerNum, which)
    local nav = GridJoypad.navFor(playerNum)
    if not nav.active and not nav.pressTime then
        nav.pressTime = getTimestampMs()
        nav.pending = which
    end
end

--- Polling por frame (no update da página): detecta LB/RB segurado >=
--- NAV_HOLD_MS e ativa o modo navegação. O bumper segurado escolhe o painel:
--- LB = INV, RB = LOOT — ao ativar, o foco vai pro painel do bumper (switchFocus
--- home), se ainda não estiver nele, e o D-pad navega as grids DAQUELE painel.
--- O tap (< NAV_HOLD_MS) não ativa o modo: a ação de troca/ciclo de container
--- roda no SOLTAR (release) — segurar o bumper pra navegar não dispara mais a
--- troca de painel nem o ciclo de container no meio do aperto. LB+RB ao mesmo
--- tempo entra no modo PAPERDOLL; lá, um bumper sozinho saindo (LB->INV,
--- RB->LOOT) também é decidido no release. Se o foco sair para algo que não
--- seja outro painel de inventário (nil, menu de contexto), o modo encerra.
function GridJoypad.pollNav(playerNum, page)
    local nav = GridJoypad.navFor(playerNum)
    local focus = getFocusForPlayer(playerNum)
    if focus ~= page then
        -- Foco saiu deste painel. Se foi pra OUTRO painel de inventário
        -- (navDir cruzou inv<->loot ou o hold trocou o foco pro painel do
        -- bumper), o update do outro painel cuida do nav; só encerra se o foco
        -- deixou de ser um inventário.
        if not (focus and focus.inventoryPane) then
            GridJoypad.endNav(playerNum)
        end
        return
    end
    local joypadData = getJoypadData(playerNum)
    if not joypadData or joypadData.id == nil then return end

    local now = getTimestampMs()
    local rbDown = JoypadButton.RightBump:isDown(joypadData.id)
    local lbDown = JoypadButton.LeftBump:isDown(joypadData.id)
    local anyDown = rbDown or lbDown

    if nav.active then
        -- Transição fluida: se apertou o outro bumper no meio do Nav, entra no PaperDoll!
        if rbDown and lbDown then
            if GridJoypad.enterPaperdoll(playerNum) then
                GridJoypad.endNav(playerNum)
            end
            return
        end

        -- Soltou o bumper: posição confirmada, sai do modo (sem ação de tap).
        if not anyDown then
            GridJoypad.endNav(playerNum)
        end
        return
    end

    -- Modo PAPERDOLL ativo: sair por um bumper sozinho no RELEASE (LB->INV,
    -- RB->LOOT), mas SÓ depois de soltar os DOIS bumpers do combo de entrada
    -- (pdArmed). Sem isso, soltar o LB+RB em sequência (1 frame de diferença)
    -- disparava a saída na hora — o paperdoll "entrava e já saía" e o tap
    -- jogava o cursor pro 1,1 do painel.
    if GridJoypad.isPaperdollActive(playerNum) then
        -- Release de um bumper que estava aguardando a saída (armado).
        if not anyDown and nav.pending then
            local side = nav.pending
            nav.pending = nil
            nav.pressTime = nil
            nav.pdArmed = false
            GridJoypad.exitPaperdoll(playerNum, page, side)
            return
        end
        if not anyDown then
            -- Ambos soltos: a partir daqui um bumper sozinho pode sair.
            nav.pdArmed = true
            nav.pending = nil
            nav.pressTime = nil
        else
            local exitSide = nil
            if rbDown and not lbDown then exitSide = "loot" end
            if lbDown and not rbDown then exitSide = "inv" end
            if exitSide and nav.pdArmed then
                if not nav.pressTime then
                    nav.pressTime = now
                    nav.pending = exitSide
                end
            end
        end
        return
    end

    -- LB+RB AO MESMO TEMPO = entra no modo PaperDoll (antes do nav de bumper
    -- único). Limpa o estado de bumper único pra não disparar tap/nav depois.
    if rbDown and lbDown then
        if GridJoypad.enterPaperdoll(playerNum) then
            GridJoypad.endNav(playerNum)
        end
        return
    end

    if anyDown then
        -- Bumper segurado: registra o aperto (se ainda não tem) e aguarda o
        -- tempo mínimo pra virar modo navegação.
        if not nav.pressTime then
            nav.pressTime = now
            nav.pending = rbDown and "RB" or "LB"
        end
        if now - nav.pressTime >= NAV_HOLD_MS then
            -- LB = inv, RB = loot: força o foco pro painel do bumper, se preciso.
            local bumperPage = nav.pending == "RB" and getPlayerLoot(playerNum)
                or getPlayerInventory(playerNum)
            if bumperPage and bumperPage ~= page then
                GridJoypad.switchFocus(playerNum, page, bumperPage, true)
            end
            nav.active = true
            nav.pressTime = nil
            nav.pending = nil
        end
        return
    end

    -- Bumper SOLTO.
    if nav.pending then
        -- Foi um TAP (nunca ativou o modo): roda a ação de troca/ciclo de
        -- container AGORA, no release, pro bumper que foi apertado.
        local tapped = nav.pending
        nav.pending = nil
        nav.pressTime = nil
        local target = tapped == "RB" and getPlayerLoot(playerNum) or getPlayerInventory(playerNum)
        GridJoypad.shoulderCycle(playerNum, page, target)
        return
    end
    nav.pressTime = nil
end

-- ============================================================================
-- PAPERDOLL (LB+RB segurados)
-- ============================================================================
-- Segurar LB+RB ao mesmo tempo entra no modo de navegação por slots do
-- PaperDoll: um overlay de D-pad aparece na janela e o D-pad navega entre os
-- slots (sem wrap). Sair: LB volta o foco pro INV, RB pro LOOT.

--- Janela do PaperDoll do jogador (se existir e tiver slots).
local function pdWindow(playerNum)
    local pd = GridInventory_PaperDollWindow
    if not pd then return nil end
    local win = pd[playerNum]
    if not win or not win.slots then return nil end
    return win
end

--- Slot do PaperDoll pela coluna/índice do layout.
local function pdSlotBy(pd, col, idx)
    for _, s in ipairs(pd.slots) do
        if s._pdCol == col and (s._pdIndex or 1) == (idx or 1) then
            return s
        end
    end
    return nil
end

--- Linhas da hotbar (slots agrupados pelo Y, ordenados por X dentro da linha).
--- A hotbar nasce/renasce no refreshHotbarUIs; aqui agrupamos por posição.
local function pdHotbarRows(pd)
    local rows = {}
    local order = {}
    for _, ui in ipairs(pd.hotbarUis or {}) do
        if ui:getIsVisible() then
            local key = tostring(ui:getY())
            if not rows[key] then
                rows[key] = {}
                table.insert(order, key)
            end
            table.insert(rows[key], ui)
        end
    end
    table.sort(order, function(a, b) return tonumber(a) < tonumber(b) end)
    local result = {}
    for _, k in ipairs(order) do
        table.sort(rows[k], function(a, b) return a:getX() < b:getX() end)
        table.insert(result, rows[k])
    end
    return result
end

local function clampIdx(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Slot de uma linha da hotbar mais próximo do centro X dado.
local function nearestInRow(row, centerX)
    local best, bestD = nil, nil
    for _, s in ipairs(row) do
        local sx = s:getX() + s:getWidth() / 2
        local d = math.abs(sx - centerX)
        if not bestD or d < bestD then
            best, bestD = s, d
        end
    end
    return best
end

--- Navegação DENTRO da hotbar (agrupada em linhas).
local function pdHotbarMove(pd, slot, dx, dy)
    local rows = pdHotbarRows(pd)
    if #rows == 0 then return nil end
    local r, c
    for ri, row in ipairs(rows) do
        for ci, s in ipairs(row) do
            if s == slot then r, c = ri, ci end
        end
    end
    if not r then return nil end
    if dx == -1 then
        return c > 1 and rows[r][c - 1] or nil
    elseif dx == 1 then
        return c < #rows[r] and rows[r][c + 1] or nil
    elseif dy == -1 then
        if r == 1 then
            -- Sobe pro primaryHand (a mão primária fica acima da hotbar).
            local prim = pdSlotBy(pd, "primary", 1)
            if prim and prim:getIsVisible() then return prim end
            -- Fallback: o mais próximo entre as mãos.
            local sec = pdSlotBy(pd, "secondary", 1)
            local slotCenter = slot:getX() + slot:getWidth() / 2
            local best, bestD = nil, nil
            for _, cand in ipairs({ prim, sec }) do
                if cand and cand:getIsVisible() then
                    local cc = cand:getX() + cand:getWidth() / 2
                    local d = math.abs(cc - slotCenter)
                    if not bestD or d < bestD then best, bestD = cand, d end
                end
            end
            return best
        end
        return rows[r - 1][clampIdx(c, 1, #rows[r - 1])]
    elseif dy == 1 then
        return r < #rows and rows[r + 1][clampIdx(c, 1, #rows[r + 1])] or nil
    end
    return nil
end

--- Próximo slot na direção (dx,dy). Layout:
---   left[1..5] (Chapéu..Calça) | right[1..5] (Acessórios..Sapatos)
---   bag (esq, embaixo)          | overflow (dir, embaixo)
---   primary (centro-esq)       | secondary (centro-dir)
---   twohand (entre eles, só se visível)
---   hotbar (linhas abaixo das mãos)
 local function pdMove(pd, slot, dx, dy)
    local col = slot._pdCol
    local i = slot._pdIndex or 1
    local two = pdSlotBy(pd, "twohand", 1)
    local twoVisible = two ~= nil and two:getIsVisible()
    -- Alvo do AVATAR (retângulo de eat/read/drink/takepill). Não é um slot;
    -- é o avatarDropZone da janela, navegável como alvo.
    local avatar = pd.avatarDropZone
    local avatarActive = avatar ~= nil and avatar:getIsVisible()
    if col == "avatar" then
        -- Do avatar (centro): esquerda/direita pras colunas (meio), baixo pro
        -- primaryHand (a mão primária fica abaixo do avatar no centro).
        if dx == -1 then return pdSlotBy(pd, "left", 3) or pdSlotBy(pd, "left", 1) end
        if dx == 1 then return pdSlotBy(pd, "right", 3) or pdSlotBy(pd, "right", 1) end
        if dy == 1 then return pdSlotBy(pd, "primary", 1) or pdSlotBy(pd, "left", 5) end
        if dy == -1 then return pdSlotBy(pd, "primary", 1) or pdSlotBy(pd, "right", 5) end
        return nil
    end
    if col == "hotbar" then
        return pdHotbarMove(pd, slot, dx, dy)
    end
    if dx == -1 then
        if col == "right" then return avatarActive and avatar or pdSlotBy(pd, "left", i) end
        if col == "overflow" then return avatarActive and avatar or pdSlotBy(pd, "bag", 1) end
        if col == "secondary" then return twoVisible and two or pdSlotBy(pd, "primary", 1) end
        if col == "twohand" then return pdSlotBy(pd, "primary", 1) end
        return nil
    elseif dx == 1 then
        if col == "left" then return avatarActive and avatar or pdSlotBy(pd, "right", i) end
        if col == "bag" then return avatarActive and avatar or pdSlotBy(pd, "overflow", 1) end
        if col == "primary" then return twoVisible and two or pdSlotBy(pd, "secondary", 1) end
        if col == "twohand" then return pdSlotBy(pd, "secondary", 1) end
        return nil
    elseif dy == -1 then
        if col == "left" then return i > 1 and pdSlotBy(pd, "left", i - 1) or nil end
        if col == "right" then return i > 1 and pdSlotBy(pd, "right", i - 1) or nil end
        if col == "bag" then return pdSlotBy(pd, "left", 5) end
        if col == "overflow" then return pdSlotBy(pd, "right", 5) end
        if col == "primary" then return pdSlotBy(pd, "bag", 1) end
        if col == "secondary" then return pdSlotBy(pd, "overflow", 1) end
        return nil
    elseif dy == 1 then
        if col == "left" then return i < 5 and pdSlotBy(pd, "left", i + 1) or pdSlotBy(pd, "bag", 1) end
        if col == "right" then return i < 5 and pdSlotBy(pd, "right", i + 1) or pdSlotBy(pd, "overflow", 1) end
        if col == "bag" then return pdSlotBy(pd, "primary", 1) end
        if col == "overflow" then return pdSlotBy(pd, "secondary", 1) end
        if col == "primary" or col == "secondary" then
            -- Desce pras mãos -> hotbar (slot mais próximo na 1ª linha).
            local rows = pdHotbarRows(pd)
            if #rows > 0 then
                return nearestInRow(rows[1], slot:getX() + slot:getWidth() / 2)
            end
        end
        return nil
    end
    return nil
end

--- O modo PaperDoll está ativo pra este jogador?
function GridJoypad.isPaperdollActive(playerNum)
    local p = GridJoypad.pds[playerNum]
    return p ~= nil and p.active == true
end

--- Slot atualmente selecionado (pro overlay/render).
function GridJoypad.pdSelectedSlot(playerNum)
    local p = GridJoypad.pds[playerNum]
    if not p or not p.active then return nil end
    return p.slot
end

--- LB+RB segurados: entra no modo PaperDoll (só se a janela estiver visível).
function GridJoypad.enterPaperdoll(playerNum)
    local p = GridJoypad.pds[playerNum]
    if p and p.active then return true end
    local pd = pdWindow(playerNum)
    if not pd or not pd:getIsVisible() then return false end
    if not p then
        p = { active = false, slot = nil }
        GridJoypad.pds[playerNum] = p
    end
    p.active = true
    p.slot = pd.slots[1]
    if p.slot then p.slot.joySelected = true end
    return true
end

--- Garante que o slot seja visível no scrollPanel do PaperDoll.
--- Se o slot estiver acima ou abaixo da viewport, rola o painel pra encaixá-lo.
local function pdEnsureSlotVisible(pd, slot)
    local sp = pd and pd.scrollPanel
    if not sp or not slot then return end
    local slotY = slot:getY()
    local slotH = slot:getHeight()
    local yScroll = sp:getYScroll() or 0
    local paneH = sp.height or sp:getHeight()
    local margin = 10
    if slotY < -yScroll + margin then
        sp:setYScroll(-slotY + margin)
    elseif slotY + slotH > -yScroll + paneH - margin then
        sp:setYScroll(-(slotY + slotH - paneH + margin))
    end
end

--- D-pad durante o modo PaperDoll: navega entre os slots (sem wrap).
function GridJoypad.pdDir(playerNum, dx, dy)
    local p = GridJoypad.pds[playerNum]
    if not p or not p.active then return false end
    local pd = pdWindow(playerNum)
    if not pd or not p.slot then return false end
    local target = pdMove(pd, p.slot, dx, dy)
    if not target or target == p.slot then return false end
    if p.slot.joySelected then p.slot.joySelected = false end
    p.slot = target
    target.joySelected = true
    -- Auto-scroll: garante que o slot alvo seja visível no scrollPanel.
    pdEnsureSlotVisible(pd, target)
    return true
end

--- Alvo na direção (dx,dy) SEM mover a seleção (pro overlay de ícones D-pad).
function GridJoypad.pdTarget(playerNum, dx, dy)
    local p = GridJoypad.pds[playerNum]
    if not p or not p.active or not p.slot then return nil end
    local pd = pdWindow(playerNum)
    if not pd then return nil end
    return pdMove(pd, p.slot, dx, dy)
end

--- A no modo PaperDoll: se há um item arrastado (drag de joypad), EQUIPA o item
--- no slot selecionado (roupa/mochila/arma/hotbar) e encerra o drag. Sem drag
--- não faz nada (remover/gerenciar o item do slot = menu de contexto, X).
function GridJoypad.pdActivate(playerNum)
    local p = GridJoypad.pds[playerNum]
    if not p or not p.active or not p.slot then return end
    if not GridJoypad.drag.active then return end
    local slot = p.slot
    -- Guarda de TEMPO contra o eco imediato do A (o engine re-envia o clique
    -- em rajada): sem isso, pegar/equipar e o eco soltava na hora.
    if GridJoypad.drag.startedAt and getTimestampMs() - GridJoypad.drag.startedAt < 300 then
        joyDebug("pdActivate -> place IGNORADO (eco imediato do A)")
        return
    end
    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.itemsData
        and #GridInventory_GlobalDrag.itemsData > 0 then
        local itemObj = GridInventory_GlobalDrag.itemsData[1].itemObj
        if itemObj then
            -- Alvo = AVATAR (retângulo de eat/read/drink/pill): usa o item.
            if slot._pdCol == "avatar" then
                local okAZ, AvatarUseDropZone = pcall(require, "UI/PaperDoll/AvatarUseDropZone")
                if okAZ and AvatarUseDropZone and AvatarUseDropZone.useItem then
                    AvatarUseDropZone.useItem(playerNum, itemObj)
                end
            elseif slot.joypadEquip then
                joyDebug("pdActivate: equipando ", tostring(itemObj), " no slot ", tostring(slot.slotName or slot._pdCol))
                slot:joypadEquip(itemObj)
            end
        end
    end
    GridJoypad.cancelDrag(playerNum)
end

--- X no modo PaperDoll: MENU CÍCLICO — slot com vários itens equipados cicla o
--- exibido; slot vazio de hotbar abre o menu do hotbar.
function GridJoypad.pdCycle(playerNum)
    local p = GridJoypad.pds[playerNum]
    if not p or not p.active or not p.slot then return end
    local slot = p.slot
    if slot and slot.getEquippedItems then
        local items = slot:getEquippedItems()
        if #items > 1 then
            slot.activeIndex = (slot.activeIndex or 1) + 1
            if slot.activeIndex > #items then slot.activeIndex = 1 end
        elseif #items == 0 and slot.hotbarRef and slot.hotbarSlotIndex then
            slot.hotbarRef:doMenu(slot.hotbarSlotIndex)
        end
    end
end

--- B no modo PaperDoll: abre o menu de contexto do item equipado no slot
--- selecionado (ou o menu do hotbar). `page` é a página de onde veio — o menu
--- volta o foco pra ELA ao fechar (não pra janela do paperdoll, que não recebe
--- foco de joypad e travava a UI).
function GridJoypad.pdContext(playerNum, page)
    local p = GridJoypad.pds[playerNum]
    if not p or not p.active or not p.slot then return end
    local slot = p.slot
    local item = slot and slot.getEquippedItem and slot:getEquippedItem()
    if item then
        local menu = ISInventoryPaneContextMenu.createMenu(playerNum, true, { item },
            slot:getAbsoluteX() + 16, slot:getAbsoluteY() + 16)
        if menu and menu.numOptions and menu.numOptions > 1 then
            menu.origin = page
            menu.mouseOver = 1
            setJoypadFocus(playerNum, menu)
        end
    elseif slot and slot.hotbarRef and slot.hotbarSlotIndex then
        slot.hotbarRef:doMenu(slot.hotbarSlotIndex)
    end
end

--- LB/RB durante o modo PaperDoll: sai. `side` = "inv" (LB) ou "loot" (RB).
function GridJoypad.exitPaperdoll(playerNum, page, side)    local p = GridJoypad.pds[playerNum]
    if not p or not p.active then return end
    if p.slot then p.slot.joySelected = false end
    p.active = false
    p.slot = nil
    local target = side == "inv" and getPlayerInventory(playerNum) or getPlayerLoot(playerNum)
    if target then
        GridJoypad.switchFocus(playerNum, page, target, true)
    end
end

--- Grid do container ATIVO de um painel (usado pelo overlay pro painel oposto).
local function activeGridOf(page)
    local pane = page and page.inventoryPane
    if not pane or not pane.gridContainerUis then return nil end
    local activeInv = pane.inventory
    for _, g in ipairs(pane.gridContainerUis) do
        if not g.isOverflow and g.inventoryContainer == activeInv then
            return g
        end
    end
    return nil
end

--- Alvos do overlay de navegação na direção do D-pad. Retorna uma tabela
--- { left=alvo, right=alvo, up=alvo, down=alvo } onde cada alvo é um GridRender
--- do próprio painel (vizinho) ou do painel oposto (grid do container ativo).
--- Direções sem alvo (vertical sem vizinho) ficam de fora.
function GridJoypad.navTargets(playerNum, page)
    local cursor = GridJoypad.resolveCursor(playerNum, page)
    if not cursor or not cursor.grid then return nil end
    local grid = cursor.grid
    local targets = {}
    local dirs = {
        left = { -1, 0 },
        right = { 1, 0 },
        up = { 0, -1 },
        down = { 0, 1 },
    }
    for name, d in pairs(dirs) do
        local n = GridJoypad.findNeighbor(grid, d[1], d[2])
        if n then
            targets[name] = n
        elseif d[1] ~= 0 then
            local inv = getPlayerInventory(playerNum)
            local loot = getPlayerLoot(playerNum)
            local other = nil
            if page == loot then other = inv elseif page == inv then other = loot end
            if other then
                targets[name] = activeGridOf(other)
            end
        end
    end
    return targets
end

--- D-pad durante o modo navegação: pula pro vizinho do painel, ou pro painel
--- oposto nas bordas horizontais. Sem wrap vertical (noWrap no boundary).
function GridJoypad.navDir(playerNum, page, dx, dy)
    local cursor = GridJoypad.resolveCursor(playerNum, page)
    if not cursor or not cursor.grid then return false end
    return GridJoypad.boundary(playerNum, page, cursor, cursor.grid, dx, dy, true)
end

--- Desenha o overlay do modo navegação (no render da página): destaque do grid
--- atual + ícones D-pad nos alvos, estilo o joypadNavigate do vanilla.
function GridJoypad.renderNavOverlay(page)
    local playerNum = page.player
    local nav = GridJoypad.navs[playerNum]
    if not nav or not nav.active then return end
    local cursor = GridJoypad.cursors[playerNum]
    local grid = cursor and cursor.grid
    if not grid or not grid:getIsVisible() then return end

    -- Página onde o cursor está (a que tem o grid atual).
    local cursorPage = grid.parent and grid.parent.inventoryPage
    if not cursorPage then return end

    local pane = page.inventoryPane
    if not pane then return end

    -- Destaque do grid atual (só na página do cursor).
    if page == cursorPage then
        local gx = grid:getAbsoluteX() - page:getAbsoluteX()
        local gy = grid:getAbsoluteY() - page:getAbsoluteY()
        
        -- Clip to the scroll pane bounds to prevent leaking over titlebar
        page:setStencilRect(pane:getX(), pane:getY(), pane.width, pane.height)
        
        page:drawRectBorderStatic(gx, gy, grid.width, grid.height, 0.5, 1.0, 1.0, 1.0)
        page:drawRectBorderStatic(gx + 1, gy + 1, grid.width - 2, grid.height - 2, 0.5, 1.0, 1.0, 1.0)
        
        page:clearStencilRect()
    end

    -- Alvos do cursor (resolvidos na página do cursor — o navTargets calcula
    -- vizinhos do painel E o grid do painel OPOSTO). Cada página desenha os
    -- alvos que são filhos DELA: a página do cursor desenha os vizinhos locais;
    -- a página oposta desenha o alvo cruzado (inv<->loot), na posição correta
    -- relativa à SUA origem (sem isso o ícone do outro painel fica atrás/fora).
    local targets = GridJoypad.navTargets(playerNum, cursorPage)
    if not targets then return end
    
    page:setStencilRect(pane:getX(), pane:getY(), pane.width, pane.height)
    for dir, t in pairs(targets) do
        if t and t:getIsVisible() and t.parent and t.parent.inventoryPage == page then
            local x = t:getAbsoluteX() - page:getAbsoluteX()
            local y = t:getAbsoluteY() - page:getAbsoluteY()
            local w, h = t.width, t.height
            page:drawRect(x, y, w, h, 0.15, 1.0, 1.0, 1.0)
            local texName = DPAID_TEXTURES[dir]
            if Joypad.Texture and Joypad.Texture[texName] then
                local texW, texH = 64, 64
                page:drawTextureScaledAspect(Joypad.Texture[texName],
                    x + w / 2 - texW / 2, y + h / 2 - texH / 2, texW, texH,
                    1.0, 1.0, 1.0, 1.0)
            end
        end
    end
    page:clearStencilRect()
end

return GridJoypad
