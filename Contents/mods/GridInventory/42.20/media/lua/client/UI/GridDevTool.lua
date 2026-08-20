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
require "ISUI/ISTextEntryBox"
require "DevTool/GridOverrides"

local GridClientNetwork = require("Network/GridClientNetwork")
local GridAdmin = require("System/GridAdmin")
local GridIconRotation = require("Algorithm/GridIconRotation")
local ItemCategory = require("Algorithm/ItemCategory")
local GridSandboxOptions = require("GridSandboxOptions")

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

--- Registro das instâncias abertas (adicionadas no :new, removidas no :close).
--- O drag do anchor captura o MOUSE (setCapture), então o painel não recebe
--- eventos de teclado — as setinhas são pegas por um handler GLOBAL (ver no fim
--- do arquivo), que usa este registro pra achar a instância sendo arrastada.
GridDevToolUI.openInstances = {}

--- Largura da janela com preview do footprint (item). O preview fica no lado
--- direito da janela e mostra, AO VIVO, o footprint W×H com a cor da categoria
--- e a sprite com ângulo/escala/anchor atuais — mesmo matemática do render.
local DEVTOOL_PREVIEW_WIDTH = 540

--- Largura da janela quando o alvo é só um container (grid) — sem preview.
local DEVTOOL_BASE_WIDTH = 300

function GridDevToolUI:new(x, y, target)
    local o = ISPanel:new(x, y, DEVTOOL_BASE_WIDTH, 200)
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
    -- Com item o preview do footprint entra no lado direito → janela mais larga.
    if o.isItem then
        o.width = DEVTOOL_PREVIEW_WIDTH
        -- Coluna do preview (x fixo, y/h definidos no initialise conforme os
        -- campos). Os botões de pixel-perfect param antes dessa borda.
        o.previewX = 305
        o.previewY = 45
        o.previewW = o.width - 305 - 10
    end
    o.fullType = GridContainer.getOverrideKey(o.inventoryContainer or (o.item and o.item:getContainer())) or "unknown"
    -- Guarda também o fullType puro (item) pra compatibilidade/fallback.
    o.itemFullType = o.item and o.item.getFullType and o.item:getFullType() or nil
    -- Chave de variante de sprite (fullType|spriteName) pra angle/scale/anchor.
    local GridIconRotation = require("Algorithm/GridIconRotation")
    o.itemVariantKey = o.item and GridIconRotation.getVariantKey(o.item) or o.itemFullType

    -- Sprite variants (IconsForTexture) pra seletor no DevTool.
    -- Cada variante é um InventoryItem separado com sua textura propia.
    o.variants = nil
    o.variantItems = nil
    o.variantIndex = 1
    if o.item and o.isItem then
        local sman = getScriptManager()
        local sitem = sman and sman:getItem(o.itemFullType)
        if sitem then
            local ok3, icons = pcall(sitem.getIconsForTexture, sitem)
            if ok3 and icons and icons.size and icons:size() > 1 then
                o.variants = {}
                o.variantItems = {}
                local needed = icons:size()
                local attempts = 0
                local maxAttempts = needed * 6
                while #o.variants < needed and attempts < maxAttempts do
                    attempts = attempts + 1
                    local okI, vItem = pcall(instanceItem, o.itemFullType)
                    if okI and vItem and instanceof(vItem, "InventoryItem") then
                        local vk = GridIconRotation.getVariantKey(vItem)
                        local dup = false
                        for _, ev in ipairs(o.variants) do
                            if ev == vk then dup = true break end
                        end
                        if not dup then
                            o.variants[#o.variants + 1] = vk
                            o.variantItems[#o.variantItems + 1] = vItem
                        end
                    end
                end
                -- Ordena por nome da variante pra ficar previsível.
                for i = 1, #o.variants do
                    for j = i + 1, #o.variants do
                        if o.variants[j] < o.variants[i] then
                            o.variants[i], o.variants[j] = o.variants[j], o.variants[i]
                            o.variantItems[i], o.variantItems[j] = o.variantItems[j], o.variantItems[i]
                        end
                    end
                end
                -- Descobre qual variante o item original corresponde.
                local origVK = o.itemVariantKey or ""
                for i, vk in ipairs(o.variants) do
                    if vk == origVK then
                        o.variantIndex = i
                        break
                    end
                end
                -- Troca o item pra refletir a variante detectada.
                o.item = o.variantItems[o.variantIndex]
            end
        end
    end

    o.backgroundColor = {r=0, g=0, b=0, a=0.9}
    o.borderColor = {r=0.4, g=0.4, b=0.4, a=1}
    
    o.tempData = {}
    
    -- Busca valores atuais. w/h/stackable/maxStack são POR TIPO (fullType)
    -- e usam o override chain completo (variante → fullType → grid key).
    -- angle/scale/anchor são POR VARIANTE e NÃO caem no fullType override.
    local overrideAll = GridDevTool.Overrides[o.itemVariantKey]
    if not overrideAll and o.itemVariantKey ~= o.itemFullType then
        overrideAll = GridDevTool.Overrides[o.itemFullType]
    end
    if not overrideAll then
        overrideAll = GridDevTool.Overrides[o.fullType]
    end
    -- Override só da variante (sem fallback fullType) pra angle/scale/anchor.
    local overrideVariant = GridDevTool.Overrides[o.itemVariantKey]
    
    local ItemFootprint = require("Algorithm/ItemFootprint")
    local w, h = 1, 1
    if o.item then
        w, h = ItemFootprint.getSize(o.item)
    else
        w, h = 1, 1
    end
    o.tempData.w = (overrideAll and overrideAll.w) or w
    o.tempData.h = (overrideAll and overrideAll.h) or h    
    o.tempData.stackable = (overrideAll and overrideAll.stackable) -- nil=Auto, true/false
    o.tempData.maxStackAuto = not (overrideAll and overrideAll.maxStack)
    local autoMax = o.item and GridContainer.getMaxStackUnits(o.item) or nil
    o.tempData.maxStack = (overrideAll and overrideAll.maxStack) or autoMax or 100
    -- Ângulo do sprite (rotação fixa). POR VARIANTE: só override salvo pra
    -- essa variante, senão hardcoded table, senão 0. NÃO usa fullType override.
    o.tempData.angle = (overrideVariant and overrideVariant.angle)
        or GridIconRotation.Overrides[o.itemFullType] or 0
    if o.tempData.angle == 0 then o.tempData.angle = nil end
    -- Escala do sprite. Mesma lógica POR VARIANTE.
    o.tempData.scale = (overrideVariant and overrideVariant.scale)
        or GridIconRotation.Scales[o.itemFullType] or 1
    if o.tempData.scale == 1 then o.tempData.scale = nil end
    -- Lock pixel-perfect: desligado por padrão. ppCurrentN = N atual (texel->px)
    -- quando o lock tá ativo (preenchido pelo toggle/setPixelPerfect).
    o.ppLock = false
    o.ppCurrentN = nil
    -- Anchor do sprite (px): POR VARIANTE. Lê override salvo dessa variante,
    -- senão hardcoded table, senão {0,0}. Não usa fullType override.
    local ax, ay = 0, 0
    if overrideVariant then
        ax = overrideVariant.anchorX or 0
        ay = overrideVariant.anchorY or 0
    else
        local fixed = GridIconRotation.Anchors[o.itemFullType]
        ax = fixed and fixed.x or 0
        ay = fixed and fixed.y or 0
    end
    o.tempData.anchorX = ax
    o.tempData.anchorY = ay
    if o.tempData.anchorX == 0 then o.tempData.anchorX = nil end
    if o.tempData.anchorY == 0 then o.tempData.anchorY = nil end
    -- Estado do drag do anchor no preview (clique+arraste pra mover a sprite).
    -- nil = sem drag ativo.
    o.anchorDragging = nil
    if o.isContainer then
        local cw, ch = GridContainer.getGridSize(o.inventoryContainer)
        o.tempData.cols = (overrideAll and overrideAll.cols) or cw
        o.tempData.rows = (overrideAll and overrideAll.rows) or ch
    end

    -- ALTURA estimada pro clamp (o initialise recalcula com o layout real).
    -- Base: title(20) + 40 por linha de campo + save.
    local estRows = 0
    if o.isItem then estRows = estRows + 10 end     -- W, H, Stackable, MaxStack, Angle, Quick, Scale, Pixel, AnchorX, AnchorY
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

    -- Registra no pool global pro handler de teclado (setas do nudge de anchor).
    table.insert(GridDevToolUI.openInstances, o)

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
        -- Variant selector (só pra itens com >1 IconsForTexture).
        if self.variants then
            self:addChild(ISLabel:new(labelX, cy, 20, "Variant:", 1, 1, 1, 1, UIFont.Small, true))
            self.btnVarPrev = ISButton:new(130, cy, 25, btnH, "<", self, function(self) self:switchVariant(self.variantIndex - 1) end)
            self.btnVarPrev:initialise()
            self:addChild(self.btnVarPrev)
            self.btnVarNext = ISButton:new(225, cy, 25, btnH, ">", self, function(self) self:switchVariant(self.variantIndex + 1) end)
            self.btnVarNext:initialise()
            self:addChild(self.btnVarNext)
            self.labels.variant = cy + 2
            cy = cy + 30
        end

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
        
        -- MaxStack (Auto / número digitável)
        self:addChild(ISLabel:new(labelX, cy, 20, "MaxStack:", 1, 1, 1, 1, UIFont.Small, true))
        self.btnMaxAuto = ISButton:new(130, cy, 55, btnH, "Auto", self, function(self)
            self.tempData.maxStackAuto = not self.tempData.maxStackAuto
            self:updateMaxButton()
            self:syncMaxEntry()
        end)
        self.btnMaxAuto:initialise()
        self:addChild(self.btnMaxAuto)
        self.entryMaxStack = ISTextEntryBox:new(tostring(self.tempData.maxStack), 190, cy, 70, 22)
        self.entryMaxStack.font = UIFont.Small
        self.entryMaxStack:initialise()
        self.entryMaxStack:instantiate()
        self.entryMaxStack.target = self
        self.entryMaxStack.onTextChange = function(box)
            box.target:onMaxStackChanged()
        end
        -- Ao clicar, seleciona o conteúdo pra digitação SUBSTITUIR o valor
        -- (senão o "5" é anexado ao "1000" existente).
        self.entryMaxStack.onMouseDown = function(box)
            box:selectAll()
        end
        self:addChild(self.entryMaxStack)
        self:updateMaxButton()
        self.labels.maxStack = cy + 2
        cy = cy + 40

        -- Icon Angle (rotação fixa do sprite). Aplica AO VIVO no GridIconRotation
        -- (via GridDevTool.Overrides) pra ver o resultado na hora, sem salvar.
        self:addChild(ISLabel:new(labelX, cy, 20, "Icon Angle:", 1, 1, 1, 1, UIFont.Small, true))
        self.btnAngMinus = ISButton:new(160, cy, btnW, btnH, "-", self, function(self)
            self:setAngle((self.tempData.angle or 0) - 5)
        end)
        self.btnAngMinus:initialise()
        self:addChild(self.btnAngMinus)
        self.btnAngPlus = ISButton:new(220, cy, btnW, btnH, "+", self, function(self)
            self:setAngle((self.tempData.angle or 0) + 5)
        end)
        self.btnAngPlus:initialise()
        self:addChild(self.btnAngPlus)
        self.btnAngReset = ISButton:new(250, cy, 40, btnH, "0", self, function(self)
            self:setAngle(0)
        end)
        self.btnAngReset:initialise()
        self:addChild(self.btnAngReset)
        self.labels.angle = cy + 2
        cy = cy + 40

        -- Atalhos pros ângulos comuns (múltiplos de 45°): giro rápido em 1 clique.
        self:addChild(ISLabel:new(labelX, cy, 20, "Quick:", 1, 1, 1, 1, UIFont.Small, true))
        local quickBtnX = 72
        for i = 0, 7 do
            local a = i * 45
            local b = ISButton:new(quickBtnX, cy, 26, btnH, tostring(a), self, function(self)
                self:setAngle(a)
            end)
            b:initialise()
            self:addChild(b)
            quickBtnX = quickBtnX + 28
        end
        cy = cy + 40

        -- Icon Scale (multiplicador de tamanho sobre o min-fit). Preserva o
        -- ASPECTO da sprite — a borda é tocada crescendo o scale, não esticando.
        -- Aplica AO VIVO como o ângulo.
        self:addChild(ISLabel:new(labelX, cy, 20, "Icon Scale:", 1, 1, 1, 1, UIFont.Small, true))
        self.btnSclMinus = ISButton:new(160, cy, btnW, btnH, "-", self, function(self)
            self:incScale(-1)
        end)
        self.btnSclMinus:initialise()
        self:addChild(self.btnSclMinus)
        self.btnSclPlus = ISButton:new(220, cy, btnW, btnH, "+", self, function(self)
            self:incScale(1)
        end)
        self.btnSclPlus:initialise()
        self:addChild(self.btnSclPlus)
        self.btnSclReset = ISButton:new(250, cy, 40, btnH, "1x", self, function(self)
            self:setScale(1)
        end)
        self.btnSclReset:initialise()
        self:addChild(self.btnSclReset)
        self.labels.scale = cy + 2
        cy = cy + 40

        -- Pixel-perfect quick scale: atalhos de 1 clique pro multiplicador que
        -- deixa cada texel do PNG num número INTEIRO de pixels de tela (sem blur
        -- de interpolação). O footprint é convertido pra PIXELS (w/h × cellSize)
        -- e o cálculo usa a MESMA matemática do render (computeBaseScale), então
        -- o valor bate exatamente com o que o GridRender aplica.
        local tex = self:getItemTex()
        if tex then
            local cellSize = math.floor(40 * (GridInventory_uiScale or 100) / 100)
            local isRotated = false
            if self.item and self.item.getModData then
                local md = self.item:getModData()
                isRotated = md and md.gridRot or false
            end
            local scales = GridIconRotation.getPixelPerfectScales(
                tex:getWidth(), tex:getHeight(),
                (self.tempData.w or 1) * cellSize, (self.tempData.h or 1) * cellSize,
                self.tempData.angle or 0, isRotated)
            if #scales > 0 then
                self:addChild(ISLabel:new(labelX, cy, 20, "Pixel:", 1, 1, 1, 1, UIFont.Small, true))
                local ppBtnX = 72
                local previewEdge = (self.previewX or self.width) - 10
                for _, s in ipairs(scales) do
                    if ppBtnX + 34 <= previewEdge then
                        local iconScale = s.iconScale
                        -- Label "N:1" = cada texel vira NxN pixels na tela.
                        -- 1:1 = tamanho nativo (nítido), 2:1 = dobra o sprite
                        -- (maior e ainda nítido, pode estourar o footprint).
                        local b = ISButton:new(ppBtnX, cy, 30, btnH, tostring(s.N) .. ":1", self, function(self)
                            self:setPixelPerfect(s.N)
                        end)
                        b:initialise()
                        self:addChild(b)
                        ppBtnX = ppBtnX + 34
                    end
                end
                -- Toggle de LOCK pixel-perfect: quando ativo, o + e - do "Icon
                -- Scale" passam a andar de N em N inteiro (1:1 -> 2:1 -> 3:1),
                -- em vez de 0.05 — então nunca perde a proporção exata.
                local rightEdge = (self.previewX or self.width) - 10
                if ppBtnX + 34 <= rightEdge then
                    self.btnPpLock = ISButton:new(ppBtnX, cy, 30, btnH, "PP", self, function(self)
                        self:togglePixelLock()
                    end)
                    self.btnPpLock:initialise()
                    self:addChild(self.btnPpLock)
                end
                cy = cy + 40
            end
        end

        -- Icon Anchor X (deslocamento em px do sprite dentro do footprint,
        -- positivo = pra direita). Corrige itens cuja massa visual nasce fora
        -- do centro do PNG e fica torta após rotacionar. Aplica AO VIVO.
        self:addChild(ISLabel:new(labelX, cy, 20, "Anchor X:", 1, 1, 1, 1, UIFont.Small, true))
        self.btnAnchXMinus = ISButton:new(160, cy, btnW, btnH, "-", self, function(self)
            self:setAnchorX((self.tempData.anchorX or 0) - 1)
        end)
        self.btnAnchXMinus:initialise()
        self:addChild(self.btnAnchXMinus)
        self.btnAnchXPlus = ISButton:new(220, cy, btnW, btnH, "+", self, function(self)
            self:setAnchorX((self.tempData.anchorX or 0) + 1)
        end)
        self.btnAnchXPlus:initialise()
        self:addChild(self.btnAnchXPlus)
        self.btnAnchXReset = ISButton:new(250, cy, 40, btnH, "0", self, function(self)
            self:setAnchorX(0)
        end)
        self.btnAnchXReset:initialise()
        self:addChild(self.btnAnchXReset)
        self.labels.anchorX = cy + 2
        cy = cy + 40

        -- Icon Anchor Y (deslocamento em px, positivo = pra baixo).
        self:addChild(ISLabel:new(labelX, cy, 20, "Anchor Y:", 1, 1, 1, 1, UIFont.Small, true))
        self.btnAnchYMinus = ISButton:new(160, cy, btnW, btnH, "-", self, function(self)
            self:setAnchorY((self.tempData.anchorY or 0) - 1)
        end)
        self.btnAnchYMinus:initialise()
        self:addChild(self.btnAnchYMinus)
        self.btnAnchYPlus = ISButton:new(220, cy, btnW, btnH, "+", self, function(self)
            self:setAnchorY((self.tempData.anchorY or 0) + 1)
        end)
        self.btnAnchYPlus:initialise()
        self:addChild(self.btnAnchYPlus)
        self.btnAnchYReset = ISButton:new(250, cy, 40, btnH, "0", self, function(self)
            self:setAnchorY(0)
        end)
        self.btnAnchYReset:initialise()
        self:addChild(self.btnAnchYReset)
        self.labels.anchorY = cy + 2
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
    
    -- Área do PREVIEW do footprint (lado direito, item). Comprida verticalmente
    -- (acompanha a pilha de campos à esquerda). Só quando há item real.
    if self.isItem then
        self.previewH = cy - self.previewY - 8
    end

    -- ALTURA final conforme os campos exibidos. Re-clampa depois de saber a
    -- altura real (o new() clamou com a estimativa — janela larga com preview
    -- pode estourar a tela se o alvo tiver muitos campos).
    self.height = cy + 40
    self:setHeight(self.height)
    self:clampAndSet(self.x, self.y)
    
    -- Save Button
    self.btnSave = ISButton:new(self.width/2 - 40, cy + 10, 80, 25, "SAVE", self, self.onSave)
    self.btnSave:initialise()
    self:addChild(self.btnSave)
    
    -- Copy/Paste (colados ao lado do Save). Copy grava w/h/angle/scale/
    -- anchor/stackable/maxStack no clipboard; Paste aplica no DevTool ativo.
    self.btnCopy = ISButton:new(self.width/2 + 45, cy + 10, 50, 25, "Copy", self, self.onCopy)
    self.btnCopy:initialise()
    self.btnCopy.backgroundColor = { r = 0.15, g = 0.25, b = 0.15, a = 0.7 }
    self:addChild(self.btnCopy)
    self.btnPaste = ISButton:new(self.width/2 + 100, cy + 10, 50, 25, "Paste", self, self.onPaste)
    self.btnPaste:initialise()
    self.btnPaste.backgroundColor = { r = 0.15, g = 0.15, b = 0.25, a = 0.7 }
    self:addChild(self.btnPaste)
    
    -- Browse Button (browser de itens do jogo)
    self.btnBrowse = ISButton:new(10, cy + 10, 80, 25, "Browse", self, self.onBrowse)
    self.btnBrowse:initialise()
    self:addChild(self.btnBrowse)

    -- Derived Button (só item): abre o browser já filtrado pros itens que nascem
    -- desse item via evolved recipes (ex: cumbuca -> saladas). Editar só o item
    -- base não resolve os derivados — eles têm fullTypes próprios.
    if self.isItem then
        self.btnDerived = ISButton:new(95, cy + 10, 80, 25, "Derivados", self, self.onDerived)
        self.btnDerived:initialise()
        self:addChild(self.btnDerived)
    end
    
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
    if not self.btnMaxAuto then return end
    if self.tempData.maxStackAuto then
        self.btnMaxAuto:setTitle("Auto")
        self.btnMaxAuto.backgroundColor = { r = 0.15, g = 0.45, b = 0.15, a = 0.8 }
        self.btnMaxAuto.backgroundColorMouseOver = { r = 0.25, g = 0.6, b = 0.25, a = 0.9 }
        -- Modo Auto: esconde o input (não há número pra editar).
        if self.entryMaxStack then self.entryMaxStack:setVisible(false) end
    else
        self.btnMaxAuto:setTitle("N")
        self.btnMaxAuto.backgroundColor = { r = 0.45, g = 0.15, b = 0.15, a = 0.8 }
        self.btnMaxAuto.backgroundColorMouseOver = { r = 0.6, g = 0.25, b = 0.25, a = 0.9 }
        if self.entryMaxStack then self.entryMaxStack:setVisible(true) end
    end
end

--- Sincroniza o TEXTO do input com tempData.maxStack. Só roda de forma
--- PROGRAMÁTICA (init/toggle do Auto) — NUNCA durante a digitação, senão cada
--- tecla re-normalizava o texto e "travava" o campo em 1000 (o "5" anexado ao
--- "1000" virava "10005" → clamp 1000 → setText de volta).
function GridDevToolUI:syncMaxEntry()
    if not self.entryMaxStack then return end
    self._syncingMax = true
    self.entryMaxStack:setText(tostring(self.tempData.maxStack))
    self._syncingMax = false
end

--- Digitou no input de MaxStack: só parseia e guarda (sem reescrever o texto).
function GridDevToolUI:onMaxStackChanged()
    if not self.entryMaxStack or self._syncingMax then return end
    local n = tonumber(self.entryMaxStack:getText())
    if n and n >= 1 then
        self.tempData.maxStack = math.min(1000, math.floor(n))
        self.tempData.maxStackAuto = false
        self:updateMaxButton()
    end
end

--- Retorna a textura do item atual. Cada variante tem seu próprio item
--- com sua textura, então self.item:getTex() já retorna a certa.
function GridDevToolUI:getItemTex()
    local item = self.item
    if not item then return nil end
    return (item.getTex and item:getTex()) or (item.getTexture and item:getTexture()) or nil
end

--- Troca pra outra variante de sprite (IconsForTexture) e recarrega
--- angle/scale/anchor do override dessa variante. Wraps circular (1→N→1).
function GridDevToolUI:switchVariant(newIndex)
    if not self.variants then return end
    local count = #self.variants
    if newIndex < 1 then newIndex = count end
    if newIndex > count then newIndex = 1 end
    -- Reconstrói a variant key e troca o item inteiro.
    self.variantIndex = newIndex
    if self.variantItems and self.variantItems[newIndex] then
        self.item = self.variantItems[newIndex]
    end
    self.itemVariantKey = self.variants[newIndex]

    -- Recarrega angle/scale/anchor desta variante (sem fallback fullType).
    local GridIconRotation = require("Algorithm/GridIconRotation")
    local override = GridDevTool.Overrides[self.itemVariantKey]

    -- Angle.
    self.tempData.angle = (override and override.angle)
        or GridIconRotation.Overrides[self.itemFullType] or 0
    if self.tempData.angle == 0 then self.tempData.angle = nil end

    -- Scale.
    self.tempData.scale = (override and override.scale)
        or GridIconRotation.Scales[self.itemFullType] or 1
    if self.tempData.scale == 1 then self.tempData.scale = nil end

    -- Anchor.
    local ax, ay = 0, 0
    if override then
        ax = override.anchorX or 0
        ay = override.anchorY or 0
    else
        local fixed = GridIconRotation.Anchors[self.itemFullType]
        ax = fixed and fixed.x or 0
        ay = fixed and fixed.y or 0
    end
    self.tempData.anchorX = ax == 0 and nil or ax
    self.tempData.anchorY = ay == 0 and nil or ay

    -- Aplica AO VIVO nos overrides pra preview atualizar.
    self:setAngle(self.tempData.angle or 0)
    self:setScale(self.tempData.scale or 1)
    self:setAnchorX(self.tempData.anchorX or 0)
    self:setAnchorY(self.tempData.anchorY or 0)

    -- Reseta pixel-perfect (base muda com a variante).
    self.ppLock = false
    self.ppCurrentN = nil
end

--- Ajusta o ângulo do sprite AO VIVO (sem precisar salvar): aplica o override
--- direto no GridDevTool.Overrides, e o GridIconRotation lê ao vivo (sem cache)
--- a cada frame — o sprite gira na hora no grid. O tempData.angle registra o
--- valor pra quando o SAVE for clicado (persistir no GridOverrides.ini).
function GridDevToolUI:setAngle(angle)
    angle = angle % 360
    self.tempData.angle = angle

    -- Override ao vivo na chave de VARIANTE (fullType|spriteName) pra
    -- itens com múltiplas sprites (ex.: Hammer esquerda/direita).
    local footprintKey = self.itemVariantKey or self.itemFullType
    if footprintKey then
        local o = GridDevTool.Overrides[footprintKey] or {}
        if angle == 0 then
            o.angle = nil
        else
            o.angle = angle
        end
        GridDevTool.Overrides[footprintKey] = o
    end
end

--- Ajusta a ESCALA do sprite AO VIVO (sem precisar salvar), mesmo padrão do
--- setAngle: aplica no GridDevTool.Overrides e o GridIconRotation lê ao vivo a
--- cada frame. Multiplicador sobre o min-fit — preserva o aspecto da sprite,
--- então crescer até a borda não deforma. 1.0 = sem override (remove).
--- Range: 0.5..inf — o piso permite ENCOLHER sprites grandes (ex: itens 1x1
--- cujo PNG é maior que a célula) e crescer até a borda.
function GridDevToolUI:setScale(scale)
    if scale < 0.5 then scale = 0.5 end
    scale = math.floor(scale * 100 + 0.5) / 100
    self:applyScale(scale)
end

--- Versão PRECISA do setScale (sem arredondar pra 2 casas): usada pelos botões
--- "Pixel:" pra que o multiplicador n/baseScale vire EXATAMENTE o número
--- inteiro N de pixels por texel no render (arredondar pra 2 casas quebraria o
--- pixel-perfect). Mesmo clamp de 0.5 e mesmo padrão de override ao vivo.
function GridDevToolUI:setScalePrecise(scale)
    if scale < 0.5 then scale = 0.5 end
    self:applyScale(scale)
end

--- Recalcula o baseScale (px-por-texel do min-fit) pro item ATUAL, do jeito que
--- o render vai calcular — textura real, footprint em pixels (w/h × cellSize),
--- ângulo e rotação atuais. Usado pelos botões pixel-perfect e pelo lock pra
--- nunca divergir do que o GridRender aplica.
function GridDevToolUI:computePixelBase()
    local item = self.item
    if not item then return nil end
    local tex = self:getItemTex()
    if not tex then return nil end
    local cellSize = math.floor(40 * (GridInventory_uiScale or 100) / 100)
    local isRotated = false
    if item.getModData then
        local md = item:getModData()
        isRotated = md and md.gridRot or false
    end
    return GridIconRotation.computeBaseScale(
        tex:getWidth(), tex:getHeight(),
        (self.tempData.w or 1) * cellSize, (self.tempData.h or 1) * cellSize,
        self.tempData.angle or 0, isRotated)
end

--- Seta a escala pro pixel-perfect N (cada texel = NxN pixels na tela).
--- N = 1 é o nativo (1 texel = 1px). Memoriza o N atual pra navegação + / -.
function GridDevToolUI:setPixelPerfect(n)
    local base = self:computePixelBase()
    if not base then return end
    n = math.max(1, math.floor(n + 0.5))
    self.ppCurrentN = n
    self:setScalePrecise(n / base)
end

--- Botão + / - do "Icon Scale". Com o LOCK pixel-perfect ativo, navega de N em
--- N inteiro (1:1 -> 2:1 -> 3:1...), mantendo a proporção exata texel->px.
--- Sem lock, incrementa 0.05 como antes.
function GridDevToolUI:incScale(delta)
    if self.ppLock then
        local base = self:computePixelBase()
        if base then
            local n = self.ppCurrentN or math.max(1, math.floor((self.tempData.scale or 1) * base + 0.5))
            self:setPixelPerfect(n + delta)
            return
        end
    end
    self:setScale((self.tempData.scale or 1) + delta * 0.05)
end

--- Liga/desliga o lock pixel-perfect. Ao ligar, encaixa no N inteiro mais
--- próximo do scale atual (não fica um valor "quebrado" pedindo lock).
function GridDevToolUI:togglePixelLock()
    self.ppLock = not self.ppLock
    if self.ppLock then
        local base = self:computePixelBase()
        if base then
            local n = math.max(1, math.floor((self.tempData.scale or 1) * base + 0.5))
            self:setPixelPerfect(n)
        end
    end
    if self.btnPpLock then
        self.btnPpLock:setTitle(self.ppLock and "ON" or "PP")
        local c = self.btnPpLock.buttonColor or {}
        c.r, c.g, c.b = self.ppLock and 0.3 or 0.7, self.ppLock and 0.8 or 0.7, self.ppLock and 0.3 or 0.7
        self.btnPpLock.buttonColor = c
    end
end

--- Aplica o multiplicador de escala ao override ao vivo (tabela + persistência
--- na hora do SAVE). Compartilhado pelo setScale (2 casas) e setScalePrecise
--- (pixel-perfect, sem arredondar).
function GridDevToolUI:applyScale(scale)
    self.tempData.scale = scale

    local footprintKey = self.itemVariantKey or self.itemFullType
    if footprintKey then
        local o = GridDevTool.Overrides[footprintKey] or {}
        if scale == 1 then
            o.scale = nil
        else
            o.scale = scale
        end
        GridDevTool.Overrides[footprintKey] = o
    end
end

--- Ajusta o ANCHOR X do sprite AO VIVO (mesmo padrão do setAngle/setScale):
--- aplica no GridDevTool.Overrides e o GridIconRotation lê ao vivo a cada frame.
--- Deslocamento em pixels (positivo = pra direita). 0 = sem override (remove).
function GridDevToolUI:setAnchorX(px)
    px = math.floor(px + 0.5)
    self.tempData.anchorX = px

    local footprintKey = self.itemVariantKey or self.itemFullType
    if footprintKey then
        local o = GridDevTool.Overrides[footprintKey] or {}
        if px == 0 then
            o.anchorX = nil
        else
            o.anchorX = px
        end
        GridDevTool.Overrides[footprintKey] = o
    end
end

--- Ajusta o ANCHOR Y do sprite AO VIVO. Deslocamento em pixels (positivo = pra
--- baixo). 0 = sem override (remove).
function GridDevToolUI:setAnchorY(px)
    px = math.floor(px + 0.5)
    self.tempData.anchorY = px

    local footprintKey = self.itemVariantKey or self.itemFullType
    if footprintKey then
        local o = GridDevTool.Overrides[footprintKey] or {}
        if px == 0 then
            o.anchorY = nil
        else
            o.anchorY = px
        end
        GridDevTool.Overrides[footprintKey] = o
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

    -- W/H/stackable/maxStack/angle/scale/anchor (footprint do item) → fullType
    -- puro. Só quando há um item real de referência (bag/item). Para o
    -- inventário do jogador e containers de mundo sem item, não há footprint.
    if hasItem and footprintKey then
        -- w/h/stackable/maxStack → fullType puro (footprint é por tipo).
        GridDevTool.applyOverrides(footprintKey,
            self.tempData.w, self.tempData.h,
            nil, nil,
            self.tempData.stackable,
            (not self.tempData.maxStackAuto) and self.tempData.maxStack or nil,
            nil, nil, nil, nil)
        -- angle/scale/anchor → variante (fullType|spriteName) pra itens com
        -- múltiplas sprites (Hammer esq/dir, etc.).
        local variantKey = self.itemVariantKey or footprintKey
        if variantKey ~= footprintKey then
            GridDevTool.applyOverrides(variantKey,
                nil, nil, nil, nil, nil, nil,
                self.tempData.angle or 0,
                self.tempData.scale or 1,
                self.tempData.anchorX or 0,
                self.tempData.anchorY or 0)
        else
            -- Sem variante distinta: tudo na mesma chave.
            GridDevTool.applyOverrides(footprintKey,
                nil, nil, nil, nil, nil, nil,
                self.tempData.angle or 0,
                self.tempData.scale or 1,
                self.tempData.anchorX or 0,
                self.tempData.anchorY or 0)
        end
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
    for i = #GridDevToolUI.openInstances, 1, -1 do
        if GridDevToolUI.openInstances[i] == self then
            table.remove(GridDevToolUI.openInstances, i)
            break
        end
    end
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

    -- DRAG DO ANCHOR: clique dentro do footprint do preview arrasta a sprite
    -- (anchorX/anchorY em px). Guarda a posição inicial do mouse e o ângulo
    -- EFETIVO (deg + isRotated*-90°) pra converter o delta de tela pro espaço
    -- da sprite — a MESMA transformação que o GridRender usa ao aplicar o
    -- anchor (desfaz a rotação, então arrastar pra direita SEMPRE move a
    -- sprite pra direita na tela, em qualquer ângulo).
    if self.isItem and self.item then
        local cell, fx, fy, fw, fh = self:computePreviewGeometry()
        if x >= fx and x <= fx + fw and y >= fy and y <= fy + fh then
            local isRotated = false
            if self.item.getModData then
                local md = self.item:getModData()
                isRotated = md and md.gridRot or false
            end
            local deg = self.tempData.angle or 0
            local effDeg = deg + (isRotated and -90 or 0)
            self.anchorDragging = {
                startMouseX = x,
                startMouseY = y,
                startAnchorX = self.tempData.anchorX or 0,
                startAnchorY = self.tempData.anchorY or 0,
                effRad = effDeg * math.pi / 180,
            }
            self:setCapture(true)
            return true
        end
    end

    return ISPanel.onMouseDown(self, x, y)
end

--- Converte um delta de TELA (px, eixo X/Y da tela) pro espaço da sprite,
--- desfazendo a rotação efetiva (mesma transformação que o GridRender aplica:
---   R(-θ)(v) = (vx*cosθ + vy*sinθ, -vx*sinθ + vy*cosθ)
--- Retorna dax, day. Usada tanto pelo drag do mouse quanto pelo nudge das setas.
function GridDevToolUI:screenDeltaToAnchor(dvx, dvy)
    local drag = self.anchorDragging
    if not drag then return 0, 0 end
    local cosT = math.cos(drag.effRad)
    local sinT = math.sin(drag.effRad)
    local dax = dvx * cosT + dvy * sinT
    local day = -dvx * sinT + dvy * cosT
    return dax, day
end

--- Atualiza o drag do anchor a partir da posição local do mouse.
function GridDevToolUI:updateAnchorDrag(mx, my)
    local drag = self.anchorDragging
    if not drag then return end

    local dax, day = self:screenDeltaToAnchor(mx - drag.startMouseX, my - drag.startMouseY)
    self:setAnchorX(drag.startAnchorX + dax)
    self:setAnchorY(drag.startAnchorY + day)
end

--- Ajuste fino do anchor com as SETAS DO TECLADO enquanto o drag está ativo:
--- cada press move 1px no eixo X/Y da TELA (desfazendo a rotação, então a
--- sprite SEMPRE anda 1px na direção da seta, em qualquer ângulo).
function GridDevToolUI:nudgeAnchor(dvx, dvy)
    if not self.anchorDragging then return end
    local dax, day = self:screenDeltaToAnchor(dvx, dvy)
    self:setAnchorX((self.tempData.anchorX or 0) + dax)
    self:setAnchorY((self.tempData.anchorY or 0) + day)
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
    if self.anchorDragging then
        self:updateAnchorDrag(self:getMouseX(), self:getMouseY())
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
    if self.anchorDragging then
        self:updateAnchorDrag(getMouseX() - self:getAbsoluteX(), getMouseY() - self:getAbsoluteY())
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
    if self.anchorDragging then
        self.anchorDragging = nil
        self:setCapture(false)
        return true
    end
    return ISPanel.onMouseUp(self, x, y)
end

function GridDevToolUI:onMouseUpOutside(x, y)
    if self.anchorDragging then
        self.anchorDragging = nil
        self:setCapture(false)
        return true
    end
    return ISPanel.onMouseUpOutside and ISPanel.onMouseUpOutside(self, x, y)
end

--- Scroll com TECLA MODIFICADORA ATIVA (Ctrl/Shift/Alt) sobre o footprint do
--- preview ajusta a ESCALA da sprite AO VIVO — ajuste fino de tamanho sem sair
--- do preview, complementando o drag do anchor. Sem modificadora, não faz nada.
--- Convenção PZ: del > 0 = rolar pra BAIXO → scale diminui; del < 0 = cima → sobe.
--- Shift = passo fino (0.01), Ctrl = médio (0.05), Alt = grosso (0.2).
function GridDevToolUI:onMouseWheel(del)
    if not (self.isItem and self.item) then return false end

    -- Só reage com modificadora ativa E mouse sobre o footprint (não a janela toda).
    -- B42: globals são isCtrlKeyDown/isShiftKeyDown/isAltKeyDown (LuaManager.GlobalObject).
    local ctrl = isCtrlKeyDown and isCtrlKeyDown() or false
    local shift = isShiftKeyDown and isShiftKeyDown() or false
    local alt = isAltKeyDown and isAltKeyDown() or false
    if not (ctrl or shift or alt) then return false end

    local cell, fx, fy, fw, fh = self:computePreviewGeometry()
    local mx = self:getMouseX()
    local my = self:getMouseY()
    if mx < fx or mx > fx + fw or my < fy or my > fy + fh then return false end

    local step = 0.05
    if shift then step = 0.01
    elseif ctrl then step = 0.05
    elseif alt then step = 0.2 end

    if self.ppLock then
        self:incScale(-del)
    else
        self:setScale((self.tempData.scale or 1) + step * (-del))
    end
    return true
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
    -- Editando um ITEM: mostra o fullType do item (ex: "Base.Hammer"), com o
    -- nome amigável junto. Antes mostrava o CONTAINER (Floor/Player), que é a
    -- chave do grid — errado quando o alvo é o item.
    if self.isItem and self.item and self.item.getFullType then
        local ft = self.item:getFullType()
        local disp = (self.item.getName and self.item:getName()) or nil
        if disp and disp ~= ft then
            return ft .. " (" .. disp .. ")"
        end
        return ft
    end
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
    local title = "Grid DevTool: " .. GridDevToolUI.friendlyName(self)
    if self.variants then
        local vk = self.variants[self.variantIndex] or "?"
        -- Extrait o nome da sprite depois do pipe (fullType|spriteName).
        local shortName = vk:match("|([^|]+)$") or vk
        shortName = shortName:match("^(.+)%.") or shortName
        title = title .. " [" .. self.variantIndex .. "/" .. #self.variants .. " " .. shortName .. "]"
    end
    self:drawTextCentre(title, self.width / 2, 10, 1, 1, 1, 1, UIFont.Small)
    
    -- Flash do botão Save (Copy/Paste feedback visual, ~250ms).
    if self._flashEnd and self._flashEnd > 0 then
        self._flashEnd = self._flashEnd - 1
        local c = self._flashColor or {r=0.2, g=0.5, b=0.2, a=0.9}
        self.btnSave.backgroundColor = c
    elseif self._flashEnd and self._flashEnd <= 0 then
        self.btnSave.backgroundColor = { r = 0.2, g = 0.2, b = 0.2, a = 0.8 }
        self._flashEnd = nil
    end
    
    -- Valores desenhados ALINHADOS com as linhas reais do initialise (posições
    -- dinâmicas conforme o tipo de alvo — self.labels). x=205 é o centro entre
    -- os botões -/+ (160/220).
    if self.labels then
        if self.labels.variant then
            local vk = self.variants and self.variants[self.variantIndex] or ""
            local shortName = vk:match("|([^|]+)$") or vk
            shortName = shortName:match("([^/\\]+)$") or shortName
            local varStr = self.variantIndex .. "/" .. #self.variants .. " " .. shortName
            self:drawTextCentre(varStr, 185, self.labels.variant, 0.5, 0.8, 0.5, 1, UIFont.Small)
        end
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
        if self.labels.angle then
            local ang = self.tempData.angle or 0
            if ang == 0 then
                self:drawTextCentre("0", 205, self.labels.angle, 0.6, 0.6, 0.6, 1, UIFont.Small)
            else
                self:drawTextCentre(tostring(ang), 205, self.labels.angle, 0.4, 0.8, 1, 1, UIFont.Small)
            end
        end
        if self.labels.scale then
            local scl = self.tempData.scale or 1
            if self.ppLock and self.ppCurrentN then
                -- Com lock pixel-perfect, mostra o N atual (1:1, 2:1...) em
                -- verde, deixando claro que o scale está travado na proporção.
                self:drawTextCentre(tostring(self.ppCurrentN) .. ":1", 205, self.labels.scale, 0.4, 0.9, 0.5, 1, UIFont.Small)
            elseif scl == 1 then
                self:drawTextCentre("1x", 205, self.labels.scale, 0.6, 0.6, 0.6, 1, UIFont.Small)
            else
                -- %g limpa floats longos do setScalePrecise (pixel-perfect).
                self:drawTextCentre(string.format("%.4g", scl) .. "x", 205, self.labels.scale, 0.8, 1, 0.5, 1, UIFont.Small)
            end
        end
        if self.labels.anchorX then
            local ax = self.tempData.anchorX or 0
            if ax == 0 then
                self:drawTextCentre("0", 205, self.labels.anchorX, 0.6, 0.6, 0.6, 1, UIFont.Small)
            else
                self:drawTextCentre(tostring(ax) .. "px", 205, self.labels.anchorX, 0.9, 0.75, 0.5, 1, UIFont.Small)
            end
        end
        if self.labels.anchorY then
            local ay = self.tempData.anchorY or 0
            if ay == 0 then
                self:drawTextCentre("0", 205, self.labels.anchorY, 0.6, 0.6, 0.6, 1, UIFont.Small)
            else
                self:drawTextCentre(tostring(ay) .. "px", 205, self.labels.anchorY, 0.9, 0.75, 0.5, 1, UIFont.Small)
            end
        end
    end

    -- Feedback do Max Container Grid Size (sandbox option): mostra o teto geral
    -- vigente e avisa que o override FIRME pode ultrapassá-lo. Só pra
    -- containers sem item (worldobj/player/floor).
    if self.maxGridNote and not self.isItem then
        local minW = GridSandboxOptions.getMinWorldGridWidth()
        local maxV = GridSandboxOptions.getMaxContainerGridSize()
        self:drawText("Grid (sandbox): W " .. tostring(minW) .. " / H " .. tostring(maxV),
            self.width / 2 - 120, self.maxGridNote, 0.8, 0.9, 0.7, 1, UIFont.Small)
    end

    -- Preview do footprint: mostra AO VIVO o W×H, a cor da categoria e a sprite
    -- com ângulo/escala/anchor atuais. Sem isso, editar um item vindo do browser
    -- (que não tem grid atrás) é configurar no escuro.
    if self.isItem and self.previewX then
        self:drawFootprintPreview()
    end
end

--- Geometria do footprint no preview (célula + caixa), compartilhada entre o
--- desenho (drawFootprintPreview) e o mouse (drag do anchor). A matemática é a
--- MESMA em ambos pra o clique/arrasto bater exatamente com o que é desenhado.
--- @return number, number, number, number, number cell, fx, fy, fw, fh
function GridDevToolUI:computePreviewGeometry()
    local px = self.previewX
    local py = self.previewY
    local pw = self.previewW
    local ph = self.previewH

    -- Área interna (margem de 6px do fundo).
    local areaX = px + 6
    local areaY = py + 6
    local areaW = pw - 12
    local areaH = ph - 12

    local w = self.tempData.w or 1
    local h = self.tempData.h or 1

    -- Tamanho da célula: o footprint (W×H) cabe inteiro na área do preview.
    -- Mesmo conceito do cellSize do render, mas dimensionado ao preview.
    local cell = math.max(4, math.floor(math.min(areaW / w, areaH / h)))
    cell = math.min(cell, 48)
    local fw = w * cell
    local fh = h * cell
    local fx = areaX + math.floor((areaW - fw) / 2)
    local fy = areaY + math.floor((areaH - fh) / 2)
    return cell, fx, fy, fw, fh
end

--- Preview AO VIVO do footprint do item, dentro do DevTool. Reusa a MESMA
--- matemática do GridRender (PAD=2, min-fit, ângulo, escala, anchor) pra que o
--- preview bata com o que o render vai aplicar na grid — não é um "desenho
--- aproximado". Coordenadas: as funções draw* são LOCAIS ao painel; o quad
--- rotacionado usa javaObject:DrawTexture com coords ABSOLUTAS (como o
--- GridRender faz).
function GridDevToolUI:drawFootprintPreview()
    local item = self.item
    if not item then return end

    local px = self.previewX
    local py = self.previewY
    local pw = self.previewW
    local ph = self.previewH

    -- Fundo escuro do preview + borda.
    self:drawRect(px, py, pw, ph, 0.2, 0.1, 0.1, 0.1)
    self:drawRectBorder(px, py, pw, ph, 1, 0.5, 0.5, 0.5)

    local cell, fx, fy, fw, fh = self:computePreviewGeometry()
    local w = self.tempData.w or 1
    local h = self.tempData.h or 1

    -- Fundo do footprint: degrade da categoria (NEUTRO topo → CATEGORIA base),
    -- exatamente como o GridRender desenha a célula de item.
    local bands = ItemCategory.getGradient(item, fh)
    for _, band in ipairs(bands) do
        self:drawRect(fx, fy + band.y, fw, band.h, 1, band.r, band.g, band.b)
    end

    -- Linhas de grade do footprint (células W×H).
    for i = 1, w - 1 do
        self:drawRect(fx + i * cell, fy, 1, fh, 0.3, 0, 0, 0)
    end
    for j = 1, h - 1 do
        self:drawRect(fx, fy + j * cell, fw, 1, 0.3, 0, 0, 0)
    end
    self:drawRectBorder(fx, fy, fw, fh, 1, 0.75, 0.75, 0.75)

    -- Sprite: mesmos parâmetros do render (ângulo/escala/anchor AO VIVO do
    -- tempData + isRotated do item).
    local texture = self:getItemTex()
    if texture then
        local texW = texture:getWidth()
        local texH = texture:getHeight()

        local isRotated = false
        if item.getModData then
            local md = item:getModData()
            isRotated = md and md.gridRot or false
        end

        local deg = self.tempData.angle or 0
        local iconScale = self.tempData.scale or 1
        local anchorX = self.tempData.anchorX or 0
        local anchorY = self.tempData.anchorY or 0

        -- Sandbox option "GridInventory.IconRotation" (o servidor decide): quando
        -- DESLIGADA, TODOS os jogadores veem o sprite no padrão (angle=0,
        -- scale=1, anchor=0) mesmo com override salvo. O preview acompanha pra
        -- mostrar exatamente o que será renderizado no jogo.
        if GridSandboxOptions.isIconRotationEnabled
            and not GridSandboxOptions.isIconRotationEnabled() then
            deg = 0
            iconScale = 1
            anchorX = 0
            anchorY = 0
        end

        -- PAD do render (1px cada lado).
        local PAD = 2
        local scaleW = math.max(1, fw - PAD)
        local scaleH = math.max(1, fh - PAD)

        if deg == 0 then
            -- Caminho do render p/ ângulo 0 (drawItemIconRotated): swap
            -- texW/texH se isRotated, min-fit, escala, anchor (girado junto).
            local visualTexW = isRotated and texH or texW
            local visualTexH = isRotated and texW or texH
            local scale = math.min(scaleW / visualTexW, scaleH / visualTexH) * iconScale
            local drawW = (isRotated and texH or texW) * scale
            local drawH = (isRotated and texW or texH) * scale
            local ox = (fw - drawW) / 2
            local oy = (fh - drawH) / 2
            local ax, ay = anchorX, anchorY
            if isRotated then ax, ay = ay, -ax end
            -- drawTextureScaled é LOCAL ao painel.
            self:drawTextureScaled(texture, fx + ox + ax, fy + oy + ay, drawW, drawH, 1, 1, 1, 1)
        else
            -- Caminho do render p/ rotação livre (drawItemIconRotatedFree):
            -- bbox do quad girado, min-fit, anchor no centro, 4 cantos.
            local effDeg = deg + (isRotated and -90 or 0)
            local rad = effDeg * math.pi / 180
            local cosT = math.cos(rad)
            local sinT = math.sin(rad)
            local bboxW = math.abs(texW * cosT) + math.abs(texH * sinT)
            local bboxH = math.abs(texW * sinT) + math.abs(texH * cosT)
            local scale = math.min(scaleW / bboxW, scaleH / bboxH) * iconScale
            local drawW = texW * scale
            local drawH = texH * scale
            local centerX = fx + fw / 2
            local centerY = fy + fh / 2
            centerX = centerX + anchorX * cosT - anchorY * sinT
            centerY = centerY + anchorX * sinT + anchorY * cosT
            local hw = drawW / 2
            local hh = drawH / 2
            local corners = {
                {-hw, -hh},
                { hw, -hh},
                { hw,  hh},
                {-hw,  hh},
            }
            for i = 1, 4 do
                local cxp, cyp = corners[i][1], corners[i][2]
                corners[i][1] = centerX + cxp * cosT - cyp * sinT
                corners[i][2] = centerY + cxp * sinT + cyp * cosT
            end
            -- javaObject:DrawTexture (4 cantos) é ABSOLUTO na tela.
            local absX = self:getAbsoluteX()
            local absY = self:getAbsoluteY()
            self.javaObject:DrawTexture(texture,
                absX + corners[1][1], absY + corners[1][2],
                absX + corners[2][1], absY + corners[2][2],
                absX + corners[3][1], absY + corners[3][2],
                absX + corners[4][1], absY + corners[4][2],
                1, 1, 1, 1)
        end
    end

    -- Legenda: W×H + ângulo atual + peso (ajuda a conferir o tamanho).
    local ang = self.tempData.angle or 0
    local legend = tostring(w) .. "x" .. tostring(h)
    if ang ~= 0 then legend = legend .. "  a=" .. tostring(ang) end
    if item.getWeight then
        local weight = tonumber(item:getWeight())
        if weight then
            -- 3 casas (0.005 → 0.005, 1.5 → 1.5) sem zeros à direita.
            legend = legend .. "  " .. tostring(weight):gsub("%.?0+$", "") .. "kg"
        end
    end
    self:drawText(legend, px + 8, py + 8, 1, 1, 1, 1, UIFont.Small)

    -- Aviso quando a sandbox option "IconRotation" está desligada: o preview
    -- mostra o sprite PADRÃO (o que os jogadores vão ver), mesmo que os campos
    -- à esquerda tenham angle/scale/anchor preenchidos.
    if GridSandboxOptions.isIconRotationEnabled
        and not GridSandboxOptions.isIconRotationEnabled() then
        self:drawText("IconRotation OFF (sandbox): sprites no padrao", px + 8, py + ph - 20, 1, 0.6, 0.2, 1, UIFont.Small)
    end

    -- Hover/drag do ANCHOR: destaca o footprint e mostra o valor atual em px.
    -- Feedback de "arrastável" (borda amarela) + texto com o anchor atual pra
    -- conferir o deslocamento sem ler a coluna da esquerda. Com modificadora
    -- ativa, o scroll vira ajuste de ESCALA (mesmo destaque).
    if self:isMouseOver() then
        local mx = self:getMouseX()
        local my = self:getMouseY()
        local overFootprint = (mx >= fx and mx <= fx + fw and my >= fy and my <= fy + fh)
        if overFootprint or self.anchorDragging then
            local ctrl = isCtrlKeyDown and isCtrlKeyDown() or false
            local shift = isShiftKeyDown and isShiftKeyDown() or false
            local alt = isAltKeyDown and isAltKeyDown() or false
            local modActive = (ctrl or shift or alt) and not self.anchorDragging
            local highlight = nil
            if self.anchorDragging then
                highlight = {1, 0.6, 0.1}
            elseif modActive then
                highlight = {0.4, 0.9, 1}
            elseif overFootprint then
                highlight = {1, 0.9, 0.3}
            end
            if highlight then
                self:drawRectBorder(fx, fy, fw, fh, 2, highlight[1], highlight[2], highlight[3])
            end
            if self.anchorDragging then
                local ax = self.tempData.anchorX or 0
                local ay = self.tempData.anchorY or 0
                self:drawText("arrastando  anchor: " .. tostring(ax) .. ", " .. tostring(ay), px + 8, py + ph - 16, 1, 0.6, 0.1, 1, UIFont.Small)
            elseif overFootprint then
                local scaleNow = self.tempData.scale or 1
                if modActive then
                    -- Com modificadora ativa, scroll = scale (mostra o valor + dica).
                    self:drawText("scroll = scale  atual: " .. tostring(scaleNow), px + 8, py + ph - 16, 0.4, 0.9, 1, 1, UIFont.Small)
                else
                    -- Sem modificadora: só o hover do anchor (dica de arrastar).
                    local ax = self.tempData.anchorX or 0
                    local ay = self.tempData.anchorY or 0
                    self:drawText("arraste p/ anchor  " .. tostring(ax) .. ", " .. tostring(ay), px + 8, py + ph - 16, 1, 0.9, 0.3, 1, UIFont.Small)
                end
            end
        end
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
        ui:bringToTop()
    end)
    devOption.iconTexture = getTexture("media/ui/BugIcon.png")
end

--- Botão "Browse" do DevTool: abre o browser de itens do jogo.
function GridDevToolUI:onBrowse()
    if not canUseDevTools(self.player) then return end
    -- GridDevBrowser.lua é auto-carregado pelo PZ (media/lua/client); fallback
    -- lazy pro caso de ordem de carga (nunca rodar a UI duas vezes via require).
    local browser = GridDevBrowser or (package.loaded and package.loaded["UI/GridDevBrowser"])
    if not browser then return end
    browser.open(self:getX(), self:getY() + self:getHeight() + 10, self.player)
end

--- Botão "Derivados" do DevTool: abre o browser já filtrado pros itens que
--- nascem deste item via evolved recipes (ex: Base.Bowl vira Base.Salad,
--- Base.FruitSalad...). Esses derivados têm fullTypes PRÓPRIOS — editar o item
--- base não muda o footprint/sprite deles. Aqui o usuário vê a lista e pode
--- abrir o DevTool de cada um pra aplicar o mesmo tuning.
function GridDevToolUI:onDerived()
    if not canUseDevTools(self.player) then return end
    if not self.itemFullType then return end
    local browser = GridDevBrowser or (package.loaded and package.loaded["UI/GridDevBrowser"])
    if not browser then return end
    browser.open(self:getX(), self:getY() + self:getHeight() + 10, self.player, self.itemFullType)
end

Events.OnFillInventoryObjectContextMenu.Add(OnFillInventoryObjectContextMenu)

-- ─── Nudge do anchor com as SETAS ───────────────────────────────────────────
-- O drag do anchor captura o MOUSE (setCapture) — o teclado NÃO é roteado pro
-- painel. Então as setas são pegas por um handler GLOBAL: enquanto houver um
-- DevTool com anchorDragging ativo, cada press de seta move 1px no eixo da
-- tela (X/Y). Keycodes B42 (Keyboard.KEY_*): UP=200, LEFT=203, RIGHT=205,
-- DOWN=208. OnKeyStartPressed = 1 passo por press (segurar não repete).
local DEVTOOL_ARROW_KEYS = {
    [Keyboard.KEY_UP] = {0, -1},
    [Keyboard.KEY_DOWN] = {0, 1},
    [Keyboard.KEY_LEFT] = {-1, 0},
    [Keyboard.KEY_RIGHT] = {1, 0},
}

local function devToolOnKeyStartPressed(key)
    local dir = DEVTOOL_ARROW_KEYS[key]
    if not dir then return end
    for i = #GridDevToolUI.openInstances, 1, -1 do
        local ui = GridDevToolUI.openInstances[i]
        if ui and ui.anchorDragging then
            ui:nudgeAnchor(dir[1], dir[2])
            return
        end
    end
end

Events.OnKeyStartPressed.Add(devToolOnKeyStartPressed)

-- ─── Clipboard compartilhado (Copy/Paste) ───────────────────────────────────
-- Uma tabela estática que sobrevive entre instâncias do DevTool. Ao copiar,
-- grava w/h/angle/scale/anchorX/anchorY/stackable/maxStack. Ao colar, aplica
-- no DevTool ativo (incluindo overrides ao vivo pro preview atualizar).
GridDevToolUI.clipboard = nil

function GridDevToolUI:onCopy()
    local d = self.tempData
    GridDevToolUI.clipboard = {
        w = d.w,
        h = d.h,
        angle = d.angle,
        scale = d.scale,
        anchorX = d.anchorX,
        anchorY = d.anchorY,
        stackable = d.stackable,
        maxStackAuto = d.maxStackAuto,
        maxStack = d.maxStack,
    }
    self._flashEnd = 15 -- ~250ms a 16fps
    self._flashColor = { r = 0.2, g = 0.6, b = 0.2, a = 0.9 }
end

function GridDevToolUI:onPaste()
    local c = GridDevToolUI.clipboard
    if not c then return end
    self.tempData.w = c.w
    self.tempData.h = c.h
    self.tempData.angle = c.angle
    self.tempData.scale = c.scale
    self.tempData.anchorX = c.anchorX
    self.tempData.anchorY = c.anchorY
    self.tempData.stackable = c.stackable
    self.tempData.maxStackAuto = c.maxStackAuto
    self.tempData.maxStack = c.maxStack
    -- Aplica ao vivo no preview.
    self:setAngle(self.tempData.angle or 0)
    self:setScale(self.tempData.scale or 1)
    self:setAnchorX(self.tempData.anchorX or 0)
    self:setAnchorY(self.tempData.anchorY or 0)
    self:updateStackButton()
    self:updateMaxButton()
    self:syncMaxEntry()
    self._flashEnd = 15
    self._flashColor = { r = 0.2, g = 0.2, b = 0.6, a = 0.9 }
end

return GridDevToolUI
