--- GridCore.lua
--- Core mathematical representation of a 2D grid inventory.
--- 100% decoupled from Project Zomboid logic and UI for max testability.

local GridCore = {}

---@class GridCoreInstance
local GridCoreInstance = {}
GridCoreInstance.__index = GridCoreInstance

--- Creates a new empty grid
---@param width number
---@param height number
---@return GridCoreInstance
function GridCore.new(width, height)
    local self = setmetatable({}, GridCoreInstance)
    self.width = width
    self.height = height
    
    -- Matrix for quick spatial lookups: cells[x][y] = itemId
    self.cells = {}
    for x = 1, width do
        self.cells[x] = {}
        for y = 1, height do
            self.cells[x][y] = nil
        end
    end
    
    -- Dictionary for fast item lookups: items[itemId] = { x, y, w, h, rotated }
    self.items = {}
    
    -- Dictionary for pending items (ghosts): ghostItems[itemId] = { x, y, w, h, rotated, itemObj, timeAdded }
    self.ghostItems = {}
    
    return self
end

--- Validates if a coordinate is within the grid boundaries
function GridCoreInstance:isWithinBounds(x, y, w, h)
    if x < 1 or y < 1 then return false end
    if (x + w - 1) > self.width then return false end
    if (y + h - 1) > self.height then return false end
    return true
end

--- Checks if a specific item can be placed at the given coordinates
---@param itemId string|number Unique identifier for the item
---@param x number X coordinate (1-indexed)
---@param y number Y coordinate (1-indexed)
---@param w number Width of the item
---@param h number Height of the item
---@param ignoreItemId string|number? Optional ID of an item to ignore during collision check (useful for moving items)
---@return boolean
function GridCoreInstance:canPlaceItem(itemId, x, y, w, h, ignoreItemId)
    x, y, w, h = tonumber(x), tonumber(y), tonumber(w), tonumber(h)
    
    if not self:isWithinBounds(x, y, w, h) then
        return false
    end

    for cx = x, x + w - 1 do
        for cy = y, y + h - 1 do
            local occupant = self.cells[cx][cy]
            if occupant ~= nil and occupant ~= ignoreItemId and occupant ~= itemId then
                return false
            end
        end
    end
    
    -- Verifica interseção com ghost items (transferências pendentes)
    if self.ghostItems then
        for gId, gData in pairs(self.ghostItems) do
            if gId ~= ignoreItemId and gId ~= itemId then
                local gx, gy, gw, gh = tonumber(gData.x), tonumber(gData.y), tonumber(gData.w), tonumber(gData.h)
                if x < gx + gw and x + w > gx and y < gy + gh and y + h > gy then
                    return false
                end
            end
        end
    end

    return true
end

--- Attempts to insert an item into the grid at a specific location
---@return boolean true if inserted successfully, false otherwise
function GridCoreInstance:insertItem(itemId, x, y, w, h, isRotated, itemObj)
    if not self:canPlaceItem(itemId, x, y, w, h) then
        return false
    end

    if self.items[itemId] then
        self:removeItem(itemId)
    end
    
    if self.ghostItems[itemId] then
        self.ghostItems[itemId] = nil
    end

    self.items[itemId] = {
        x = x,
        y = y,
        w = w,
        h = h,
        rotated = isRotated or false,
        itemObj = itemObj -- Referência nativa para UI
    }

    -- Mark cells as occupied
    for cx = x, x + w - 1 do
        for cy = y, y + h - 1 do
            self.cells[cx][cy] = itemId
        end
    end

    return true
end

--- Removes an item from the grid
---@return boolean true if removed, false if not found
function GridCoreInstance:removeItem(itemId)
    local itemData = self.items[itemId]
    if not itemData then
        return false
    end

    -- Free the cells
    for cx = itemData.x, itemData.x + itemData.w - 1 do
        for cy = itemData.y, itemData.y + itemData.h - 1 do
            if self.cells[cx][cy] == itemId then
                self.cells[cx][cy] = nil
            end
        end
    end

    -- Remove from registry
    self.items[itemId] = nil
    return true
end

--- Gets the data for an item in the grid
function GridCoreInstance:getItemData(itemId)
    return self.items[itemId]
end

function GridCoreInstance:addGhostItem(itemId, itemObj, x, y, w, h, rotated)
    self.ghostItems[itemId] = {
        itemObj = itemObj,
        x = tonumber(x),
        y = tonumber(y),
        w = tonumber(w),
        h = tonumber(h),
        rotated = rotated or false,
        timeAdded = getTimeInMillis()
    }
end

function GridCoreInstance:removeGhostItem(itemId)
    self.ghostItems[itemId] = nil
end

--- Finds the first available free spot for an item, prioritizing top-left.
---@return number, number (x, y) or nil, nil if no space
function GridCoreInstance:findFreeSpace(itemId, w, h)
    for y = 1, self.height do
        for x = 1, self.width do
            if self:canPlaceItem(itemId, x, y, w, h) then
                return x, y
            end
        end
    end
    return nil, nil
end

return GridCore
