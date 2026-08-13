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
    o.tempData.stackable = (override and override.stackable) -- nil=Auto, true/false
    o.tempData.maxStackAuto = not (override and override.maxStack)
    local GridContainer = require("DataModel/GridContainer")
    local autoMax = GridContainer.getMaxStackUnits(item)
    o.tempData.maxStack = (override and override.maxStack) or autoMax or 100
    o.isContainer = item:IsInventoryContainer()
    if o.isContainer then
        local cap = item:getInventory():getCapacity()
        local cw, ch = 6, math.max(2, math.ceil(cap / 3))
        o.tempData.cols = (override and override.cols) or cw
        o.tempData.rows = (override and override.rows) or ch
        o.height = 380
    else
        o.height = 280
    end

    -- ALTURA final (o ISPanel:new criou com 200; corrige agora que sabemos)
    o.height = o.isContainer and 380 or 280

    -- Clamp: a janela nunca nasce (nem fica) fora da tela.
    local sw = getCore() and getCore():getScreenWidth() or 1280
    local sh = getCore() and getCore():getScreenHeight() or 720
    if x + o.width > sw then x = math.max(0, sw - o.width) end
    if x < 0 then x = 0 end
    if y + o.height > sh then y = math.max(0, sh - o.height) end
    if y < 0 then y = 0 end
    o:setX(x)
    o:setY(y)
    
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
    
    -- Stackable toggle (Auto → ON → OFF)
    self:addChild(ISLabel:new(labelX, cy, 20, "Stackable:", 1, 1, 1, 1, UIFont.Small, true))
    self.btnStack = ISButton:new(160, cy, 90, btnH, "Auto", self, function(self)
        if self.tempData.stackable == nil then
            self.tempData.stackable = true
        elseif self.tempData.stackable == true then
            self.tempData.stackable = false
        else
            self.tempData.stackable = nil
        end
        self:updateStackButton()
    end)
    self.btnStack:initialise()
    self:addChild(self.btnStack)
    self:updateStackButton()

    cy = cy + 40

    -- MaxStack (Auto / número)
    self:addChild(ISLabel:new(labelX, cy, 20, "MaxStack:", 1, 1, 1, 1, UIFont.Small, true))
    self.btnMaxMinus = ISButton:new(130, cy, btnW, btnH, "-", self, function(self)
        if not self.tempData.maxStackAuto then
            self.tempData.maxStack = math.max(1, self.tempData.maxStack - 1)
            self:updateMaxButton()
        end
    end)
    self.btnMaxMinus:initialise()
    self:addChild(self.btnMaxMinus)
    self.btnMaxMode = ISButton:new(165, cy, 60, btnH, "Auto", self, function(self)
        self.tempData.maxStackAuto = not self.tempData.maxStackAuto
        self:updateMaxButton()
    end)
    self.btnMaxMode:initialise()
    self:addChild(self.btnMaxMode)
    self.btnMaxPlus = ISButton:new(230, cy, btnW, btnH, "+", self, function(self)
        if not self.tempData.maxStackAuto then
            self.tempData.maxStack = self.tempData.maxStack + 1
            self:updateMaxButton()
        end
    end)
    self.btnMaxPlus:initialise()
    self:addChild(self.btnMaxPlus)
    self:updateMaxButton()

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

function GridDevToolUI:updateStackButton()
    if not self.btnStack then return end
    if self.tempData.stackable == true then
        self.btnStack:setTitle("ON")
        self.btnStack.backgroundColor = { r = 0.15, g = 0.45, b = 0.15, a = 0.8 }
        self.btnStack.backgroundColorMouseOver = { r = 0.25, g = 0.6, b = 0.25, a = 0.9 }
    elseif self.tempData.stackable == false then
        self.btnStack:setTitle("OFF")
        self.btnStack.backgroundColor = { r = 0.45, g = 0.15, b = 0.15, a = 0.8 }
        self.btnStack.backgroundColorMouseOver = { r = 0.6, g = 0.25, b = 0.25, a = 0.9 }
    else
        self.btnStack:setTitle("Auto")
        self.btnStack.backgroundColor = { r = 0.3, g = 0.3, b = 0.3, a = 0.6 }
        self.btnStack.backgroundColorMouseOver = { r = 0.5, g = 0.5, b = 0.5, a = 0.8 }
    end
end

function GridDevToolUI:updateMaxButton()
    if not self.btnMaxMode then return end
    if self.tempData.maxStackAuto then
        self.btnMaxMode:setTitle("Auto")
    else
        self.btnMaxMode:setTitle(tostring(self.tempData.maxStack))
    end
end

function GridDevToolUI:onSave()
    GridDevTool.applyOverrides(self.fullType, self.tempData.w, self.tempData.h,
        self.isContainer and self.tempData.cols or nil,
        self.isContainer and self.tempData.rows or nil,
        self.tempData.stackable,
        self.tempData.maxStackAuto and nil or self.tempData.maxStack)

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

-- ─── Drag da janela ─────────────────────────────────────────────────────────
-- Arrasta pela BARRA DE TÍTULO (topo, altura ~25px). Usa setCapture pra
-- continuar seguindo o mouse mesmo fora do elemento. Clamp mantém a janela
-- sempre dentro da tela (nunca "some" por arrastar demais).
local DEVTOOL_TITLE_BAR = 25

function GridDevToolUI:onMouseDown(x, y)
    if y <= DEVTOOL_TITLE_BAR and x <= self:getWidth() - 24 then
        -- Clique na barra de título (fora do botão fechar X, canto direito)
        self.dragging = true
        self.dragStartX = x
        self.dragStartY = y
        self:setCapture(true)
        return true
    end
    return ISPanel.onMouseDown(self, x, y)
end

function GridDevToolUI:onMouseMove(dx, dy)
    if self.dragging then
        local mx = self:getMouseX()
        local my = self:getMouseY()
        local nx = self:getX() + (mx - self.dragStartX)
        local ny = self:getY() + (my - self.dragStartY)
        self:clampAndSet(nx, ny)
        return true
    end
    return ISPanel.onMouseMove(self, dx, dy)
end

function GridDevToolUI:onMouseMoveOutside(dx, dy)
    if self.dragging then
        local mx = getMouseX()
        local my = getMouseY()
        local nx = self:getX() + (mx - (self:getX() + self.dragStartX))
        local ny = self:getY() + (my - (self:getY() + self.dragStartY))
        self:clampAndSet(nx, ny)
        return true
    end
    return ISPanel.onMouseMoveOutside and ISPanel.onMouseMoveOutside(self, dx, dy)
end

function GridDevToolUI:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
    return ISPanel.onMouseUp(self, x, y)
end

--- Posiciona a janela garantindo que fique dentro da tela.
function GridDevToolUI:clampAndSet(nx, ny)
    local sw = getCore() and getCore():getScreenWidth() or 1280
    local sh = getCore() and getCore():getScreenHeight() or 720
    if nx + self:getWidth() > sw then nx = sw - self:getWidth() end
    if nx < 0 then nx = 0 end
    if ny + self:getHeight() > sh then ny = sh - self:getHeight() end
    if ny < 0 then ny = 0 end
    self:setX(nx)
    self:setY(ny)
end

function GridDevToolUI:prerender()
    ISPanel.prerender(self)
    self:drawTextCentre("Grid DevTool: " .. self.fullType, self.width / 2, 10, 1, 1, 1, 1, UIFont.Small)
    
    -- Valores desenhados ALINHADOS com as linhas reais do initialise (valores
    -- ABSOLUTOS, não incrementais — incrementar bugava a posição):
    --   W (40), H (80), Stackable (120), MaxStack (160), [container:]
    --   Cols (200), Rows (240). x=205 é o centro entre os botões -/+ (160/220).
    self:drawTextCentre(tostring(self.tempData.w), 205, 42, 1, 1, 1, 1, UIFont.Small)
    self:drawTextCentre(tostring(self.tempData.h), 205, 82, 1, 1, 1, 1, UIFont.Small)
    
    if self.isContainer then
        -- Pula Stackable (120) e MaxStack (160) → Cols em 200, Rows em 240
        self:drawTextCentre(tostring(self.tempData.cols), 205, 202, 1, 1, 1, 1, UIFont.Small)
        self:drawTextCentre(tostring(self.tempData.rows), 205, 242, 1, 1, 1, 1, UIFont.Small)
    end
end

-----------------------------------------------------------------------------------------
-- Context Menu Hook
-----------------------------------------------------------------------------------------

local function OnFillInventoryObjectContextMenu(player, context, items)
    -- DevTool: aparece com o jogo iniciado em -debug OU com a Sandbox Option
    -- "Ativar DevTools" ligada. No MP o SERVIDOR é fail-closed: rejeita aplicar
    -- overrides de quem não é admin (GridServerNetwork.isAdmin) — então o menu
    -- pode aparecer pra todos; o servidor decide na hora de salvar. No SP o
    -- jogador é o dono e sempre pode.
    local GridSandboxOptions = require("GridSandboxOptions")
    if not (isDebugEnabled() or GridSandboxOptions.isDevToolsEnabled()) then return end

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
