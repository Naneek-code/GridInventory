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
local GridAdmin = require("System/GridAdmin")

--- Gate do DevTool (fail-closed no CLIENTE).
--- O servidor já rejeita REQ_OVERRIDES de não-admin, mas sem esse gate o
--- override seria aplicado LOCALMENTE (applyOverrides + clearCaches) antes do
--- servidor rejeitar — o não-admin veria o item ajustado na própria grid mesmo
--- sem broadcast. Então o menu nem aparece e o save não aplica pra não-admin.
--- Regras:
---   * SP (host): -debug OU sandbox option ligada.
---   * MP: SÓ admin E sandbox option ligada — admin role sem o DevTools ligado
---     no Sandbox Options NÃO vê o menu (a option é o gate global do recurso).
local function canUseDevTools(player)
    local GridSandboxOptions = require("GridSandboxOptions")
    local enabled = GridSandboxOptions.isDevToolsEnabled()
    if isClient() then
        if not enabled then return false end
        -- O hook OnFillInventoryObjectContextMenu passa o NÚMERO do jogador
        -- (não o IsoPlayer!). Resolve o IsoPlayer local antes de checar admin.
        local playerObj = player
        if type(player) == "number" then
            playerObj = getSpecificPlayer(player)
        end
        if not playerObj then
            playerObj = getPlayer()
        end
        return GridAdmin.isAdmin(playerObj)
    end
    return isDebugEnabled() or enabled
end

-----------------------------------------------------------------------------------------
-- UI Panel
-----------------------------------------------------------------------------------------

GridDevToolUI = ISPanel:derive("GridDevToolUI")

function GridDevToolUI:new(x, y, target)
    local o = ISPanel:new(x, y, 300, 200)
    setmetatable(o, self)
    self.__index = self
    o.target = target

    -- O alvo pode ser um ITEM (InventoryItem) ou um CONTAINER (ItemContainer —
    -- inventário do jogador, caixa de mundo, etc). Resolve o item de referência
    -- (pro footprint) e a chave de override do grid.
    local GridContainer = require("DataModel/GridContainer")
    local isContainerTarget = not (instanceof and instanceof(target, "InventoryItem"))
    if isContainerTarget then
        o.inventoryContainer = target
        o.item = (target.getContainingItem and target:getContainingItem()) or nil
    else
        o.item = target
        o.inventoryContainer = o.item:IsInventoryContainer() and o.item:getInventory() or nil
    end

    o.isContainer = (o.inventoryContainer ~= nil)
    -- "item real" (tem InventoryItem de referência): mostra W/H/Stackable/MaxStack.
    -- Worldobj/player/floor (container sem item) só mostram o grid.
    o.isItem = (o.item ~= nil)
    o.fullType = GridContainer.getOverrideKey(o.inventoryContainer or (o.item and o.item:getContainer())) or "unknown"
    -- Guarda também o fullType puro (item) pra compatibilidade/fallback.
    o.itemFullType = o.item and o.item.getFullType and o.item:getFullType() or nil

    o.backgroundColor = {r=0, g=0, b=0, a=0.9}
    o.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    
    o.tempData = {}
    
    -- Busca valores atuais (chave do grid primeiro, fallback pro fullType puro)
    local override = GridDevTool.Overrides[o.fullType]
    if not override and o.itemFullType then
        override = GridDevTool.Overrides[o.itemFullType]
    end
    
    local ItemFootprint = require("Algorithm/ItemFootprint")
    local w, h = 1, 1
    if o.item then
        w, h = ItemFootprint.getSize(o.item)
    else
        w, h = 1, 1
    end
    o.tempData.w = (override and override.w) or w
    o.tempData.h = (override and override.h) or h    
    o.tempData.stackable = (override and override.stackable) -- nil=Auto, true/false
    o.tempData.maxStackAuto = not (override and override.maxStack)
    local autoMax = o.item and GridContainer.getMaxStackUnits(o.item) or nil
    o.tempData.maxStack = (override and override.maxStack) or autoMax or 100
    if o.isContainer then
        local cw, ch = GridContainer.getGridSize(o.inventoryContainer)
        o.tempData.cols = (override and override.cols) or cw
        o.tempData.rows = (override and override.rows) or ch
    end

    -- ALTURA estimada pro clamp (o initialise recalcula com o layout real).
    -- Base: title(20) + 40 por linha de campo + save.
    local estRows = 0
    if o.isItem then estRows = estRows + 4 end      -- W, H, Stackable, MaxStack
    if o.isContainer then estRows = estRows + 2 end -- Cols, Rows
    o.height = 40 + (estRows * 40) + 50

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
    
    -- Layout INTELIGENTE: worldobj/player/floor (container SEM item) não usam
    -- footprint/stack — só o grid. Bag (item+container) e item mostram tudo.
    -- Armazena a posição Y de cada campo pro prerender desenhar os valores.
    self.labels = {}
    
    if self.isItem then
        -- Item Width
        self:addChild(ISLabel:new(labelX, cy, 20, "Item Width (W):", 1, 1, 1, 1, UIFont.Small, true))
        self.btnWMinus = ISButton:new(160, cy, btnW, btnH, "-", self, function(self) self.tempData.w = math.max(1, self.tempData.w - 1) end)
        self.btnWMinus:initialise()
        self:addChild(self.btnWMinus)
        self.btnWPlus = ISButton:new(220, cy, btnW, btnH, "+", self, function(self) self.tempData.w = self.tempData.w + 1 end)
        self.btnWPlus:initialise()
        self:addChild(self.btnWPlus)
        self.labels.w = cy + 2
        cy = cy + 40
        
        -- Item Height
        self:addChild(ISLabel:new(labelX, cy, 20, "Item Height (H):", 1, 1, 1, 1, UIFont.Small, true))
        self.btnHMinus = ISButton:new(160, cy, btnW, btnH, "-", self, function(self) self.tempData.h = math.max(1, self.tempData.h - 1) end)
        self.btnHMinus:initialise()
        self:addChild(self.btnHMinus)
        self.btnHPlus = ISButton:new(220, cy, btnW, btnH, "+", self, function(self) self.tempData.h = self.tempData.h + 1 end)
        self.btnHPlus:initialise()
        self:addChild(self.btnHPlus)
        self.labels.h = cy + 2
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
        self.labels.stack = cy + 2
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
        self.labels.maxStack = cy + 2
        cy = cy + 40
    end

    if self.isContainer then
        self:addChild(ISLabel:new(labelX, cy, 20, "Grid Cols:", 1, 1, 1, 1, UIFont.Small, true))
        self.btnCMinus = ISButton:new(160, cy, btnW, btnH, "-", self, function(self) self.tempData.cols = math.max(1, self.tempData.cols - 1) end)
        self.btnCMinus:initialise()
        self:addChild(self.btnCMinus)
        self.btnCPlus = ISButton:new(220, cy, btnW, btnH, "+", self, function(self) self.tempData.cols = self.tempData.cols + 1 end)
        self.btnCPlus:initialise()
        self:addChild(self.btnCPlus)
        self.labels.cols = cy + 2
        cy = cy + 40
        
        self:addChild(ISLabel:new(labelX, cy, 20, "Grid Rows:", 1, 1, 1, 1, UIFont.Small, true))
        self.btnRMinus = ISButton:new(160, cy, btnW, btnH, "-", self, function(self) self.tempData.rows = math.max(1, self.tempData.rows - 1) end)
        self.btnRMinus:initialise()
        self:addChild(self.btnRMinus)
        self.btnRPlus = ISButton:new(220, cy, btnW, btnH, "+", self, function(self) self.tempData.rows = self.tempData.rows + 1 end)
        self.btnRPlus:initialise()
        self:addChild(self.btnRPlus)
        self.labels.rows = cy + 2
        cy = cy + 40
        
        -- Feedback do Max Container Grid Size (sandbox option) — só pra
        -- containers SEM item (worldobj/player/floor), onde o teto se aplica.
        if not self.isItem then
            self.maxGridNote = cy
            cy = cy + 18
        end
    end
    
    -- ALTURA final conforme os campos exibidos
    self.height = cy + 40
    self:setHeight(self.height)
    
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
    -- Fail-closed local: mesmo que alguém abra a UI por outro caminho, não
    -- aplica override na própria grid se não puder usar o DevTool.
    if not canUseDevTools(self.player) then
        self:close()
        return
    end

    -- w/h (footprint) só fazem sentido quando o alvo TEM um item real. Container
    -- de mundo / inventário do jogador: só cols/rows (grid) + stackable/maxStack.
    local hasItem = (self.item ~= nil)
    -- CHAVES DE OVERRIDE: footprint do item usa o fullType PURO (ItemFootprint
    -- procura por "Base.Knife"), enquanto o grid do container usa a chave de
    -- grid (getOverrideKey: "item:Base.Bag", "worldobj:crate", "player").
    -- Aplicamos em CADA chave separadamente — antes isso gravava tudo numa
    -- chave só (o container), então W/H de itens e cols/rows de bags iam pro
    -- lugar errado e o servidor "ignorava" (a chave não batia com o lookup).
    local gridKey = self.fullType
    local footprintKey = self.itemFullType or (self.item and self.item.getFullType and self.item:getFullType()) or nil

    -- cols/rows (grid do container) → chave de grid.
    if self.isContainer and gridKey and (self.tempData.cols or self.tempData.rows) then
        GridDevTool.applyOverrides(gridKey,
            nil, nil,
            self.tempData.cols, self.tempData.rows,
            nil, nil)
    end

    -- W/H/stackable/maxStack (footprint do item) → fullType puro. Só quando há
    -- um item real de referência (bag/item). Para o inventário do jogador e
    -- containers de mundo sem item, não há footprint pra gravar.
    if hasItem and footprintKey then
        GridDevTool.applyOverrides(footprintKey,
            self.tempData.w, self.tempData.h,
            nil, nil,
            self.tempData.stackable,
            self.tempData.maxStackAuto and nil or self.tempData.maxStack)
    end
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

--- Nome amigável do alvo pro título do DevTool (chave técnica → legível).
function GridDevToolUI.friendlyName(self)
    local k = self.fullType or "unknown"
    if k == "player" then return "Player Inventory" end
    if k == "floor" then return "Floor" end
    if k:sub(1, 5) == "item:" then return k:sub(6) end
    if k:sub(1, 9) == "worldobj:" then return k:sub(10) end
    if k:sub(1, 6) == "ctype:" then return k:sub(7) end
    return k
end

function GridDevToolUI:prerender()
    ISPanel.prerender(self)
    self:drawTextCentre("Grid DevTool: " .. GridDevToolUI.friendlyName(self), self.width / 2, 10, 1, 1, 1, 1, UIFont.Small)
    
    -- Valores desenhados ALINHADOS com as linhas reais do initialise (posições
    -- dinâmicas conforme o tipo de alvo — self.labels). x=205 é o centro entre
    -- os botões -/+ (160/220).
    if self.labels then
        if self.labels.w then
            self:drawTextCentre(tostring(self.tempData.w), 205, self.labels.w, 1, 1, 1, 1, UIFont.Small)
        end
        if self.labels.h then
            self:drawTextCentre(tostring(self.tempData.h), 205, self.labels.h, 1, 1, 1, 1, UIFont.Small)
        end
        if self.labels.cols then
            self:drawTextCentre(tostring(self.tempData.cols), 205, self.labels.cols, 1, 1, 1, 1, UIFont.Small)
        end
        if self.labels.rows then
            self:drawTextCentre(tostring(self.tempData.rows), 205, self.labels.rows, 1, 1, 1, 1, UIFont.Small)
        end
    end

    -- Feedback do Max Container Grid Size (sandbox option): mostra o teto geral
    -- vigente e avisa que o override FIRME pode ultrapassá-lo. Só pra
    -- containers sem item (worldobj/player/floor).
    if self.maxGridNote and not self.isItem then
        local GridSandboxOptions = require("GridSandboxOptions")
        local minW = GridSandboxOptions.getMinWorldGridWidth()
        local maxV = GridSandboxOptions.getMaxContainerGridSize()
        self:drawText("Grid (sandbox): W " .. tostring(minW) .. " / H " .. tostring(maxV),
            self.width / 2 - 120, self.maxGridNote, 0.8, 0.9, 0.7, 1, UIFont.Small)
    end
end

-----------------------------------------------------------------------------------------
-- Context Menu Hook
-----------------------------------------------------------------------------------------

local function OnFillInventoryObjectContextMenu(player, context, items)
    -- DevTool: só quem pode usar vê o menu. SP: -debug ou sandbox option.
    -- MP: fail-closed no CLIENTE — o menu nem aparece pra não-admin (o servidor
    -- também rejeita o envio, mas sem o gate local o override seria aplicado
    -- na própria grid antes da rejeição).
    if not canUseDevTools(player) then return end

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

    GridDevToolUI.addContextOption(context, player, testItem)
end

--- Adiciona a opção "[DevTool] Edit Grid Size" a um context menu. Aceita um
--- ITEM ou um CONTAINER como alvo (o container resolve o grid do mundo/jogador).
---@param context ISContextMenu
---@param player number|IsoPlayer
---@param target InventoryItem|ItemContainer
function GridDevToolUI.addContextOption(context, player, target)
    if not context or not target then return end
    if not canUseDevTools(player) then return end
    local devOption = context:addOption("[DevTool] Edit Grid Size", nil, function()
        local ui = GridDevToolUI:new(getMouseX() + 20, getMouseY(), target)
        ui.player = player
        ui:initialise()
        ui:addToUIManager()
    end)
    devOption.iconTexture = getTexture("media/ui/BugIcon.png")
end

Events.OnFillInventoryObjectContextMenu.Add(OnFillInventoryObjectContextMenu)

return GridDevToolUI
