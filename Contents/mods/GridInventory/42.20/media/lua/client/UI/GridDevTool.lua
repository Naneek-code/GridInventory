--- GridDevTool.lua
--- Ferramenta de desenvolvedor para editar os tamanhos de itens e grids em tempo real.
--- Salva tudo num arquivo na pasta do usuário para não perder e facilitar o balanceamento.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISInventoryPaneContextMenu"

GridDevTool = {}
GridDevTool.Overrides = {}

function GridDevTool.loadOverrides()
    local reader = getFileReader("GridOverrides.ini", true)
    if not reader then return end
    
    local currentItem = nil
    local line = reader:readLine()
    while line do
        line = line:match("^%s*(.-)%s*$") -- Lua trim
        if line:sub(1, 1) == "[" and line:sub(-1) == "]" then
            currentItem = string.sub(line, 2, -2)
            GridDevTool.Overrides[currentItem] = GridDevTool.Overrides[currentItem] or {}
        elseif currentItem and string.find(line, "=") then
            local parts = string.split(line, "=")
            if #parts == 2 then
                local k = parts[1]:match("^%s*(.-)%s*$")
                local v = tonumber(parts[2]:match("^%s*(.-)%s*$"))
                if v then
                    GridDevTool.Overrides[currentItem][k] = v
                end
            end
        end
        line = reader:readLine()
    end
    reader:close()
    print("[GridDevTool] Loaded overrides from GridOverrides.ini")
end

function GridDevTool.saveOverrides()
    local writer = getFileWriter("GridOverrides.ini", true, false)
    if not writer then return end
    
    for itemName, data in pairs(GridDevTool.Overrides) do
        writer:write("[" .. itemName .. "]\r\n")
        if data.w then writer:write("w=" .. tostring(data.w) .. "\r\n") end
        if data.h then writer:write("h=" .. tostring(data.h) .. "\r\n") end
        if data.cols then writer:write("cols=" .. tostring(data.cols) .. "\r\n") end
        if data.rows then writer:write("rows=" .. tostring(data.rows) .. "\r\n") end
        writer:write("\r\n")
    end
    writer:close()
    print("[GridDevTool] Saved overrides to GridOverrides.ini")
end

-- Inicializa carregando os dados salvos
Events.OnGameBoot.Add(GridDevTool.loadOverrides)

-----------------------------------------------------------------------------------------
-- UI Panel
-----------------------------------------------------------------------------------------

GridDevToolUI = ISPanel:derive("GridDevToolUI")

function GridDevToolUI:new(x, y, item)
    local o = ISPanel:new(x, y, 300, 200)
    setmetatable(o, self)
    self.__index = self
    o.item = item
    o.fullType = item:getFullType()
    
    o.backgroundColor = {r=0, g=0, b=0, a=0.9}
    o.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    
    o.tempData = {}
    
    -- Busca valores atuais
    local override = GridDevTool.Overrides[o.fullType]
    
    local ItemFootprint = require("Algorithm/ItemFootprint")
    local w, h = ItemFootprint.getSize(item)
    o.tempData.w = (override and override.w) or w
    o.tempData.h = (override and override.h) or h
    
    o.isContainer = item:IsInventoryContainer()
    if o.isContainer then
        local cap = item:getInventory():getCapacity()
        local cw, ch = 6, math.max(2, math.ceil(cap / 3))
        o.tempData.cols = (override and override.cols) or cw
        o.tempData.rows = (override and override.rows) or ch
        o.height = 300
    end
    
    return o
end

function GridDevToolUI:initialise()
    ISPanel.initialise(self)
    
    local btnW = 30
    local btnH = 20
    local labelX = 20
    local cy = 40
    
    -- Item Width
    self:addChild(ISLabel:new(labelX, cy, 20, "Item Width (W):", 1, 1, 1, 1, UIFont.Small, true))
    self.btnWMinus = ISButton:new(160, cy, btnW, btnH, "-", self, function(self) self.tempData.w = math.max(1, self.tempData.w - 1) end)
    self.btnWMinus:initialise()
    self:addChild(self.btnWMinus)
    self.btnWPlus = ISButton:new(220, cy, btnW, btnH, "+", self, function(self) self.tempData.w = self.tempData.w + 1 end)
    self.btnWPlus:initialise()
    self:addChild(self.btnWPlus)
    
    cy = cy + 40
    
    -- Item Height
    self:addChild(ISLabel:new(labelX, cy, 20, "Item Height (H):", 1, 1, 1, 1, UIFont.Small, true))
    self.btnHMinus = ISButton:new(160, cy, btnW, btnH, "-", self, function(self) self.tempData.h = math.max(1, self.tempData.h - 1) end)
    self.btnHMinus:initialise()
    self:addChild(self.btnHMinus)
    self.btnHPlus = ISButton:new(220, cy, btnW, btnH, "+", self, function(self) self.tempData.h = self.tempData.h + 1 end)
    self.btnHPlus:initialise()
    self:addChild(self.btnHPlus)
    
    cy = cy + 40
    
    if self.isContainer then
        self:addChild(ISLabel:new(labelX, cy, 20, "Bag Grid Cols:", 1, 1, 1, 1, UIFont.Small, true))
        self.btnCMinus = ISButton:new(160, cy, btnW, btnH, "-", self, function(self) self.tempData.cols = math.max(1, self.tempData.cols - 1) end)
        self.btnCMinus:initialise()
        self:addChild(self.btnCMinus)
        self.btnCPlus = ISButton:new(220, cy, btnW, btnH, "+", self, function(self) self.tempData.cols = self.tempData.cols + 1 end)
        self.btnCPlus:initialise()
        self:addChild(self.btnCPlus)
        
        cy = cy + 40
        
        self:addChild(ISLabel:new(labelX, cy, 20, "Bag Grid Rows:", 1, 1, 1, 1, UIFont.Small, true))
        self.btnRMinus = ISButton:new(160, cy, btnW, btnH, "-", self, function(self) self.tempData.rows = math.max(1, self.tempData.rows - 1) end)
        self.btnRMinus:initialise()
        self:addChild(self.btnRMinus)
        self.btnRPlus = ISButton:new(220, cy, btnW, btnH, "+", self, function(self) self.tempData.rows = self.tempData.rows + 1 end)
        self.btnRPlus:initialise()
        self:addChild(self.btnRPlus)
        
        cy = cy + 40
    end
    
    -- Save Button
    self.btnSave = ISButton:new(self.width/2 - 40, cy + 10, 80, 25, "SAVE", self, self.onSave)
    self.btnSave:initialise()
    self:addChild(self.btnSave)
    
    -- Close Button
    self.btnClose = ISButton:new(self.width - 25, 5, 20, 20, "X", self, self.close)
    self.btnClose:initialise()
    self:addChild(self.btnClose)
end

function GridDevToolUI:onSave()
    GridDevTool.Overrides[self.fullType] = GridDevTool.Overrides[self.fullType] or {}
    GridDevTool.Overrides[self.fullType].w = self.tempData.w
    GridDevTool.Overrides[self.fullType].h = self.tempData.h
    
    if self.isContainer then
        GridDevTool.Overrides[self.fullType].cols = self.tempData.cols
        GridDevTool.Overrides[self.fullType].rows = self.tempData.rows
    end
    
    GridDevTool.saveOverrides()
    
    -- Força um refresh global nas instâncias!
    local GridContainer = require("DataModel/GridContainer")
    if GridContainer then
        GridContainer.instances = {} -- Limpa cache para reconstruir bag grids
    end
    
    local playerInvUI = getPlayerInventory(0)
    local lootUI = getPlayerLoot(0)
    if playerInvUI and playerInvUI.inventoryPane then playerInvUI.inventoryPane:refreshContainer() end
    if lootUI and lootUI.inventoryPane then lootUI.inventoryPane:refreshContainer() end
    
    self:close()
end

function GridDevToolUI:close()
    self:removeFromUIManager()
end

function GridDevToolUI:prerender()
    ISPanel.prerender(self)
    self:drawTextCentre("Grid DevTool: " .. self.fullType, self.width / 2, 10, 1, 1, 1, 1, UIFont.Small)
    
    local cy = 40
    self:drawTextCentre(tostring(self.tempData.w), 205, cy + 2, 1, 1, 1, 1, UIFont.Small)
    cy = cy + 40
    self:drawTextCentre(tostring(self.tempData.h), 205, cy + 2, 1, 1, 1, 1, UIFont.Small)
    
    if self.isContainer then
        cy = cy + 40
        self:drawTextCentre(tostring(self.tempData.cols), 205, cy + 2, 1, 1, 1, 1, UIFont.Small)
        cy = cy + 40
        self:drawTextCentre(tostring(self.tempData.rows), 205, cy + 2, 1, 1, 1, 1, UIFont.Small)
    end
end

-----------------------------------------------------------------------------------------
-- Context Menu Hook
-----------------------------------------------------------------------------------------

local function OnFillInventoryObjectContextMenu(player, context, items)
    local testItem = items[1]
    if not testItem then return end
    
    -- O Zomboid passa uma tabela quando a lista é combinada
    if not instanceof(testItem, "InventoryItem") then
        if testItem.items and testItem.items[1] then
            testItem = testItem.items[1]
        else
            return
        end
    end

    local devOption = context:addOption("[DevTool] Edit Grid Size", nil, function()
        local ui = GridDevToolUI:new(getMouseX() + 20, getMouseY(), testItem)
        ui:initialise()
        ui:addToUIManager()
    end)
    devOption.iconTexture = getTexture("media/ui/BugIcon.png")
end

Events.OnFillInventoryObjectContextMenu.Add(OnFillInventoryObjectContextMenu)
