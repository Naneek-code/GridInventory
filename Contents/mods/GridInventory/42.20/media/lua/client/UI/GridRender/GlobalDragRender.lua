require "ISUI/ISUIElement"
local GridRender = require "UI/GridRender/GridRender"

GridInventory_GlobalDrag = nil

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

    local extraCount = #itemsData - 1

    -- Sem fundo/borda: o ghost agora renderiza o item "cru", como na própria
    -- grid (o feedback de validade fica por conta do preview do grid abaixo).
    if anchorData.itemObj then
        GridRender.drawItemIconRotated(self, anchorData.itemObj, drawX, drawY, drawW, drawH, anchorData.rotated, 1, 1, 1, 1)
    end

    -- Texto indicando o total de itens
    if extraCount > 0 then
        local text = "+" .. tostring(extraCount)
        local textW = getTextManager():MeasureStringX(UIFont.Small, text)
        -- Fundo escuro pro texto
        self:drawRect(drawX + drawW - textW - 4, drawY + drawH - 16, textW + 4, 16, 0.8, 0, 0, 0)
        self:drawText(text, drawX + drawW - textW - 2, drawY + drawH - 16, 1, 1, 1, 1, UIFont.Small)
    end
end

return GlobalDragRender
