require "ISUI/ISPanel"
require "TimedActions/ISWearClothing"
require "TimedActions/ISEquipWeaponAction"
require "TimedActions/ISUnequipAction"
require "TimedActions/ISInventoryTransferAction"

local PaperDollSlot = ISPanel:derive("PaperDollSlot")

-- Cache por player do wornItems: os slots de localização varrem o wornItems
-- inteiro (com tostring/lower por item) varias vezes por frame por slot.
-- Cacheamos o mapa localização->item e so reconstruimos quando o
-- PaperDollWindow:update detecta mudanca (GridInventory_WornCacheEpoch).
local wornLocationCaches = {}

local function getWornLocationCache(playerNum, player)
    local epoch = (GridInventory_WornCacheEpoch and GridInventory_WornCacheEpoch[playerNum]) or 0
    local cache = wornLocationCaches[playerNum]
    if cache and cache.epoch == epoch then
        return cache
    end
    cache = { epoch = epoch, byLocation = {} }
    local wornItems = player:getWornItems()
    local size = wornItems:size()
    for i = 0, size - 1 do
        local worn = wornItems:get(i)
        local itemObj = worn:getItem()
        local loc = worn:getLocation()
        local locStr = tostring(loc)
        if type(loc) == "userdata" and loc.getId then
            locStr = loc:getId()
        elseif type(loc) == "userdata" and loc.name then
            locStr = loc:name()
        end
        local idPart = string.lower(locStr)
        if string.find(idPart, ":") then
            idPart = string.sub(idPart, string.find(idPart, ":") + 1)
        end
        if not cache.byLocation[idPart] then
            cache.byLocation[idPart] = {}
        end
        table.insert(cache.byLocation[idPart], itemObj)
    end
    wornLocationCaches[playerNum] = cache
    return cache
end

function PaperDollSlot:initialise()
    ISPanel.initialise(self)
    
    self.shortSlotName = self.slotName or ""
    local maxW = self.width - 4
    if getTextManager():MeasureStringX(UIFont.Small, self.shortSlotName) > maxW then
        while string.len(self.shortSlotName) > 0 and getTextManager():MeasureStringX(UIFont.Small, self.shortSlotName .. "...") > maxW do
            self.shortSlotName = string.sub(self.shortSlotName, 1, string.len(self.shortSlotName) - 1)
        end
        self.shortSlotName = self.shortSlotName .. "..."
    end
end

function PaperDollSlot:render()
    ISPanel.render(self)
    
    local isHovered = self:isMouseOver()
    local isDragging = (ISMouseDrag.dragging and #ISMouseDrag.dragging > 0) or GridInventory_GlobalDrag
    local canAccept = false
    
    if isDragging then
        canAccept = self:canAcceptDraggedItem()
    end
    
    if canAccept then
        self:drawRect(0, 0, self.width, self.height, 0.4, 0.2, 0.8, 0.2)
    elseif isHovered then
        self:drawRect(0, 0, self.width, self.height, 0.2, 0.3, 0.3, 0.3)
    end
    
    -- Borda sutil igual ao do Grid
    self:drawRectBorder(0, 0, self.width, self.height, 0.15, 0.5, 0.5, 0.5)
    
    -- getEquippedItems() aloca uma tabela nova + varredura Java: chama UMA vez
    -- por frame e deriva item + contagem do MESMO resultado (antes o getEquippedItem
    -- chamava getEquippedItems internamente e depois chamávamos de novo no #items).
    local items = self:getEquippedItems()
    local item = nil
    if #items > 0 then
        if not self.activeIndex or self.activeIndex > #items or self.lastItemsCount ~= #items then
            self.activeIndex = #items
            self.lastItemsCount = #items
        end
        item = items[self.activeIndex]
    end
    if item then
        local tex = item:getTex()
        if tex then
            local r, g, b = 1, 1, 1
            if item.getColor and item:getColor() then
                r = item:getColor():getR()
                g = item:getColor():getG()
                b = item:getColor():getB()
            end
            self:drawTextureScaledAspect(tex, 4, 4, self.width - 8, self.height - 8, 1, r, g, b)
        end
        
        if #items > 1 then
            local text = tostring(self.activeIndex or 1) .. "/" .. tostring(#items)
            local uiScale = (GridInventory_uiScale or 100) / 100
            local font = UIFont.Small
            if uiScale >= 1.5 then font = UIFont.Large elseif uiScale >= 1.25 then font = UIFont.Medium end
            
            local tw = getTextManager():MeasureStringX(font, text)
            local th = getTextManager():MeasureStringY(font, text)
            
            self:drawRect(self.width - tw - 4, self.height - th - 4, tw + 4, th + 4, 0.7, 0, 0, 0)
            self:drawText(text, self.width - tw - 2, self.height - th - 2, 1, 1, 1, 1, font)
        end
    else
        if self.hotbarProviderTexture then
            local uiScale = (GridInventory_uiScale or 100) / 100
            local pad = math.floor(8 * uiScale)
            self:drawTextureScaledAspect(self.hotbarProviderTexture, pad, pad, self.width - (pad * 2), self.height - (pad * 2), 0.4, 1, 1, 1)
        else
            local uiScale = (GridInventory_uiScale or 100) / 100
            local font = UIFont.Small
            if uiScale >= 1.5 then font = UIFont.Large elseif uiScale >= 1.25 then font = UIFont.Medium end
            local fh = getTextManager():MeasureStringY(font, "A")
            self:drawTextCentre(self.shortSlotName, self.width/2, (self.height - fh)/2, 0.3, 0.3, 0.3, 1, font)
        end
    end
    
    if item and self.hotbarProviderTexture then
        local uiScale = (GridInventory_uiScale or 100) / 100
        local pSize = math.floor(28 * uiScale)
        local pad = math.floor(4 * uiScale)
        self:drawTextureScaledAspect(self.hotbarProviderTexture, self.width - pSize - pad, self.height - pSize - pad, pSize, pSize, 1, 1, 1, 1)
    end

    -- Slot selecionado pelo joypad (modo PaperDoll: LB+RB segurados).
    if self.joySelected then
        self:drawRect(0, 0, self.width, self.height, 0.35, 1.0, 1.0, 0.45)
        self:drawRectBorder(0, 0, self.width, self.height, 1.3, 1.0, 1.0, 1.0)
    end
end

function PaperDollSlot:canAcceptDraggedItem()
    local itemsToEquip = {}
    if ISMouseDrag.dragging and #ISMouseDrag.dragging > 0 then
        for _, itemObj in ipairs(ISMouseDrag.dragging) do
            if type(itemObj) == "table" and itemObj.items then
                table.insert(itemsToEquip, itemObj.items[1])
            else
                table.insert(itemsToEquip, itemObj)
            end
        end
    elseif GridInventory_GlobalDrag then
        for _, dData in ipairs(GridInventory_GlobalDrag.itemsData) do
            table.insert(itemsToEquip, dData.itemObj)
        end
    end
    
    if #itemsToEquip > 0 then
        local item = itemsToEquip[1]
        
        -- HOTBAR SUPPORT
        if self.hotbarRef and self.hotbarSlotIndex then
            local slot = self.hotbarRef.availableSlot[self.hotbarSlotIndex]
            if slot and self.hotbarRef:canBeAttached(slot, item) then
                return true
            end
            return false
        end
        
        if type(self.locations) == "table" and (self.locations[1] == "PRIMARY" or self.locations[1] == "SECONDARY") then
            return true
        else
            if item:IsClothing() or item:IsInventoryContainer() then
                local itemLoc = (item:IsClothing() or item:IsInventoryContainer()) and item:getBodyLocation() or item:canBeEquipped()
                if itemLoc and itemLoc ~= "" then
                    local itemLocStr = tostring(itemLoc)
                    if type(itemLoc) == "userdata" and itemLoc.getId then
                        itemLocStr = itemLoc:getId()
                    elseif type(itemLoc) == "userdata" and itemLoc.name then
                        itemLocStr = itemLoc:name()
                    end
                    
                    local idPart = string.lower(itemLocStr)
                    if string.find(idPart, ":") then
                        idPart = string.sub(idPart, string.find(idPart, ":") + 1)
                    end
                    
                    if type(self.locations) == "table" then
                        for _, pattern in ipairs(self.locations) do
                            if idPart == string.lower(pattern) then return true end
                        end
                    else
                        local myLocStr = tostring(self.locations)
                        if type(self.locations) == "userdata" and self.locations.getId then
                            myLocStr = self.locations:getId()
                        end
                        return itemLocStr == myLocStr
                    end
                end
            end
        end
    end
    return false
end

function PaperDollSlot:onMouseDown(x, y)
    self.clicked = true
    self.clickX = x
    self.clickY = y
end

function PaperDollSlot:onMouseMove(dx, dy)
    if self.clicked and not ISMouseDrag.dragging and not GridInventory_GlobalDrag then
        local x = self:getMouseX()
        local y = self:getMouseY()
        
        -- Debounce: só inicia o drag se mover mais que 4 pixels
        if math.abs(x - self.clickX) > 4 or math.abs(y - self.clickY) > 4 then
            local item = self:getEquippedItem()
            if item then
                ISMouseDrag.dragging = { item }
                ISMouseDrag.draggingFocus = self

                -- Footprint REAL do item (mesmo usado pelos grids), para o
                -- fantasma de arraste ter o tamanho certo e o item ser colocado
                -- com o footprint correto ao soltar num grid.
                local ItemFootprint = require("Algorithm/ItemFootprint")
                local fw, fh = ItemFootprint.getSize(item)

                GridInventory_GlobalDrag = {
                    itemsData = {
                        {
                            id = "paperdoll_" .. tostring(item:getID()),
                            originalW = fw,
                            originalH = fh,
                            grabOffsetX = 0,
                            grabOffsetY = 0,
                            rotated = false,
                            itemObj = item
                        }
                    },
                    itemsMap = { ["paperdoll_" .. tostring(item:getID())] = true },
                    anchorId = "paperdoll_" .. tostring(item:getID()),
                    sourceGrid = self
                }
            end
        end
    end
end

function PaperDollSlot:onMouseUpOutside(x, y)
    self.clicked = false
end

function PaperDollSlot:onMouseUp(x, y)
    local wasClicked = self.clicked
    self.clicked = false
    
    if ISMouseDrag.draggingFocus == self then
        -- Cancelando o arrasto
        if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid and GridInventory_GlobalDrag.sourceGrid.selectedItems then
            GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
        end
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
    elseif wasClicked and not GridInventory_GlobalDrag then
        -- Apenas um clique normal! (Cycle)
        local items = self:getEquippedItems()
        if #items > 1 then
            self.activeIndex = (self.activeIndex or 1) + 1
            if self.activeIndex > #items then self.activeIndex = 1 end
        elseif #items == 0 and self.hotbarRef and self.hotbarSlotIndex then
            self.hotbarRef:doMenu(self.hotbarSlotIndex)
        end
        if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid and GridInventory_GlobalDrag.sourceGrid.selectedItems then
            GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
        end
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
        return
    end

    local itemsToEquip = {}
    
    if ISMouseDrag.dragging and #ISMouseDrag.dragging > 0 then
        for _, itemObj in ipairs(ISMouseDrag.dragging) do
            if type(itemObj) == "table" and itemObj.items then
                table.insert(itemsToEquip, itemObj.items[1])
            else
                table.insert(itemsToEquip, itemObj)
            end
        end
    elseif GridInventory_GlobalDrag then
        for _, dData in ipairs(GridInventory_GlobalDrag.itemsData) do
            table.insert(itemsToEquip, dData.itemObj)
        end
    end
    
    if #itemsToEquip > 0 then
        local player = getSpecificPlayer(self.playerNum)
        local itemObj = itemsToEquip[1]
        
        if itemObj then
            if self.hotbarRef and self.hotbarSlotIndex then
                local slot = self.hotbarRef.availableSlot[self.hotbarSlotIndex]
                if slot and self.hotbarRef:canBeAttached(slot, itemObj) then
                    self.hotbarRef:attachItem(itemObj, slot.def.attachments[itemObj:getAttachmentType()], self.hotbarSlotIndex, slot.def, true)
                end
            elseif type(self.locations) == "table" and self.locations[1] == "PRIMARY" then
                ISInventoryPaneContextMenu.equipWeapon(itemObj, true, false, self.playerNum)
            elseif type(self.locations) == "table" and self.locations[1] == "SECONDARY" then
                ISInventoryPaneContextMenu.equipWeapon(itemObj, false, false, self.playerNum)
            elseif type(self.locations) == "table" and self.locations[1] == "TWOHANDED" then
                ISInventoryPaneContextMenu.equipWeapon(itemObj, true, true, self.playerNum)
            else
                if itemObj:IsClothing() or itemObj:IsInventoryContainer() then
                    ISInventoryPaneContextMenu.wearItem(itemObj, self.playerNum)
                end
            end
        end
    end
    
    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid and GridInventory_GlobalDrag.sourceGrid.selectedItems then
        GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
    end
    GridInventory_GlobalDrag = nil
    ISMouseDrag.dragging = nil
    ISMouseDrag.draggingFocus = nil
end

--- Equipa um item neste slot (usado pelo joypad: drag de item + A no slot do
--- PaperDoll). Mesma lógica do drop de mouse (onMouseUp), sem depender de
--- ISMouseDrag. Retorna true se aceitou o item.
function PaperDollSlot:joypadEquip(itemObj)
    if not itemObj then return false end
    local player = getSpecificPlayer(self.playerNum)
    if not player then return false end

    if self.hotbarRef and self.hotbarSlotIndex then
        local slot = self.hotbarRef.availableSlot[self.hotbarSlotIndex]
        if slot and self.hotbarRef:canBeAttached(slot, itemObj) then
            self.hotbarRef:attachItem(itemObj, slot.def.attachments[itemObj:getAttachmentType()], self.hotbarSlotIndex, slot.def, true)
            return true
        end
        return false
    end

    if type(self.locations) == "table" then
        if self.locations[1] == "PRIMARY" then
            ISInventoryPaneContextMenu.equipWeapon(itemObj, true, false, self.playerNum)
            return true
        elseif self.locations[1] == "SECONDARY" then
            ISInventoryPaneContextMenu.equipWeapon(itemObj, false, false, self.playerNum)
            return true
        elseif self.locations[1] == "TWOHANDED" then
            ISInventoryPaneContextMenu.equipWeapon(itemObj, true, true, self.playerNum)
            return true
        elseif self.locations[1] == "OVERFLOW" then
            return false
        end
    end

    if itemObj:IsClothing() or itemObj:IsInventoryContainer() then
        ISInventoryPaneContextMenu.wearItem(itemObj, self.playerNum)
        return true
    end
    return false
end

function PaperDollSlot:onRightMouseUp(x, y)
    local item = self:getEquippedItem()
    if item then
        ISInventoryPaneContextMenu.createMenu(self.playerNum, true, {item}, self:getAbsoluteX() + x, self:getAbsoluteY() + y)
    elseif self.hotbarRef and self.hotbarSlotIndex then
        self.hotbarRef:doMenu(self.hotbarSlotIndex)
    end
end

function PaperDollSlot:getEquippedItems()
    local player = getSpecificPlayer(self.playerNum)
    local results = {}
    if not player then return results end
    
    if self.hotbarRef and self.hotbarSlotIndex then
        local item = self.hotbarRef.attachedItems[self.hotbarSlotIndex]
        if item then table.insert(results, item) end
        return results
    end
    
    if type(self.locations) == "table" then
        if self.locations[1] == "PRIMARY" then
            local it = player:getPrimaryHandItem()
            if it then table.insert(results, it) end
            return results
        elseif self.locations[1] == "SECONDARY" then
            local it = player:getSecondaryHandItem()
            if it then table.insert(results, it) end
            return results
        elseif self.locations[1] == "TWOHANDED" then
            -- Apenas um drop zone visual, não segura itens fisicamente
            return results
        elseif self.locations[1] == "OVERFLOW" then
            return self.itemsList or results
        end
        
        local cache = getWornLocationCache(self.playerNum, player)
        for _, pattern in ipairs(self.locations) do
            local list = cache.byLocation[string.lower(pattern)]
            if list then
                for _, it in ipairs(list) do
                    table.insert(results, it)
                end
            end
        end
    else
        local loc = nil
        if type(self.locations) == "userdata" then
            loc = self.locations
        elseif type(self.locations) == "string" and ResourceLocation and ItemBodyLocation.get then
            loc = ItemBodyLocation.get(ResourceLocation.of(self.locations))
        else
            loc = self.locations
        end
        if loc then
            local it = player:getWornItem(loc)
            if it then table.insert(results, it) end
        end
    end
    return results
end

function PaperDollSlot:getEquippedItem()
    local items = self:getEquippedItems()
    if #items == 0 then return nil end
    
    if not self.activeIndex or self.activeIndex > #items or self.lastItemsCount ~= #items then
        self.activeIndex = #items
        self.lastItemsCount = #items
    end
    
    return items[self.activeIndex]
end

function PaperDollSlot:new(x, y, width, height, playerNum, locations, slotName)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.playerNum = playerNum
    o.locations = locations
    o.slotName = slotName
    -- Escala do fantasma de arraste: mesmo cellSize do grid, para o item
    -- solto do PaperDoll ter o mesmo tamanho visual que teria no inventário.
    o.cellSize = 40
    o.backgroundColor = {r=0.1, g=0.1, b=0.1, a=0.8}
    o.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    return o
end

function PaperDollSlot:updateTooltip()
    local item = self:getEquippedItem()

    -- Joypad (modo PaperDoll): tooltip segue o slot SELECIONADO (não o mouse).
    local GridJoypad = require("System/GridJoypad")
    local joypadSelected = GridJoypad.isPaperdollActive(self.playerNum)
        and GridJoypad.pdSelectedSlot(self.playerNum) == self

    -- Não mostrar tooltip se estiver arrastando algum item
    if joypadSelected and item and not GridJoypad.isDragging(self.playerNum) then
        if not self.toolRender then
            self.toolRender = ISToolTipInv:new(item)
            self.toolRender:initialise()
            self.toolRender:addToUIManager()
            self.toolRender:setOwner(self)
            self.toolRender:setCharacter(getSpecificPlayer(self.playerNum))
        end
        self.toolRender:setItem(item)
        self.toolRender:setVisible(true)
        self.toolRender:bringToTop()
        self.toolRender.followMouse = false

        -- Posição junto ao slot selecionado (à direita dele), sem sair da tela.
        local tx = self:getAbsoluteX() + self:getWidth() + 15
        local ty = self:getAbsoluteY() - 15
        if self.toolRender.width and (tx + self.toolRender.width > getCore():getScreenWidth()) then
            tx = self:getAbsoluteX() - self.toolRender.width - 15
        end
        if self.toolRender.height and (ty + self.toolRender.height > getCore():getScreenHeight()) then
            ty = getCore():getScreenHeight() - self.toolRender.height - 15
        end
        self.toolRender:setX(tx)
        self.toolRender:setY(ty)
    elseif self:isMouseOver() and item and not ISMouseDrag.dragging and not GridInventory_GlobalDrag
        and not GridJoypad.isPaperdollActive(self.playerNum) then
        if not self.toolRender then
            self.toolRender = ISToolTipInv:new(item)
            self.toolRender:initialise()
            self.toolRender:addToUIManager()
            self.toolRender:setOwner(self)
            self.toolRender:setCharacter(getSpecificPlayer(self.playerNum))
        end
        self.toolRender:setItem(item)
        self.toolRender:setVisible(true)
        self.toolRender:bringToTop()

        local mx = getMouseX()
        local my = getMouseY()

        local tx = mx + 15
        local ty = my + 15

        if self.toolRender.width and (tx + self.toolRender.width > getCore():getScreenWidth()) then
            tx = mx - self.toolRender.width - 15
        end
        if self.toolRender.height and (ty + self.toolRender.height > getCore():getScreenHeight()) then
            ty = my - self.toolRender.height - 15
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

function PaperDollSlot:removeFromUIManager()
    if self.toolRender then
        self.toolRender:removeFromUIManager()
        self.toolRender:setVisible(false)
        self.toolRender = nil
    end
    ISPanel.removeFromUIManager(self)
end

function PaperDollSlot:update()
    ISPanel.update(self)
    
    self:updateTooltip()
    
    if type(self.locations) == "table" and self.locations[1] == "TWOHANDED" then
        local show = false
        local draggedItem = nil
        
        if ISMouseDrag.dragging and #ISMouseDrag.dragging > 0 then
            draggedItem = ISMouseDrag.dragging[1]
            if type(draggedItem) == "table" and draggedItem.items then
                draggedItem = draggedItem.items[1]
            end
        elseif GridInventory_GlobalDrag and GridInventory_GlobalDrag.itemsData and #GridInventory_GlobalDrag.itemsData > 0 then
            draggedItem = GridInventory_GlobalDrag.itemsData[1].itemObj
        end
        
        if draggedItem and draggedItem.isTwoHandWeapon and draggedItem:isTwoHandWeapon() then
            show = true
        end
        
        self:setVisible(show)
        if not show then return end
    end
    
    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid == self and not isMouseButtonDown(0) then
        local mx = getMouseX()
        local my = getMouseY()
        local uis = UIManager.getUI()
        local mouseOverUI = false
        
        for i=0,uis:size()-1 do
            local ui = uis:get(i)
            if ui:isPointOver(mx, my) then
                mouseOverUI = true
                break
            end
        end

        if not mouseOverUI then
            for _, draggedItem in ipairs(GridInventory_GlobalDrag.itemsData) do
                if draggedItem and draggedItem.itemObj then
                    local player = getSpecificPlayer(self.playerNum)
                    if player then
                        ISTimedActionQueue.add(ISUnequipAction:new(player, draggedItem.itemObj, 50))
                    end
                end
            end
        end

        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
    end
end

return PaperDollSlot
