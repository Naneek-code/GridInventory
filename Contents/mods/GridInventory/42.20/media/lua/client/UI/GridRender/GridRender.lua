--- GridRender.lua
--- O coração visual do GridInventory. 
--- Responsável por desenhar a malha de fundo (os quadrados) e sobrepor os itens nela.

require "ISUI/ISPanel"
require "TimedActions/ISUnequipAction"
local ItemFootprint = require("Algorithm/ItemFootprint")
local GridContainer = require("DataModel/GridContainer")

GridRender = ISPanel:derive("GridRender")

-- Configurações visuais do nosso estilo "Tarkov"

local GridRender = ISPanel:derive("GridRender")
local GRID_PADDING = 10
local ITEM_BG_COLOR = {r=0.4, g=0.4, b=0.4, a=0.5}
local ITEM_BG_FROZEN = {r=0.2, g=0.6, b=0.9, a=0.5}
local ITEM_BG_HOT = {r=0.9, g=0.2, b=0.2, a=0.5}

function GridRender:new(x, y, gridCore, playerNum, inventoryContainer, gridIndex, containerItem, fallbackIcon)
    local headerH = 28
    local width = (gridCore.width * 40) + (GRID_PADDING * 2)
    local height = (gridCore.height * 40) + (GRID_PADDING * 2) + headerH
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.gridCore = gridCore
    o.inventoryContainer = inventoryContainer
    o.containerItem = containerItem
    o.gridIndex = gridIndex or 1
    o.fallbackIcon = fallbackIcon
    o.headerH = headerH
    o.cellSize = 40
    o.playerNum = playerNum or 0
    o.draggedItem = nil
    o.selectedItems = {}
    
    o.onMouseDoubleClick = self.onMouseDoubleClick
    
    return o
end

function GridRender:initialise()
    ISPanel.initialise(self)
    self.poisonIcon = getTexture("media/ui/SkullPoison.png")
    self.brokenIcon = getTexture("media/ui/icon_broken.png")
end

function GridRender:drawItemIconRotated(item, x, y, w, h, isRotated, r, g, b, a)
    if not item then return end
    local texture = item:getTex() or item:getTexture()
    if not texture then return end
    
    r = r or 1
    g = g or 1
    b = b or 1
    a = a or 1
    
    local texW = texture:getWidth()
    local texH = texture:getHeight()
    
    local isCustomTint = (r ~= 1 or g ~= 1 or b ~= 1)
    
    if not isRotated and not isCustomTint then
        -- Quando não há rotação nem tint especial, usamos o renderizador NATIVO (DrawItemIcon).
        -- Para evitar as margens invisíveis do jogo e deixar o item igualzinho ao tamanho real do Grid:
        -- Calculamos a escala baseada nos pixels VISÍVEIS (getWidth).
        local scale = math.min(w / texW, h / texH)
        
        -- Descobrimos o tamanho que a imagem "com margens" (getWidthOrig) deve ter para o miolo bater na escala
        local fullW = texture:getWidthOrig() * scale
        local fullH = texture:getHeightOrig() * scale
        
        -- Centralizamos o "miolo visível" (croppedW/H) dentro do Grid (w/h)
        local croppedW = texW * scale
        local croppedH = texH * scale
        local centerOffsetX = (w - croppedW) / 2
        local centerOffsetY = (h - croppedH) / 2
        
        -- Subtraímos o offset nativo do jogo (margem da esquerda/topo) pra anular o padding original do DrawItemIcon
        local relX = x + centerOffsetX - (texture:getOffsetX() * scale)
        local relY = y + centerOffsetY - (texture:getOffsetY() * scale)
        
        self.javaObject:DrawItemIcon(item, relX, relY, a, fullW, fullH)
    else
        -- Fallback manual (para itens deitados). Usa geometria de vértices nativos do DrawTexture.
        -- OBS: Máscara de fluido removida do fallback pois a Engine só permite recortar volume d'água via manipulação de UV na API Java.
        local visualTexW = isRotated and texH or texW
        local visualTexH = isRotated and texW or texH
        local scale = math.min(w / visualTexW, h / visualTexH)
        
        local drawW = (isRotated and texH or texW) * scale
        local drawH = (isRotated and texW or texH) * scale
        
        local offsetX = (w - drawW) / 2
        local offsetY = (h - drawH) / 2
        
        local absX = self:getAbsoluteX() + x + offsetX
        local absY = self:getAbsoluteY() + y + offsetY
        
        local hasColorMask = item.getTextureColorMask and item:getTextureColorMask()
        
        local baseR, baseG, baseB = 1, 1, 1
        if not hasColorMask and item.getColor and item:getColor() then
            baseR = item:getColor():getR()
            baseG = item:getColor():getG()
            baseB = item:getColor():getB()
        end
        
        local finalR = isCustomTint and r or baseR
        local finalG = isCustomTint and g or baseG
        local finalB = isCustomTint and b or baseB
        
        local renderTex = function(texToDraw, red, green, blue)
            if not isRotated then
                self.javaObject:DrawTexture(texToDraw, absX, absY, absX+drawW, absY, absX+drawW, absY+drawH, absX, absY+drawH, red, green, blue, a)
            else
                self.javaObject:DrawTexture(texToDraw, absX, absY+drawH, absX, absY, absX+drawW, absY, absX+drawW, absY+drawH, red, green, blue, a)
            end
        end
        
        -- Textura Base (já vem com a sprite de queimado/podre graças ao getTex())
        renderTex(texture, finalR, finalG, finalB)
        
        -- Fluid Mask (Sangue/Água Suja)
        if item.getTextureFluidMask and item:getTextureFluidMask() then
            local fluidColor = {r=1, g=1, b=1}
            local fc = item.getFluidContainer and item:getFluidContainer()
            local fluidPercent = 1.0
            
            if fc then
                fluidColor.r = fc:getColor():getR()
                fluidColor.g = fc:getColor():getG()
                fluidColor.b = fc:getColor():getB()
                
                local cap = fc:getCapacity()
                if cap > 0 then
                    fluidPercent = fc:getAmount() / cap
                end
            elseif instanceof(item, "DrainableComboItem") then
                local maxUses = item:getMaxUses()
                if maxUses > 0 then
                    fluidPercent = item:getCurrentUses() / maxUses
                end
            end
            
            if fluidPercent < 0.15 then fluidPercent = 0.15 end
            if fluidPercent > 1.0 then fluidPercent = 1.0 end
            
            local fmR = isCustomTint and finalR or fluidColor.r
            local fmG = isCustomTint and finalG or fluidColor.g
            local fmB = isCustomTint and finalB or fluidColor.b
            
            local fTex = item:getTextureFluidMask()
            
            if fTex then
                local tx1 = fTex:getXStart()
                local ty1 = fTex:getYStart()
                local tx2 = fTex:getXEnd()
                local ty2 = fTex:getYEnd()
                
                local missing = 1.0 - fluidPercent
                local yD = ty2 - ty1
                
                local tlx, tly = tx1, ty1
                local trx, try = tx2, ty1
                local brx, bry = tx2, ty2
                local blx, bly = tx1, ty2
                
                local relOffsetX = (fTex:getOffsetX() - texture:getOffsetX()) * scale
                local relOffsetY = (fTex:getOffsetY() - texture:getOffsetY()) * scale
                
                if not isRotated then
                    local maskDrawW = fTex:getWidth() * scale
                    local maskDrawH = fTex:getHeight() * scale
                    local maskAbsX = absX + relOffsetX
                    local maskAbsY = absY + relOffsetY
                    
                    tly = tly + yD * missing
                    try = try + yD * missing
                    
                    local screenMissing = maskDrawH * missing
                    local rx = maskAbsX
                    local ry = maskAbsY + screenMissing
                    local rw = maskDrawW
                    local rh = maskDrawH - screenMissing
                    
                    SpriteRenderer.instance:render(fTex, rx, ry, rw, rh, fmR, fmG, fmB, a, tlx, tly, trx, try, brx, bry, blx, bly)
                else
                    local maskDrawW = fTex:getHeight() * scale
                    local maskDrawH = fTex:getWidth() * scale
                    local maskAbsX = absX + relOffsetY
                    local maskAbsY = absY + drawH - relOffsetX - maskDrawH
                    
                    tly = tly + yD * missing
                    try = try + yD * missing
                    
                    local screenMissing = maskDrawW * missing
                    local rx = maskAbsX + screenMissing
                    local ry = maskAbsY
                    local rw = maskDrawW - screenMissing
                    local rh = maskDrawH
                    
                    -- UV mapping for Counter-Clockwise: TL->TR, TR->BR, BR->BL, BL->TL
                    local uv1X, uv1Y = trx, try
                    local uv2X, uv2Y = brx, bry
                    local uv3X, uv3Y = blx, bly
                    local uv4X, uv4Y = tlx, tly
                    
                    SpriteRenderer.instance:render(fTex, rx, ry, rw, rh, fmR, fmG, fmB, a, uv1X, uv1Y, uv2X, uv2Y, uv3X, uv3Y, uv4X, uv4Y)
                end
            end
        end
        
        -- Color Mask (Tintas de Cabelo, etc)
        if hasColorMask then
            local maskR, maskG, maskB = 1, 1, 1
            if item.getColor and item:getColor() then
                maskR = item:getColor():getR()
                maskG = item:getColor():getG()
                maskB = item:getColor():getB()
            end
            local mR = isCustomTint and finalR or maskR
            local mG = isCustomTint and finalG or maskG
            local mB = isCustomTint and finalB or maskB
            renderTex(hasColorMask, mR, mG, mB)
        end
    end
end

function GridRender:prerender()
    ISPanel.prerender(self)
    
    -- Efeito de "Piscar" o Grid quando selecionado/targuetado pelo auto-scroll
    if self.flashAlpha and self.flashAlpha > 0 then
        self:drawRect(0, 0, self.width, self.height, self.flashAlpha * 0.2, 1.0, 0.9, 0.3)
        self:drawRectBorder(0, 0, self.width, self.height, self.flashAlpha, 1.0, 0.9, 0.3)
        
        self.flashAlpha = self.flashAlpha - 0.03 * (UIManager.getMillisSinceLastRender() / 33.3)
        if self.flashAlpha < 0 then
            self.flashAlpha = 0
        end
    end
end

function GridRender:render()
    local mouseX = self:getMouseX()
    local mouseY = self:getMouseY()
    
    if self.headerH and self.headerH > 0 then
        self:drawRect(GRID_PADDING, GRID_PADDING, self.width - (GRID_PADDING*2), self.headerH - 4, 0.5, 0.1, 0.1, 0.1)
        
        local isActive = false
        local pInv = getPlayerInventory(self.playerNum)
        local pLoot = getPlayerLoot(self.playerNum)
        
        if self.inventoryContainer then
            if pInv and pInv.inventory == self.inventoryContainer then
                isActive = true
            elseif pLoot and pLoot.inventory == self.inventoryContainer then
                isActive = true
            end
        end
        
        if isActive then
            self:drawRectBorder(GRID_PADDING, GRID_PADDING, self.width - (GRID_PADDING*2), self.headerH - 4, 0.9, 1.0, 0.9, 0.3)
        else
            self:drawRectBorder(GRID_PADDING, GRID_PADDING, self.width - (GRID_PADDING*2), self.headerH - 4, 0.8, 0.3, 0.3, 0.3)
        end
        
        local text = ""
        local invItem = self.containerItem
        if not invItem and self.inventoryContainer then
            invItem = self.inventoryContainer:getContainingItem()
        end
        
        local tex = nil
        if invItem then
            text = invItem:getName()
            tex = invItem:getTexture()
        elseif self.inventoryContainer then
            if self.inventoryContainer:getType() == "floor" then
                text = getTextOrNull("IGUI_ContainerTitle_floor") or "Floor"
            elseif self.inventoryContainer:getType() == "inventory" or self.inventoryContainer:getType() == "none" then
                text = getTextOrNull("IGUI_InventoryTooltip") or "Inventory"
            else
                local cType = self.inventoryContainer:getType()
                text = getTextOrNull("IGUI_ContainerTitle_" .. tostring(cType)) or cType
            end
            tex = self.fallbackIcon
        end
        
        if self.gridIndex and self.gridIndex > 1 then
            text = text .. " (Overflow)"
        end
        
        local textX = GRID_PADDING + 5
        if tex then
            self:drawTextureScaledAspect(tex, textX, GRID_PADDING + 2, 20, 20, 1, 1, 1, 1)
            textX = textX + 25
        end
        
        self:drawText(text, textX, GRID_PADDING + 4, 0.9, 0.9, 0.9, 1, UIFont.Small)
        
        if self.inventoryContainer and self.inventoryContainer.getCapacityWeight and self.inventoryContainer.getMaxWeight then
            local w = self.inventoryContainer:getCapacityWeight()
            local mw = self.inventoryContainer:getMaxWeight()
            local weightStr = string.format("%.2f / %d", w, mw)
            local rightX = self.width - GRID_PADDING - 5
            self:drawTextRight(weightStr, rightX, GRID_PADDING + 4, 0.9, 0.9, 0.9, 1, UIFont.Small)
        end
    end

    -- Desenha a malha do grid (os quadrados de cada slot)
    for col = 1, self.gridCore.width do
        for row = 1, self.gridCore.height do
            local cellX = GRID_PADDING + ((col - 1) * self.cellSize)
            local cellY = GRID_PADDING + (self.headerH or 0) + ((row - 1) * self.cellSize)
            
            -- Mantém a transparência natural preta, desenhando APENAS a borda
            self:drawRectBorder(cellX, cellY, self.cellSize, self.cellSize, 0.15, 0.5, 0.5, 0.5)
        end
    end

    for itemId, data in pairs(self.gridCore.items) do
        -- Se estivermos arrastando, não renderizamos o item localmente se for um dos arrastados.
        local isDragged = GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid == self and GridInventory_GlobalDrag.itemsMap[itemId]
        
        if not isDragged then
            local drawX = GRID_PADDING + ((data.x - 1) * self.cellSize)
            local drawY = GRID_PADDING + (self.headerH or 0) + ((data.y - 1) * self.cellSize)
            
            local drawW = data.w * self.cellSize
            local drawH = data.h * self.cellSize

            local isSelected = self.selectedItems[itemId]

            if data.itemObj then
                -- B42/B41 Fix: O motor do Zomboid delega o tick de idade e umidade das roupas e comidas à renderização da UI (se estiver num container visível).
                -- Como pulamos o renderdetails do Vanilla, temos que disparar o update nós mesmos!
                if data.itemObj.updateAge then data.itemObj:updateAge() end
                if data.itemObj.updateWetness then data.itemObj:updateWetness() end
                
                local bgR, bgG, bgB, bgA = ITEM_BG_COLOR.r, ITEM_BG_COLOR.g, ITEM_BG_COLOR.b, ITEM_BG_COLOR.a
                
                -- Checa se está congelado ou quente
                local heat = 1
                if data.itemObj.getHeat then heat = data.itemObj:getHeat()
                elseif data.itemObj.getItemHeat then heat = data.itemObj:getItemHeat() end
                
                local invHeat = 0
                if data.itemObj.getInvHeat then invHeat = math.abs(data.itemObj:getInvHeat()) end
                if invHeat > 1 then invHeat = 1 end
                
                local freezeTime = 0
                if data.itemObj.getFreezingTime then freezeTime = data.itemObj:getFreezingTime() / 100 end
                if freezeTime > 1 then freezeTime = 1 end
                
                if (data.itemObj.isFrozen and data.itemObj:isFrozen()) or freezeTime > 0 or heat < 0.99 then
                    -- Frio / Congelando
                    local t = math.max(freezeTime, invHeat)
                    if data.itemObj.isFrozen and data.itemObj:isFrozen() then t = 1.0 end
                    
                    bgR = ITEM_BG_COLOR.r + (ITEM_BG_FROZEN.r - ITEM_BG_COLOR.r) * t
                    bgG = ITEM_BG_COLOR.g + (ITEM_BG_FROZEN.g - ITEM_BG_COLOR.g) * t
                    bgB = ITEM_BG_COLOR.b + (ITEM_BG_FROZEN.b - ITEM_BG_COLOR.b) * t
                elseif heat > 1.01 then
                    -- Quente
                    local t = invHeat
                    bgR = ITEM_BG_COLOR.r + (ITEM_BG_HOT.r - ITEM_BG_COLOR.r) * t
                    bgG = ITEM_BG_COLOR.g + (ITEM_BG_HOT.g - ITEM_BG_COLOR.g) * t
                    bgB = ITEM_BG_COLOR.b + (ITEM_BG_HOT.b - ITEM_BG_COLOR.b) * t
                end
                
                if isSelected then
                    self:drawRect(drawX, drawY, drawW, drawH, bgA + 0.3, bgR + 0.3, bgG + 0.3, bgB + 0.3)
                else
                    self:drawRect(drawX, drawY, drawW, drawH, bgA, bgR, bgG, bgB)
                end
                
                self:drawRectBorder(drawX, drawY, drawW, drawH, 1, 0.7, 0.8, 1.0)

                self:drawItemIconRotated(data.itemObj, drawX, drawY, drawW, drawH, data.rotated, 1, 1, 1, 1)
                
                -- Indicadores de Status Visual (Envenenado / Quebrado)
                local playerObj = getSpecificPlayer(self.playerNum)
                
                -- Veneno / Água Suja
                local isPoison = false
                if instanceof(data.itemObj, "Food") then
                    if (data.itemObj.isTainted and data.itemObj:isTainted()) or (playerObj and playerObj:isKnownPoison(data.itemObj)) then
                        isPoison = true
                    end
                else
                    local fluid = data.itemObj.getFluidContainer and data.itemObj:getFluidContainer()
                    if fluid and not fluid:isEmpty() then
                        if fluid:contains(Fluid.Bleach) or (fluid:contains(Fluid.TaintedWater) and fluid:getPoisonRatio() > 0.1) then
                            isPoison = true
                        end
                    end
                end
                
                if isPoison and self.poisonIcon then
                    self:drawTexture(self.poisonIcon, drawX + 4, drawY + 4, 1, 1, 1, 1)
                end
                
                -- Quebrado (Condição 0)
                local isBroken = false
                if data.itemObj.isBroken and data.itemObj:isBroken() then
                    isBroken = true
                elseif data.itemObj.getCondition and data.itemObj.getConditionMax and data.itemObj:getConditionMax() > 0 and data.itemObj:getCondition() <= 0 then
                    isBroken = true
                end
                
                if isBroken and self.brokenIcon then
                    self:drawTexture(self.brokenIcon, drawX + drawW - 16, drawY + 4, 1, 1, 1, 1)
                end
                
                -- Feedback visual de falta de espaço
                if data.outOfSpaceTimer then
                    if getTimeInMillis() < data.outOfSpaceTimer then
                        self:drawRect(drawX, drawY, drawW, drawH, 0.7, 0.2, 0.05, 0.05)
                        self:drawTextCentre(getText("IGUI_InventoryFull") or "Out of space", drawX + drawW/2, drawY + drawH/2 - 10, 1, 1, 1, 1, UIFont.Small)
                    else
                        data.outOfSpaceTimer = nil
                    end
                end
                
                -- Barra de progresso da ação (preenchendo de baixo pra cima)
                if data.itemObj.getJobDelta then
                    local jobDelta = data.itemObj:getJobDelta()
                    if jobDelta > 0 then
                        local fillH = drawH * jobDelta
                        local fillY = drawY + drawH - fillH
                        -- Verde translúcido: a=0.4, r=0.2, g=0.8, b=0.2
                        self:drawRect(drawX, fillY, drawW, fillH, 0.4, 0.2, 0.8, 0.2)
                    end
                end
            end
        end
    end
    if self.gridCore.ghostItems then
        for gId, gData in pairs(self.gridCore.ghostItems) do
            local drawX = GRID_PADDING + ((gData.x - 1) * self.cellSize)
            local drawY = GRID_PADDING + (self.headerH or 0) + ((gData.y - 1) * self.cellSize)
            local drawW = gData.w * self.cellSize
            local drawH = gData.h * self.cellSize
            
            -- Fundo translúcido cinza para indicar fantasma
            self:drawRect(drawX, drawY, drawW, drawH, 0.3, 0.5, 0.5, 0.5)
            self:drawRectBorder(drawX, drawY, drawW, drawH, 0.5, 0.7, 0.7, 0.7)
            
            if gData.itemObj then
                -- Desenha o item com 50% de opacidade
                self:drawItemIconRotated(gData.itemObj, drawX, drawY, drawW, drawH, gData.rotated, 1, 1, 1, 0.5)
            end
        end
    end

    if self.draggingMarquis then
        local mX = self:getMouseX()
        local mY = self:getMouseY()
        
        local rx = math.min(self.marquisStartX, mX)
        local ry = math.min(self.marquisStartY, mY)
        local rw = math.abs(mX - self.marquisStartX)
        local rh = math.abs(mY - self.marquisStartY)
        
        self:drawRectBorder(rx, ry, rw, rh, 1, 1.0, 1.0, 1.0)
        self:drawRect(rx, ry, rw, rh, 0.2, 1.0, 1.0, 1.0)
    end

    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.itemsData and #GridInventory_GlobalDrag.itemsData > 0 then
        local firstItem = GridInventory_GlobalDrag.itemsData[1].itemObj
        if firstItem and self.inventoryContainer then
            local playerObj = getSpecificPlayer(self.playerNum)
            
            -- Verifica se tentou colocar o container dentro dele mesmo
            if firstItem == self.containerItem then
                self:drawRect(0, 0, self.width, self.height, 0.7, 0.2, 0.05, 0.05)
                self:drawTextCentre(getText("IGUI_CannotStoreItself") or "Cannot store itself", self.width/2, self.height/2 - 10, 1, 0.2, 0.2, 1, UIFont.Large)
                
            -- Verifica se o container rejeita o item categoricamente
            elseif not self.inventoryContainer:isItemAllowed(firstItem) then
                self:drawRect(0, 0, self.width, self.height, 0.7, 0.2, 0.05, 0.05)
                self:drawTextCentre(getText("IGUI_CantStore") or "Impossível Guardar", self.width/2, self.height/2 - 10, 1, 0.2, 0.2, 1, UIFont.Large)
                
            -- Verifica capacidade física de peso (Engine Java)
            elseif not self.inventoryContainer:hasRoomFor(playerObj, firstItem) then
                self:drawRect(0, 0, self.width, self.height, 0.7, 0.2, 0.05, 0.05)
                self:drawTextCentre(getText("IGUI_Overloaded") or "Sobrecarregado", self.width/2, self.height/2 - 10, 1, 0.2, 0.2, 1, UIFont.Large)
                
            -- Verifica se há espaço matemático no Grid
            else
                local hasGridSpace = false
                local gridContainer = GridContainer.instances[self.inventoryContainer]
                if gridContainer then
                    local w, h = ItemFootprint.getSize(firstItem)
                    for _, grid in ipairs(gridContainer.grids) do
                        local fx, fy = grid:findFreeSpace(firstItem:getID(), w, h)
                        if not fx then fx, fy = grid:findFreeSpace(firstItem:getID(), h, w) end
                        if fx and fy then
                            hasGridSpace = true
                            break
                        end
                    end
                else
                    hasGridSpace = true -- Fallback se a malha não tiver inicializado (raro)
                end
                
                if not hasGridSpace then
                    self:drawRect(0, 0, self.width, self.height, 0.7, 0.2, 0.05, 0.05)
                    self:drawTextCentre(getText("IGUI_NoGridSpace") or "Sem Espaço", self.width/2, self.height/2 - 10, 1, 0.2, 0.2, 1, UIFont.Large)
                else
                    -- Espaço liberado! Verifica só se estamos desequipando pra dar dica visual.
                    local isFromPaperDoll = GridInventory_GlobalDrag.sourceGrid and GridInventory_GlobalDrag.sourceGrid.slotName
                    if isFromPaperDoll then
                        local isInPlayerInv = self.inventoryContainer:isInCharacterInventory(playerObj)
                        if isInPlayerInv then
                            self:drawRect(0, 0, self.width, self.height, 0.7, 0.1, 0.1, 0.1)
                            self:drawTextCentre(getText("IGUI_Unequip") or "Desequipar", self.width/2, self.height/2 - 10, 1, 0.3, 0.3, 1, UIFont.Large)
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- SISTEMA DE DRAG AND DROP E CONTEXT MENU
-- ============================================================================

function GridRender:getGridCellAtMouse(x, y)
    local col = math.floor((x - GRID_PADDING) / self.cellSize) + 1
    local row = math.floor((y - GRID_PADDING - (self.headerH or 0)) / self.cellSize) + 1
    if col >= 1 and col <= self.gridCore.width and row >= 1 and row <= self.gridCore.height then
        return col, row
    end
    return nil, nil
end

function GridRender:onMouseDown(x, y)
    -- Verifica se clicou no Header!
    if self.headerH and self.headerH > 0 then
        if y >= GRID_PADDING and y <= GRID_PADDING + self.headerH then
            local pLoot = getPlayerLoot(self.playerNum)
            local pInv = getPlayerInventory(self.playerNum)
            local found = false
            
            for _, page in ipairs({pLoot, pInv}) do
                if page and page.backpacks and not found then
                    for _, btn in ipairs(page.backpacks) do
                        if btn.inventory == self.inventoryContainer then
                            page:selectContainer(btn)
                            found = true
                            break
                        end
                    end
                end
            end
            
            return -- Aborta o resto do clique pois foi no header
        end
    end

    local col, row = self:getGridCellAtMouse(x, y)
    local itemId = nil
    
    if col and row then
        itemId = self.gridCore.cells[col][row]
    end

    if not itemId then
        local now = getTimeInMillis()
        if self.lastEmptyClickTime and (now - self.lastEmptyClickTime < 500) then
            self.lastEmptyClickTime = nil
            
            -- Lógica de selecionar container (similar ao click no Header)
            local pLoot = getPlayerLoot(self.playerNum)
            local pInv = getPlayerInventory(self.playerNum)
            local found = false
            for _, page in ipairs({pLoot, pInv}) do
                if page and page.backpacks and not found then
                    for _, btn in ipairs(page.backpacks) do
                        if btn.inventory == self.inventoryContainer then
                            page:selectContainer(btn)
                            found = true
                            break
                        end
                    end
                end
            end
            
            return -- Aborta a seleção em área pois foi um duplo clique no fundo
        end
        self.lastEmptyClickTime = now

        -- Inicia seleção em área!
        self.draggingMarquis = true
        self.marquisStartX = x
        self.marquisStartY = y
        if not isShiftKeyDown() then
            self.selectedItems = {}
        end
        return
    end

    if itemId then
        if isShiftKeyDown() then
            self.selectedItems[itemId] = not self.selectedItems[itemId]
            self.lastManualClickTime = nil
            self.lastManualClickItemId = nil
            return -- Se tá segurando shift só marca/desmarca, não arrasta e não ativa duplo clique
        end

        -- Lógica customizada de Double Click (ignora restrição severa de pixels do Java)
        local now = getTimeInMillis()
        if self.lastManualClickTime and self.lastManualClickItemId and (now - self.lastManualClickTime < 500) and self.lastManualClickItemId == itemId then
            self.lastManualClickTime = nil
            self.lastManualClickItemId = nil
            self:doDoubleClick(x, y)
            return -- Aborta o onMouseDown normal pois foi um clique duplo
        end
        
        self.lastManualClickTime = now
        self.lastManualClickItemId = itemId
        
        -- Salva as informações de clique para preparar o drag no onMouseMove (NÃO seleciona instantaneamente para evitar piscar verde em clicks limpos)
        self.clickedItemId = itemId
        self.clickX = x
        self.clickY = y
        self.clickCol = col
        self.clickRow = row
    end
end

function GridRender:onMouseMove(dx, dy)
    if self.draggingMarquis then
        local mX = self:getMouseX()
        local mY = self:getMouseY()
        
        local rx = math.min(self.marquisStartX, mX)
        local ry = math.min(self.marquisStartY, mY)
        local rw = math.abs(mX - self.marquisStartX)
        local rh = math.abs(mY - self.marquisStartY)
    elseif self.clickedItemId and not GridInventory_GlobalDrag then
        local mX = self:getMouseX()
        local mY = self:getMouseY()
        
        if math.abs(mX - self.clickX) > 4 or math.abs(mY - self.clickY) > 4 then
            
            -- É um drag! Seleciona o item agarrado agora (se não estiver selecionado previamente com shift)
            if not self.selectedItems[self.clickedItemId] then
                self.selectedItems = {}
                self.selectedItems[self.clickedItemId] = true
            end

            local dragList = {}
            local dragMap = {}
            local nativeList = {}
            
            for selectedId, _ in pairs(self.selectedItems) do
                local itemData = self.gridCore.items[selectedId]
                if itemData then
                    local ItemFootprint = require("Algorithm/ItemFootprint")
                    local trueW, trueH = ItemFootprint.getSize(itemData.itemObj)
                    
                    -- Verifica se o grid em que o item estava forçou um tamanho falso (como 1x1 no Overflow/PaperDoll)
                    local isForcedSize = (itemData.w ~= trueW and itemData.w ~= trueH) or (itemData.h ~= trueW and itemData.h ~= trueH)
                    local rotated = itemData.rotated
                    
                    if isForcedSize then
                        rotated = false -- Ao restaurar o tamanho real, reseta a rotação pro padrão
                    end

                    local grabOffsetX = self.clickCol - itemData.x
                    local grabOffsetY = self.clickRow - itemData.y
                    
                    if isForcedSize then
                        grabOffsetX = 0
                        grabOffsetY = 0
                    end

                    local dData = {
                        id = selectedId,
                        originalX = itemData.x,
                        originalY = itemData.y,
                        originalW = trueW,
                        originalH = trueH,
                        grabOffsetX = grabOffsetX,
                        grabOffsetY = grabOffsetY,
                        rotated = rotated,
                        itemObj = itemData.itemObj
                    }
                    table.insert(dragList, dData)
                    dragMap[selectedId] = true
                    if itemData.itemObj then
                        table.insert(nativeList, itemData.itemObj)
                    end
                end
            end

            if #dragList > 0 then
                GridInventory_GlobalDrag = {
                    itemsData = dragList,
                    itemsMap = dragMap,
                    anchorId = self.clickedItemId,
                    sourceGrid = self
                }
                
                ISMouseDrag.dragging = nativeList
                ISMouseDrag.draggingFocus = self
                
                -- Muito importante: Limpa o clique inicial para não criar um drag fantasma caso solte o item fora deste painel e volte o mouse depois
                self.clickedItemId = nil
            end
        end
    end
end

function GridRender:doDoubleClick(x, y)
    local col, row = self:getGridCellAtMouse(x, y)
    if not col or not row then return end
    
    local itemId = nil
    if self.gridCore and self.gridCore.cells and self.gridCore.cells[col] then
        itemId = self.gridCore.cells[col][row]
    end
    if not itemId then return end
    
    -- Evita spam de double click na mesma ação
    local now = getTimeInMillis()
    if self.lastActionTime and (now - self.lastActionTime < 300) then return end
    self.lastActionTime = now
    
    self.selectedItems = {} -- Limpa a seleção para não ofuscar o progresso verde
    
    local itemData = self.gridCore.items[itemId]
    if not itemData or not itemData.itemObj then return end
    
    local item = itemData.itemObj
    local playerObj = getSpecificPlayer(self.playerNum)
    local playerInvUI = getPlayerInventory(self.playerNum)
    
    -- Se o inventário da esquerda (player) estiver aberto, pegamos EXATAMENTE a aba selecionada no momento.
    -- Se por acaso falhar, caímos para o inventário principal do personagem
    local targetInv = playerObj:getInventory()
    if playerInvUI and playerInvUI.inventoryPane and playerInvUI.inventoryPane.inventory then
        targetInv = playerInvUI.inventoryPane.inventory
    end
    
    if self.inventoryContainer ~= targetInv then
        -- Loot ou Mochila Diferente -> Mochila Selecionada no Painel do Jogador
        if isForceDropHeavyItem(item) then
            ISInventoryPaneContextMenu.equipHeavyItem(playerObj, item)
        else
            -- 1. Verifica se cabe no targetInv!
            local ItemFootprint = require("Algorithm/ItemFootprint")
            local GridContainer = require("DataModel/GridContainer")
            local w, h = ItemFootprint.getSize(item)
            local targetGrid = GridContainer.instances[targetInv]
            
            local canFitInTarget = false
            -- Antes de olhar a geometria, checa a capacidade de peso!
            if targetInv:hasRoomFor(playerObj, item) and targetGrid and targetGrid.grids and targetGrid.grids[1] then
                -- Checa se cabe na posição original
                local fx, fy = targetGrid.grids[1]:findFreeSpace(item:getID(), w, h)
                -- Se não couber, tenta rotacionado
                if not fx then
                    fx, fy = targetGrid.grids[1]:findFreeSpace(item:getID(), h, w)
                end
                
                if fx and fy then
                    canFitInTarget = true
                end
            end
            
            local isFromEquippedBag = self.inventoryContainer:isInCharacterInventory(playerObj)
            
            local canFitAnywhere = canFitInTarget
            -- Se não couber no alvo principal, e for do Loot, verificamos se cabe em QUALQUER outra mochila ou bolsos
            if not canFitInTarget and not isFromEquippedBag then
                for i = 0, playerObj:getWornItems():size() - 1 do
                    local wornItem = playerObj:getWornItems():get(i):getItem()
                    if wornItem and wornItem:IsInventoryContainer() then
                        local bagInv = wornItem:getInventory()
                        local bagGrid = GridContainer.instances[bagInv]
                        if bagInv:hasRoomFor(playerObj, item) and bagGrid and bagGrid.grids and bagGrid.grids[1] then
                            local bfx, bfy = bagGrid.grids[1]:findFreeSpace(item:getID(), w, h)
                            if not bfx then bfx, bfy = bagGrid.grids[1]:findFreeSpace(item:getID(), h, w) end
                            if bfx and bfy then
                                canFitAnywhere = true
                                break
                            end
                        end
                    end
                end
                
                if not canFitAnywhere then
                    local pInv = playerObj:getInventory()
                    local pGrid = GridContainer.instances[pInv]
                    if pInv:hasRoomFor(playerObj, item) and pGrid and pGrid.grids and pGrid.grids[1] then
                        local pfx, pfy = pGrid.grids[1]:findFreeSpace(item:getID(), w, h)
                        if not pfx then pfx, pfy = pGrid.grids[1]:findFreeSpace(item:getID(), h, w) end
                        if pfx and pfy then
                            canFitAnywhere = true
                        end
                    end
                end
            end
            
            -- Se couber no target (ou se for do Loot e couber em qualquer lugar), transfere normal
            if canFitInTarget or (not isFromEquippedBag and canFitAnywhere) then
                if luautils.walkToContainer(self.inventoryContainer, self.playerNum) then
                    ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(playerObj, item, self.inventoryContainer, targetInv))
                end
            else
                -- Veio de uma mochila equipada e a raiz ta cheia:
                -- Tenta equipar nas mãos pra não dar loop de unpack!
                local primary = playerObj:getPrimaryHandItem()
                local secondary = playerObj:getSecondaryHandItem()
                
                if isFromEquippedBag and primary == nil then
                    if luautils.walkToContainer(self.inventoryContainer, self.playerNum) then
                        ISInventoryPaneContextMenu.equipWeapon(item, true, false, self.playerNum)
                    end
                elseif isFromEquippedBag and secondary == nil then
                    if luautils.walkToContainer(self.inventoryContainer, self.playerNum) then
                        ISInventoryPaneContextMenu.equipWeapon(item, false, false, self.playerNum)
                    end
                else
                    -- Feedback visual "Sem Espaço"
                    itemData.outOfSpaceTimer = getTimeInMillis() + 1500
                end
            end
        end
    else
        -- Contextual double click (Equip / Wear / Eat, etc)
        local invUI = getPlayerInventory(self.playerNum)
        if invUI and invUI.inventoryPane then
            invUI.inventoryPane:doContextualDblClick(item)
        end
    end
end

function GridRender:onMouseDoubleClick(x, y)
    -- O Zomboid chama isso se os pixels não mudarem mais de 5 e for dentro de 500ms.
    -- Como nós já interceptamos no onMouseDown de forma mais robusta, apenas chamamos nosso método.
    self:doDoubleClick(x, y)
    return true
end

function GridRender:onMouseUp(x, y)
    self.clickedItemId = nil
    if self.draggingMarquis then
        self.draggingMarquis = false
        local mX = self:getMouseX()
        local mY = self:getMouseY()
        
        local rx = math.min(self.marquisStartX, mX)
        local ry = math.min(self.marquisStartY, mY)
        local rw = math.abs(mX - self.marquisStartX)
        local rh = math.abs(mY - self.marquisStartY)
        
        for itemId, data in pairs(self.gridCore.items) do
            local itemX = GRID_PADDING + ((data.x - 1) * self.cellSize)
            local itemY = GRID_PADDING + (self.headerH or 0) + ((data.y - 1) * self.cellSize)
            local itemW = data.w * self.cellSize
            local itemH = data.h * self.cellSize
            
            -- Checa interseção de retângulos simples
            if itemX < rx + rw and itemX + itemW > rx and itemY < ry + rh and itemY + itemH > ry then
                self.selectedItems[itemId] = true
            end
        end
        return
    end

    -- Se temos um drag global iniciado por nós mesmos, estamos soltando itens do próprio grid
    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid == self then
        local dropCol, dropRow = self:getGridCellAtMouse(x, y)
        local itemsData = GridInventory_GlobalDrag.itemsData
        
        if dropCol and dropRow then
            -- Tenta colocar todos ou nenhum (modo estrito para evitar perda de itens)
            local allCanPlace = true
            local targets = {}
            
            for _, draggedItem in ipairs(itemsData) do
                local effectiveW = draggedItem.rotated and draggedItem.originalH or draggedItem.originalW
                local effectiveH = draggedItem.rotated and draggedItem.originalW or draggedItem.originalH
                
                local targetX = dropCol - draggedItem.grabOffsetX
                local targetY = dropRow - draggedItem.grabOffsetY
                
                if targetX < 1 then targetX = 1 end
                if targetY < 1 then targetY = 1 end
                
                if not self.gridCore:canPlaceItem(draggedItem.id, targetX, targetY, effectiveW, effectiveH, draggedItem.id) then
                    allCanPlace = false
                    break
                end
                
                table.insert(targets, {item = draggedItem, tx = targetX, ty = targetY, ew = effectiveW, eh = effectiveH})
            end
            
            if allCanPlace then
                for _, t in ipairs(targets) do
                    self.gridCore:insertItem(t.item.id, t.tx, t.ty, t.ew, t.eh, t.item.rotated, t.item.itemObj)
                    if t.item.itemObj then
                        local modData = t.item.itemObj:getModData()
                        modData.gridX = t.tx
                        modData.gridY = t.ty
                        modData.gridRot = t.item.rotated
                    end
                end
                self.selectedItems = {} -- Limpa seleção após mover com sucesso
            end
        end

        if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid then
            GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
        end
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
        return
    end

    -- Se não é um drag do mesmo grid, mas estamos arrastando algo de outro lugar
    if ISMouseDrag.dragging and #ISMouseDrag.dragging > 0 then
        local dropCol, dropRow = self:getGridCellAtMouse(x, y)
        if dropCol and dropRow then
            -- Verifica se é um drag de outro grid nosso (temos os offsets e rotação!)
            local globalDragItems = nil
            if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid ~= self then
                globalDragItems = GridInventory_GlobalDrag.itemsData
            end

            local ItemFootprint = require("Algorithm/ItemFootprint")
            local isMultiDrag = (#ISMouseDrag.dragging > 1)
            if globalDragItems and #globalDragItems > 1 then
                isMultiDrag = true
            end
            
            local isFromPaperDoll = GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid and GridInventory_GlobalDrag.sourceGrid.slotName

            for index, itemObj in ipairs(ISMouseDrag.dragging) do
                if type(itemObj) == "table" and itemObj.items then
                    itemObj = itemObj.items[1]
                end
                
                -- Se o item vem de outro container, ou se está equipado e jogamos no próprio inventário
                local isEquipped = itemObj:isEquipped()
                local srcContainer = itemObj:getContainer()
                
                if srcContainer ~= self.inventoryContainer or isEquipped then
                    local targetX = dropCol
                    local targetY = dropRow
                    local rotated = false
                    
                    local fw, fh = ItemFootprint.getSize(itemObj)
                    local effectiveW = fw
                    local effectiveH = fh
                    
                    if isMultiDrag then
                        -- Se for múltiplos itens, joga o controle pela janela e deixa o AutoSort agir
                        local modData = itemObj:getModData()
                        modData.gridX = nil
                        modData.gridY = nil
                        modData.gridRot = false
                        
                        if itemObj == self.containerItem or not self.inventoryContainer:isItemAllowed(itemObj) then
                            -- Ignora, não pode guardar dentro de si mesmo ou item não é permitido
                        elseif isFromPaperDoll and srcContainer == self.inventoryContainer then
                            local playerObj = getSpecificPlayer(self.playerNum)
                            if playerObj then
                                if itemObj:getAttachedSlot() > -1 then
                                    ISTimedActionQueue.add(ISDetachItemHotbar:new(playerObj, itemObj))
                                else
                                    ISTimedActionQueue.add(ISUnequipAction:new(playerObj, itemObj, 50))
                                end
                            end
                        else
                            -- Transfere normalmente (Sem criar fantasma)
                            local playerInv = getPlayerInventory(self.playerNum)
                            if playerInv and playerInv.inventoryPane then
                                playerInv.inventoryPane:transferItemsByWeight({itemObj}, self.inventoryContainer)
                            end
                        end
                    else
                        -- Controle fino para 1 único item
                        if globalDragItems and globalDragItems[index] then
                            local dData = globalDragItems[index]
                            targetX = dropCol - (dData.grabOffsetX or 0)
                            targetY = dropRow - (dData.grabOffsetY or 0)
                            rotated = dData.rotated
                            effectiveW = dData.rotated and (dData.originalH or fh) or (dData.originalW or fw)
                            effectiveH = dData.rotated and (dData.originalW or fw) or (dData.originalH or fh)
                        end
                        
                        if targetX < 1 then targetX = 1 end
                        if targetY < 1 then targetY = 1 end
                        
                        if not self.gridCore:canPlaceItem(itemObj:getID(), targetX, targetY, effectiveW, effectiveH) then
                            local fx, fy = self.gridCore:findFreeSpace(itemObj:getID(), effectiveW, effectiveH)
                            if fx and fy then
                                targetX = fx
                                targetY = fy
                            else
                                -- Saco cheio!
                                targetX = nil
                                targetY = nil
                            end
                        end
                        
                        if targetX and targetY then
                            if itemObj == self.containerItem or not self.inventoryContainer:isItemAllowed(itemObj) then
                                -- Ignora
                            else
                                local modData = itemObj:getModData()
                                modData.gridX = targetX
                                modData.gridY = targetY
                                modData.gridRot = rotated
                                
                                if isFromPaperDoll and srcContainer == self.inventoryContainer then
                                    local playerObj = getSpecificPlayer(self.playerNum)
                                    if playerObj then
                                        if itemObj:getAttachedSlot() > -1 then
                                            ISTimedActionQueue.add(ISDetachItemHotbar:new(playerObj, itemObj))
                                        else
                                            ISTimedActionQueue.add(ISUnequipAction:new(playerObj, itemObj, 50))
                                        end
                                    end
                                else
                                    self.gridCore:addGhostItem(itemObj:getID(), itemObj, targetX, targetY, effectiveW, effectiveH, rotated)
                                    local playerInv = getPlayerInventory(self.playerNum)
                                    if playerInv and playerInv.inventoryPane then
                                        playerInv.inventoryPane:transferItemsByWeight({itemObj}, self.inventoryContainer)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid then
            GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
        end
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
        return
    end

    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid then
        GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
    end
    GridInventory_GlobalDrag = nil
    ISMouseDrag.dragging = nil
    ISMouseDrag.draggingFocus = nil
end

function GridRender:onMouseUpOutside(x, y)
    -- Não limpe o drag aqui! Zomboid dispara isso MUITO CEDO, 
    -- antes que os outros painéis (como o Loot) tenham a chance de processar o onMouseUp!
    -- A limpeza será feita no GridRender:update()
end

function GridRender:onRightMouseUp(x, y)
    if GridInventory_GlobalDrag then
        -- Rotaciona TODOS os itens sendo arrastados no grupo!
        for _, draggedItem in ipairs(GridInventory_GlobalDrag.itemsData) do
            draggedItem.rotated = not draggedItem.rotated
            draggedItem.grabOffsetX, draggedItem.grabOffsetY = draggedItem.grabOffsetY, draggedItem.grabOffsetX
        end
    else
        local col, row = self:getGridCellAtMouse(x, y)
        if col and row then
            local itemId = self.gridCore.cells[col][row]
            if itemId then
                local itemData = self.gridCore.items[itemId]
                if itemData and itemData.itemObj then
                    local inv = itemData.itemObj:getContainer()
                    local isInPlayerInv = inv and inv:isInCharacterInventory(getSpecificPlayer(self.playerNum)) or false
                    
                    ISInventoryPaneContextMenu.createMenu(self.playerNum, isInPlayerInv, {itemData.itemObj}, self:getAbsoluteX() + x, self:getAbsoluteY() + y)
                end
            end
        end
    end
end

function GridRender:removeFromUIManager()
    self:destroy()
    ISPanel.removeFromUIManager(self)
end

function GridRender:destroy()
    if self.toolRender then
        self.toolRender:removeFromUIManager()
        self.toolRender:setVisible(false)
        self.toolRender = nil
    end
end

function GridRender:updateTooltip()
    -- Checa se o mouse está sobre esse grid E sobre o painel pai (para evitar tooltips quando scrollar o grid pra fora da view)
    local isOver = self:isMouseOver()
    if isOver and self.parent and not self.parent:isMouseOver() then
        isOver = false
    end
    
    if not isOver or not self:getIsVisible() then
        if self.toolRender then
            self.toolRender:removeFromUIManager()
            self.toolRender:setVisible(false)
            self.toolRender = nil
        end
        return
    end
    
    local mx = self:getMouseX()
    local my = self:getMouseY()
    local col, row = self:getGridCellAtMouse(mx, my)
    
    local hoveredItem = nil
    if col and row and self.gridCore and self.gridCore.cells then
        local itemId = self.gridCore.cells[col][row]
        if itemId and self.gridCore.items[itemId] then
            hoveredItem = self.gridCore.items[itemId].itemObj
        end
    end
    
    if hoveredItem and not ISMouseDrag.dragging and not GridInventory_GlobalDrag and not self.draggingMarquis then
        if not self.toolRender then
            self.toolRender = ISToolTipInv:new(hoveredItem)
            self.toolRender:initialise()
            self.toolRender:addToUIManager()
            self.toolRender:setOwner(self)
            self.toolRender:setCharacter(getSpecificPlayer(self.playerNum))
        end
        self.toolRender:setItem(hoveredItem)
        self.toolRender:setVisible(true)
        self.toolRender:bringToTop()
        
        local gmx = getMouseX()
        local gmy = getMouseY()
        
        local tx = gmx + 15
        local ty = gmy + 15
        
        if self.toolRender.width and (tx + self.toolRender.width > getCore():getScreenWidth()) then
            tx = gmx - self.toolRender.width - 15
        end
        if self.toolRender.height and (ty + self.toolRender.height > getCore():getScreenHeight()) then
            ty = gmy - self.toolRender.height - 15
        end
        
        self.toolRender:setX(tx)
        self.toolRender:setY(ty)
    else
        if self.toolRender then
            self.toolRender:removeFromUIManager()
            self.toolRender:setVisible(false)
            self.toolRender = nil
        end
    end
end

function GridRender:update()
    ISPanel.update(self)
    self:updateTooltip()

    if self.gridCore and self.gridCore.ghostItems then
        local playerObj = getSpecificPlayer(self.playerNum)
        local q = ISTimedActionQueue.getTimedActionQueue(playerObj)
        local activeTransfers = {}
        
        if q then
            if q.action and q.action.item and type(q.action.item) == "userdata" and q.action.item.getID then
                activeTransfers[q.action.item:getID()] = true
            end
            if q.queue then
                for i = 1, #q.queue do
                    local act = q.queue[i]
                    if act.item and type(act.item) == "userdata" and act.item.getID then
                        activeTransfers[act.item:getID()] = true
                    end
                end
            end
        end

        local currentTime = getTimeInMillis()
        for gId, gData in pairs(self.gridCore.ghostItems) do
            -- Apaga o fantasma se não houver NENHUMA action pendente pra ele na queue
            -- e já tiver passado 500ms desde a criação (pra não matar no 1º frame antes da action nascer)
            if not activeTransfers[gId] and (currentTime - gData.timeAdded > 500) then
                self.gridCore:removeGhostItem(gId)
            end
        end
    end

    -- Se o mouse foi solto (em qualquer lugar da tela)
    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid == self and not isMouseButtonDown(0) then
        local mx = getMouseX()
        local my = getMouseY()
        local uis = UIManager.getUI()
        local mouseOverUI = false
        
        -- Zomboid loop pra ver se o mouse soltou em cima de alguma interface
        for i=0,uis:size()-1 do
            local ui = uis:get(i)
            if ui:isPointOver(mx, my) then
                mouseOverUI = true
                break
            end
        end

        -- Se não soltou em nenhuma UI, significa que soltou no chão (Mundo 3D)!
        if not mouseOverUI then
            for _, draggedItem in ipairs(GridInventory_GlobalDrag.itemsData) do
                if draggedItem and draggedItem.itemObj then
                    ISInventoryPaneContextMenu.dropItem(draggedItem.itemObj, self.playerNum)
                end
            end
        end

        -- Independente se caiu no chão, no Loot, ou no vácuo, limpar a renderização global
        if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid then
            GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
        end
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
        self.draggingMarquis = false
    end
    
    if not isMouseButtonDown(0) then
        self.clickedItemId = nil
        if self.draggingMarquis then
            self.draggingMarquis = false
            -- Seleção termina fora do painel
        end
    end
end

return GridRender
