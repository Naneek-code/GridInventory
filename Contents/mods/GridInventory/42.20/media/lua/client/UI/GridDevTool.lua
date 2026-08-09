--- GridDevTool.lua (CLIENT)
--- Ferramenta de desenvolvedor para editar os tamanhos de itens e grids.
--- A camada de DADOS (tabela de overrides + arquivo) vive no módulo SHARED
--- DevTool/GridOverrides.lua — carregado também no SERVIDOR, que usa os mesmos
--- overrides na validação autoritativa. Aqui fica só a UI + o menu de contexto,
--- e ao salvar o cliente envia os overrides pro servidor (autoridade final).

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISInventoryPaneContextMenu"
require "DevTool/GridOverrides"

local GridClientNetwork = require("Network/GridClientNetwork")

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
    GridDevTool.applyOverrides(self.fullType, self.tempData.w, self.tempData.h,
        self.isContainer and self.tempData.cols or nil,
        self.isContainer and self.tempData.rows or nil)

    -- MP server-mandatory: envia pro servidor aplicar (autoridade) + broadcast.
    GridClientNetwork.sendOverrides(GridDevTool.Overrides)

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
    -- DevTool é ferramenta de DEV: só aparece com o jogo iniciado em -debug.
    if not isDebugEnabled() then return end

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
