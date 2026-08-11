require "ISUI/ISUIElement"
local GridRender = require "UI/GridRender/GridRender"

GridInventory_GlobalDrag = nil

-- Decisão agregada do preview de multi-drag, publicada pelo grid sob o cursor
-- (GridRender:updateMultiDragPreview). { fits = boolean, grid = GridRender,
-- dragRef = GridInventory_GlobalDrag } — dragRef + isMouseOver evitam usar um
-- valor velho de outro drag ou de quando o mouse saiu do grid.
GridInventory_MultiDragFit = nil

GlobalDragRender = ISUIElement:derive("GlobalDragRender")

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

    local drawW = (anchorData.rotated and anchorData.originalH or anchorData.originalW) * cellSize
    local drawH = (anchorData.rotated and anchorData.originalW or anchorData.originalH) * cellSize

    local drawX = mouseX - (anchorData.grabOffsetX * cellSize) - (cellSize / 2)
    local drawY = mouseY - (anchorData.grabOffsetY * cellSize) - (cellSize / 2)

    -- Multi-drag real = itens em células de origem DIFERENTES → mini-layout
    -- (cluster de sprites nas posições relativas, como no grid de origem),
    -- tintado de verde/vermelho pela decisão agregada do grid sob o cursor.
    local isMultiDrag = false
    if anchorData.originalX ~= nil then
        for _, dragData in ipairs(itemsData) do
            if dragData.originalX ~= anchorData.originalX or dragData.originalY ~= anchorData.originalY then
                isMultiDrag = true
                break
            end
        end
    end

    local fits = nil
    local fit = GridInventory_MultiDragFit
    if fit and fit.grid and fit.dragRef == GridInventory_GlobalDrag and fit.grid:isMouseOver() then
        fits = fit.fits
    end

    if isMultiDrag then
        -- Deduplica por célula de origem: uma pilha inteira (vários membros na
        -- mesma célula) vira UM sprite com badge "+N" — senão os membros
        -- desenhariam um por cima do outro.
        local cellUnits = {}
        for _, dragData in ipairs(itemsData) do
            local key = (dragData.originalX or 0) .. "," .. (dragData.originalY or 0)
            local unit = cellUnits[key]
            if unit then
                unit.count = unit.count + 1
            else
                cellUnits[key] = { d = dragData, count = 1 }
            end
        end

        for _, unit in pairs(cellUnits) do
            local dragData = unit.d
            local dw = (dragData.rotated and dragData.originalH or dragData.originalW) * cellSize
            local dh = (dragData.rotated and dragData.originalW or dragData.originalH) * cellSize
            local dx = drawX + ((dragData.originalX or 0) - (anchorData.originalX or 0)) * cellSize
            local dy = drawY + ((dragData.originalY or 0) - (anchorData.originalY or 0)) * cellSize

            -- Sem grid sob o cursor: sprites crus, como na própria grid. Com
            -- decisão agregada: plate verde (cabe) ou vermelha (não cabe).
            if fits == true then
                self:drawRect(dx, dy, dw, dh, 0.28, 0.2, 0.85, 0.3)
                self:drawRectBorder(dx, dy, dw, dh, 0.85, 0.3, 1.0, 0.45)
            elseif fits == false then
                self:drawRect(dx, dy, dw, dh, 0.3, 0.9, 0.2, 0.2)
                self:drawRectBorder(dx, dy, dw, dh, 0.85, 1.0, 0.3, 0.3)
            end

            if dragData.itemObj then
                GridRender.drawItemIconRotated(self, dragData.itemObj, dx, dy, dw, dh, dragData.rotated, 1, 1, 1, 1)
            end

            if unit.count > 1 then
                local text = "+" .. tostring(unit.count - 1)
                local textW = getTextManager():MeasureStringX(UIFont.Small, text)
                self:drawRect(dx + dw - textW - 4, dy + dh - 16, textW + 4, 16, 0.8, 0, 0, 0)
                self:drawText(text, dx + dw - textW - 2, dy + dh - 16, 1, 1, 1, 1, UIFont.Small)
            end
        end
        return
    end

    -- Pilha única (mesma célula de origem) ou item único: sprite "cru" do
    -- âncora + badge de contagem (o feedback de validade fica no grid abaixo).
    if anchorData.itemObj then
        GridRender.drawItemIconRotated(self, anchorData.itemObj, drawX, drawY, drawW, drawH, anchorData.rotated, 1, 1, 1, 1)
    end

    local extraCount = #itemsData - 1
    if extraCount > 0 then
        local text = "+" .. tostring(extraCount)
        local textW = getTextManager():MeasureStringX(UIFont.Small, text)
        -- Fundo escuro pro texto
        self:drawRect(drawX + drawW - textW - 4, drawY + drawH - 16, textW + 4, 16, 0.8, 0, 0, 0)
        self:drawText(text, drawX + drawW - textW - 2, drawY + drawH - 16, 1, 1, 1, 1, UIFont.Small)
    end
end

return GlobalDragRender