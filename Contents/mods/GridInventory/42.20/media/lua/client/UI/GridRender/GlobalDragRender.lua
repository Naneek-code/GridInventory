require "ISUI/ISUIElement"
local GridRender = require "UI/GridRender/GridRender"
local GridInventory_BagDrop = require "System/GridInventory_BagDrop"
local ItemCategory = require "Algorithm/ItemCategory"
local GridIconRotation = require "Algorithm/GridIconRotation"

GridInventory_GlobalDrag = nil

-- Publicado pelo grid sob o cursor quando ele ESTÁ pintando o preview de drop
-- (footprint verde/vermelho) — GridRender:drawDropPreview. { grid = GridRender,
-- dragRef = GridInventory_GlobalDrag }. Se ativo, a GlobalDragRender desenha o
-- ghost "cru" (sem fundo/borda) pra não cobrir a validação.
GridInventory_DropPreview = nil

-- DRAG_BG (neutro) é usado SÓ no deck de camadas (multi-select). O footprint
-- principal do ghost herda a cor da CATEGORIA do item arrastado (ItemCategory),
-- mesmo padrão do GridRender.
local DRAG_BG = { r = 0.4, g = 0.4, b = 0.4, a = 0.5 }
local DRAG_BORDER = { r = 0.45, g = 0.45, b = 0.45, a = 1 }

local GlobalDragRender = ISUIElement:derive("GlobalDragRender")
local GridJoypad = require("System/GridJoypad")

function GlobalDragRender:new()
    -- Largura e altura 0 para não bloquear os cliques do mouse da Engine
    local o = ISUIElement:new(0, 0, 0, 0)
    setmetatable(o, self)
    self.__index = self
    return o
end

function GlobalDragRender:initialise()
    ISUIElement.initialise(self)
end

function GlobalDragRender:prerender()
    if not GridInventory_GlobalDrag or not GridInventory_GlobalDrag.itemsData then return end
    self:bringToTop()

    -- Zera o preview de drop: só vale o publish DESTE frame. Cada grid pinta e
    -- publica GridInventory_DropPreview no render() quando o mouse está sobre
    -- uma célula dele; se nada publicou (header, fora do grid), o ghost mantém
    -- o fundo/borda — sem o "stale" do frame anterior deixando o ghost cru.
    GridInventory_DropPreview = nil

    -- Put-in por MOUSE não se aplica ao drag de joypad (o cursor virtual guia;
    -- se rodasse, um mouse parado sobre header/bolsa transferiria e encerraria
    -- o drag na hora). O drop do joypad é cometido no place (botão A).
    if not (GridInventory_GlobalDrag and GridInventory_GlobalDrag.joypad) then
        -- Descobre o alvo de put-in sob o cursor (páginas do jogador dono do
        -- drag) — usado como fallback de drop no mouseUp (sem feedback visual).
        local playerNum = GridInventory_GlobalDrag.sourceGrid
            and GridInventory_GlobalDrag.sourceGrid.playerNum or 0
        local bag = GridInventory_BagDrop.findBagUnderMouse(playerNum)

        -- Caminho próprio de drop: mouse solto sobre a bolsa → transfere. É
        -- idempotente com o caminho vanilla (se o dropItemsInContainer já
        -- transferiu, o GridInventory_GlobalDrag já foi zerado e isto é no-op).
        GridInventory_BagDrop.tryHandleMouseUp(playerNum, bag)
    end
end

function GlobalDragRender:render()
    if not GridInventory_GlobalDrag or not GridInventory_GlobalDrag.itemsData then return end

    local itemsData = GridInventory_GlobalDrag.itemsData
    local sourceGrid = GridInventory_GlobalDrag.sourceGrid
    local anchorId = GridInventory_GlobalDrag.anchorId
    
    local mouseX = getMouseX()
    local mouseY = getMouseY()
    local cellSize = sourceGrid.cellSize or 32

    local anchorData = nil
    for _, dragData in ipairs(itemsData) do
        if dragData.id == anchorId then
            anchorData = dragData
            break
        end
    end
    
    if not anchorData then return end

    -- Rotação do ghost = anchorData.rotated (a rotação do grid, data.rotated).
    -- `itemObj:isRotated()` NÃO reflete a rotação da grid — usar ele dessincroniza.
    local rotated = anchorData.rotated or false

    local drawW = (rotated and anchorData.originalH or anchorData.originalW) * cellSize
    local drawH = (rotated and anchorData.originalW or anchorData.originalH) * cellSize

    local drawX, drawY
    if GridInventory_GlobalDrag.joypad then
        -- Drag de joypad: o ghost acompanha o CURSOR virtual (topo-esquerda da
        -- célula do cursor), não o mouse. O getAbsoluteX do grid NÃO inclui o
        -- scroll do pane (setScrollChildren) — desconta o scroll pra achar a
        -- posição de tela real da célula.
        local playerNum = sourceGrid.playerNum or 0
        -- O nav/switchFocus pode ter RECONSTRUÍDO as grids (container novo):
        -- re-resolve o cursor pra pegar o grid VIVO (senão o ghost lê posição
        -- de grid destruído e fica deslocado pra sempre).
        local cursor = GridJoypad.cursors[playerNum]
        if cursor and cursor.grid and cursor.grid.parent and cursor.grid.parent.inventoryPage then
            GridJoypad.resolveCursor(playerNum, cursor.grid.parent.inventoryPage)
            cursor = GridJoypad.cursors[playerNum]
        end
        if not cursor or not cursor.grid or not cursor.col or not cursor.row then return end
        local g = cursor.grid
        -- Posição de tela da célula do cursor: o getAbsoluteX/Y do grid JÁ
        -- inclui o scroll do pane (setScrollChildren) — qualquer correção de
        -- scroll adicional desloca o ghost (subtrair descia, somar subia).
        drawX = g:getAbsoluteX() + g.gridPadding + ((cursor.col - 1) * g.cellSize)
        drawY = g:getAbsoluteY() + g.gridPadding + (g.headerH or 0) + ((cursor.row - 1) * g.cellSize)
        if GridInventory_joypadDebug then
            print("[GridJoypad] ghost joypad: grid=", tostring(g.name or g.inventoryContainer),
                " absX=", g:getAbsoluteX(), " absY=", g:getAbsoluteY(),
                " cursor=", cursor.col, cursor.row,
                " draw=", drawX, drawY)
        end
    else
        drawX = mouseX - (anchorData.grabOffsetX * cellSize) - (cellSize / 2)
        drawY = mouseY - (anchorData.grabOffsetY * cellSize) - (cellSize / 2)
    end

    local extraCount = #itemsData - 1

    -- Fundo/borda de footprint posicionado SÓ quando o grid sob o cursor não
    -- está pintando o preview verde/vermelho (fora do grid, sobre o header ou
    -- paperdoll, ou multi-drag). Com o preview ativo o ghost fica "cru" pra
    -- deixar a validação de posição visível por baixo. O DropPreview é zerado
    -- no prerender e publicado só pelo grid realmente sob o mouse neste frame,
    -- então não precisa re-checar isMouseOver (evita o "stale" do frame
    -- anterior — ex.: header de bolsa mostrando ghost cru).
    local previewActive = false
    local preview = GridInventory_DropPreview
    if preview and preview.grid and preview.dragRef == GridInventory_GlobalDrag then
        previewActive = true
    end

    if not previewActive then
        -- Efeito de camadas (deck de cartas) ATRÁS do footprint quando são
        -- VÁRIOS itens (multi-select ou pilha): cada card é o mesmo footprint
        -- deslocado 4px, deixando claro que não é um item só. Deck SEMPRE em
        -- cor neutra (DRAG_BG) — só o footprint principal herda a categoria.
        if extraCount > 0 then
            local maxStacks = math.min(extraCount, 3)
            for i = maxStacks, 1, -1 do
                local layerX = drawX + (i * 4)
                local layerY = drawY + (i * 4)
                self:drawRect(layerX, layerY, drawW, drawH, DRAG_BG.a, DRAG_BG.r, DRAG_BG.g, DRAG_BG.b)
                self:drawRectBorder(layerX, layerY, drawW, drawH, DRAG_BORDER.a, DRAG_BORDER.r, DRAG_BORDER.g, DRAG_BORDER.b)
            end
        end
        -- Footprint principal: cor da CATEGORIA do item arrastado (fundo),
        -- borda em DEGRADE (mesmas faixas). Usa o DEGRADE vertical (neutro no
        -- topo → categoria na base), igual ao item posicionado. MISC mantém a
        -- borda neutra. O deck de camadas acima fica neutro.
        if anchorData.itemObj then
            local bands = ItemCategory.getGradient(anchorData.itemObj, drawH)
            for _, band in ipairs(bands) do
                self:drawRect(drawX, drawY + band.y, drawW, band.h, DRAG_BG.a, band.r, band.g, band.b)
            end
            local cat = ItemCategory.getCategory(anchorData.itemObj)
            if cat ~= ItemCategory.MISC then
                GridRender.drawGradientBorder(self, drawX, drawY, drawW, drawH, bands, DRAG_BORDER.a, 0)
            else
                -- MISC: degrade sutil (neutro → slot vazio), quase imperceptível
                GridRender.drawGradientBorder(self, drawX, drawY, drawW, drawH, ItemCategory.getSubtleGradient(drawH), DRAG_BORDER.a, 0)
            end
        else
            self:drawRect(drawX, drawY, drawW, drawH, DRAG_BG.a, DRAG_BG.r, DRAG_BG.g, DRAG_BG.b)
            self:drawRectBorder(drawX, drawY, drawW, drawH, DRAG_BORDER.a, DRAG_BORDER.r, DRAG_BORDER.g, DRAG_BORDER.b)
        end
    end

    if anchorData.itemObj then
        GridRender.drawItemIconRotated(self, anchorData.itemObj, drawX, drawY, drawW, drawH, rotated, 1, 1, 1, 1, GridIconRotation.getRenderAngle(anchorData.itemObj))
    end

    -- Badge de contagem: total de itens arrastados (pilha ou multi-drag)
    if extraCount > 0 then
        local text = "+" .. tostring(extraCount)
        local textW = getTextManager():MeasureStringX(UIFont.Small, text)
        -- Fundo escuro pro texto
        self:drawRect(drawX + drawW - textW - 4, drawY + drawH - 16, textW + 4, 16, 0.8, 0, 0, 0)
        self:drawText(text, drawX + drawW - textW - 2, drawY + drawH - 16, 1, 1, 1, 1, UIFont.Small)
    end
end

return GlobalDragRender