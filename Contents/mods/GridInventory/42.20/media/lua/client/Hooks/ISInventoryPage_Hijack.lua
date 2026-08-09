require "ISUI/ISInventoryPage"
local PaperDollWindow = require("UI/PaperDoll/PaperDollWindow")
local GlobalDragRender = require("UI/GridRender/GlobalDragRender")

-- Precisamos manter uma referência global para o PaperDoll
GridInventory_PaperDollWindow = GridInventory_PaperDollWindow or {}

-- Mata o Resize globalmente
local og_resizeInit = ISResizeWidget.initialise
function ISResizeWidget:initialise()
    og_resizeInit(self)
    self.onMouseDown = function() end
    self.onMouseMove = function() end
    self.onMouseMoveOutside = function() end
end

local og_createChildren = ISInventoryPage.createChildren
function ISInventoryPage:createChildren()
    og_createChildren(self)

    -- Instancia o Renderizador Global de Drag uma única vez!
    if not GridInventory_GlobalDragRendererInstance then
        GridInventory_GlobalDragRendererInstance = GlobalDragRender:new()
        GridInventory_GlobalDragRendererInstance:initialise()
        GridInventory_GlobalDragRendererInstance:addToUIManager()
        GridInventory_GlobalDragRendererInstance:setVisible(true)
    end

    if self.onCharacter then
        local paperDollWidth = 350
        
        -- Cria a janela Sidecar do PaperDoll
        local paperDoll = PaperDollWindow:new(0, 0, paperDollWidth, self.height, self.player)
        paperDoll:initialise()
        paperDoll:addToUIManager()
        paperDoll:setVisible(false)
        
        GridInventory_PaperDollWindow[self.player] = paperDoll
    end
end

local og_update = ISInventoryPage.update
function ISInventoryPage:update()
    -- Roda o Zomboid (e o maldito CleanUI) primeiro!
    og_update(self)

    -- Coalesce do onInventoryUpdate: o refreshContainer (remap de todos os
    -- containers) roda no maximo 1x por frame e apenas com o painel visivel.
    local pane = self.inventoryPane
    if pane and pane.gridRefreshDirty then
        pane.gridRefreshDirty = nil
        if self:getIsVisible() and pane:getIsVisible() then
            pane:refreshContainer()
        end
    end

    local core = getCore()
    local screenW = core:getScreenWidth()
    local screenH = core:getScreenHeight()
    local paperDollW = 350
    local panelW = (screenW - paperDollW) / 2

    -- Destruir a maldição do Zomboid que limita a altura da janela!
    self:clearMaxDrawHeight()
    self.maxDrawHeight = -1

    -- Define o tamanho do painel base
    self:setWidth(panelW)
    self:setHeight(screenH)
    self:setY(0)
    
    if self.onCharacter then
        local pd = GridInventory_PaperDollWindow[self.player]
        if pd then pd:setHeight(screenH) end
    end

    -- Layout das mochilas e grids
    if self.onCharacter then
        self:setX(0)
        
        -- Inventário do Jogador: Grid na ESQUERDA (borda), Mochilas na DIREITA (centro)
        if self.containerButtonPanel then
            self.containerButtonPanel:setX(panelW - self.buttonSize)
            self.containerButtonPanel:setHeight(screenH)
        end
        if self.inventoryPane then
            self.inventoryPane:setX(0)
            self.inventoryPane:setWidth(panelW - self.buttonSize)
        end
        if self.controlsUI then
            self.controlsUI:setX(0)
            self.controlsUI:setWidth(panelW - self.buttonSize)
            self.controlsUI:setY(self.height - 30)
        end
    else
        self:setX(panelW + paperDollW)
        
        -- Loot: Mochilas na ESQUERDA (centro), Grid na DIREITA (borda)
        if self.containerButtonPanel then
            self.containerButtonPanel:setX(0)
            self.containerButtonPanel:setHeight(screenH)
        end
        if self.inventoryPane then
            self.inventoryPane:setX(self.buttonSize)
            self.inventoryPane:setWidth(panelW - self.buttonSize)
        end
    end
    
    -- Ajuste da Title Bar (Mover botões pro canto direito, descontando o painel de mochilas se ele estiver na direita)
    -- Nativamente o Zomboid espera os botões acima das mochilas na direita.
    local btnOffset = self.width
    if self.onCharacter then
        -- No inventário do player, as mochilas ficam na direita, vamos recuar os botões pra não esmagar com o peso
        btnOffset = self.width - self.buttonSize - 5
    end
    
    if self.closeButton then
        self.closeButton:setX(btnOffset - 3 - 21)
    end
    if self.infoButton then
        self.infoButton:setVisible(false)
    end
    if self.pinButton then 
        self.pinButton:setVisible(false) 
    end
    if self.collapseButton then 
        self.collapseButton:setVisible(false) 
    end

    -- O SEGREDO DE TUDO:
    -- O Zomboid recalcula a posição do footer (controlsUI) baseado na posição Y do resizeWidget!
    -- Como a gente escondia o resizeWidget mas não atualizava a posição dele,
    -- o Zomboid ficava puxando os botões pro meio da tela (a altura antiga).
    -- Aqui nós ancoramos o fantasma do resizeWidget perto do fundo da tela (1080p).
    -- Subimos uns pixels (screenH - 20) para dar espaço e não bugar a engine.
    if self.resizeWidget then
        self.resizeWidget:setY(screenH - 15)
        self.resizeWidget:setX(self.width)
    end
    if self.resizeWidget2 then
        self.resizeWidget2:setY(screenH - 15)
        self.resizeWidget2:setX(self.width)
    end

    -- Se o Zomboid disparar o arrange() fora do update, ele vai usar o Y correto!
    -- Mas precisamos garantir o layout X pro player (esquerda) e loot (direita).
    if self.controlsUI then
        if self.onCharacter then
            self.controlsUI:setX(0)
        else
            self.controlsUI:setX(self.buttonSize)
        end
        self.controlsUI:setWidth(panelW - self.buttonSize)
        self.controlsUI:setY(screenH - 15 - self.controlsUI:getHeight())
    end

    -- Esconde os botões soltos da title bar nativa, pois o controlsUI já cuida de tudo no rodapé
    if type(self.lootAll) == "table" and self.lootAll.setVisible then
        self.lootAll:setVisible(false)
    end
    if type(self.transferAll) == "table" and self.transferAll.setVisible then
        self.transferAll:setVisible(false)
    end
    if type(self.removeAll) == "table" and self.removeAll.setVisible then
        self.removeAll:setVisible(false)
    end

    -- Destruir completamente a habilidade de redimensionar e os widgets nativos!
    self.resizable = false
    self.pin = true
    self.isCollapsed = false
end

-- Hook para mostrar/esconder o PaperDoll e o Loot juntos
local og_setVisible = ISInventoryPage.setVisible
function ISInventoryPage:setVisible(visible)
    og_setVisible(self, visible)
    
    if visible then
        self:bringToTop()
    end
    
    if self.onCharacter then
        local paperDoll = GridInventory_PaperDollWindow[self.player]
        if paperDoll then
            paperDoll:setVisible(visible)
            if visible then paperDoll:bringToTop() end
        end
        local lootPage = getPlayerLoot(self.player)
        if lootPage then
            if lootPage:getIsVisible() ~= visible then
                lootPage:setVisible(visible)
            end
            if visible then lootPage:bringToTop() end
        end
    else
        local invPage = getPlayerInventory(self.player)
        if invPage then
            if invPage:getIsVisible() ~= visible then
                invPage:setVisible(visible)
            end
            if visible then invPage:bringToTop() end
        end
    end
end

local og_pagePrerender = ISInventoryPage.prerender
function ISInventoryPage:prerender()
    local oldTitle = self.title
    
    -- Ocultamos APENAS o título para que a classe pai não desenhe o nome do container
    self.title = ""
    
    og_pagePrerender(self)
    
    self.title = oldTitle
    
    -- Desenha um fundo sólido escuro (estilo Tarkov/Zomboid) em TODO o painel!
    -- Reduzi a opacidade de 0.85 para 0.65 para que o jogador consiga ver os zumbis!
    local w = self:getWidth()
    local h = self:getHeight()
    local titleH = self:titleBarHeight()
    
    self:drawRect(0, titleH, w, h - titleH, 0.65, 0.08, 0.08, 0.08)
    self:drawRectBorder(0, titleH, w, h - titleH, 0.5, 0.5, 0.5, 0.5)
    
    -- (Bordas dos botões suspensas a pedido do usuário devido a spam de erros no console)
    
    -- Restaura a borda bonitinha exclusiva da coluna de mochilas
    -- E também mantemos um fundo mais opaco (0.85) só pra essa coluna,
    -- garantindo que os botões não fiquem confusos com o chão!
    if self.containerButtonPanel then
        local bx = self.containerButtonPanel:getX()
        local by = self.containerButtonPanel:getY()
        local bw = self.containerButtonPanel:getWidth()
        local bh = self.containerButtonPanel:getHeight()
        
        -- Fundo mais forte pra coluna das mochilas
        self:drawRect(bx, by, bw, bh, 0.85, 0.08, 0.08, 0.08)
        self:drawRectBorder(bx, by, bw, bh, 0.5, 0.5, 0.5, 0.5)
    end
end

-- Hook no render estava atrasado pois a barra é desenhada no prerender
local og_pageRender = ISInventoryPage.render
function ISInventoryPage:render()
    og_pageRender(self)
end

-- Sobrescrevemos o sistema de destaque visual (highlight verde no chão) 
-- para garantir que TODOS os grids visíveis brilhem no mundo do jogo, e não só o ativo nativo.
local og_updateContainerHighlight = ISInventoryPage.updateContainerHighlight
function ISInventoryPage:updateContainerHighlight()
    -- Chama o original para o Zomboid tratar o container ativo
    og_updateContainerHighlight(self)
    
    -- Só queremos fazer isso pro painel de Loot (onde temos as pilhas de caixas/zumbis)
    if self.onCharacter then return end
    
    -- 1. Removemos os destaques da galera que saiu da tela
    if self.extraColoredInvs then
        for _, oldInv in ipairs(self.extraColoredInvs) do
            -- Não mexemos no ativo nativo, pois o vanilla cuida dele
            if oldInv ~= self.inventory then
                local coloredObj = self:getContainerParent(oldInv)
                if coloredObj then
                    coloredObj:setHighlighted(self.player, false)
                    coloredObj:setOutlineHighlight(self.player, false)
                    if coloredObj.setOutlineHlAttached then
                        coloredObj:setOutlineHlAttached(self.player, false)
                    end
                end
            end
        end
    end
    
    self.extraColoredInvs = {}
    
    -- 2. Adicionamos o destaque pra TODO MUNDO que está visível no painel agora
    if not self.isCollapsed and self.inventoryPane and self.inventoryPane.gridContainerUis then
        for _, ui in ipairs(self.inventoryPane.gridContainerUis) do
            local inv = ui.inventoryContainer
            if inv and inv ~= self.inventory then
                local coloredObj = self:getContainerParent(inv)
                if coloredObj then
                    if (not instanceof(coloredObj, "IsoPlayer")) or instanceof(coloredObj, "IsoDeadBody") then
                        coloredObj:setHighlighted(self.player, true, false)
                        if getCore():getOptionDoContainerOutline() then
                            coloredObj:setOutlineHighlight(self.player, true)
                            if coloredObj.setOutlineHlAttached then
                                coloredObj:setOutlineHlAttached(self.player, true)
                            end
                            local hc = getCore():getObjectHighlitedColor()
                            coloredObj:setOutlineHighlightCol(self.player, hc:getR(), hc:getG(), hc:getB(), 1)
                        end
                        coloredObj:setHighlightColor(self.player, getCore():getObjectHighlitedColor())
                        table.insert(self.extraColoredInvs, inv)
                    end
                end
            end
        end
    end
end

-- No-op module-level (sem closure): evita alocar 6 closures por frame no render
-- abaixo, que precisa mutar os métodos de desenho do ISInventoryPane.
local function noop() end

local og_inventoryRender = ISInventoryPane.render
function ISInventoryPane:render()
    -- Hack para forçar alpha zero no texto
    local og_drawText = self.drawText
    local og_drawTextRight = self.drawTextRight
    local og_drawTexture = self.drawTexture
    local og_drawTextureScaled = self.drawTextureScaled
    local og_drawRect = self.drawRect
    local og_drawRectBorder = self.drawRectBorder
    
    self.drawText = noop
    self.drawTextRight = noop
    self.drawTexture = noop
    self.drawTextureScaled = noop
    self.drawRect = noop
    self.drawRectBorder = noop
    
    -- Oculta os botões inúteis de Expandir/Recolher Lista de forma DEFINITIVA
    -- Mutilando as funções de renderização deles pra não piscarem durante o render original
    if self.expandAll and not self.expandAll._isMuted then
        self.expandAll.render = noop
        self.expandAll.prerender = noop
        self.expandAll._isMuted = true
    end
    if self.collapseAll and not self.collapseAll._isMuted then
        self.collapseAll.render = noop
        self.collapseAll.prerender = noop
        self.collapseAll._isMuted = true
    end
    
    og_inventoryRender(self)
    
    -- Restaura no final
    self.drawText = og_drawText
    self.drawTextRight = og_drawTextRight
    self.drawTexture = og_drawTexture
    self.drawTextureScaled = og_drawTextureScaled
    self.drawRect = og_drawRect
    self.drawRectBorder = og_drawRectBorder

    if self.myFinalHeight then
        self:setScrollHeight(self.myFinalHeight)
        self:updateScrollbars()
    end
end

-- Destruir a capacidade de mover a janela nativamente
function ISInventoryPage:onMouseDown(x, y)
    if not self:getIsVisible() then return end
    getSpecificPlayer(self.player):nullifyAiming()
end

-- Conserta a rolagem do mouse nas mochilas! (O Zomboid hardcodava o scroll para a direita)
function ISInventoryPage:onMouseWheel(del)
    if self.containerButtonPanel then
        local mx = self:getMouseX()
        local bx = self.containerButtonPanel:getX()
        local bw = self.containerButtonPanel:getWidth()
        
        -- Se o mouse não estiver em cima da coluna de botões, e não estiver segurando a tecla de atalho, ignora
        if mx < bx or mx > bx + bw then
            if not self:isCycleContainerKeyDown() then
                return false
            end
        end
    end

    return self:cycleContainer(del)
end

--- Troca o container selecionado usando o scroll (mesma lógica do vanilla
--- quando o mouse está sobre a coluna de mochilas/ícones). Também é chamado
--- pelo ISInventoryPane:onMouseWheel quando o scroll rola FORA de um grid.
function ISInventoryPage:cycleContainer(del)
    local currentIndex = self:getCurrentBackpackIndex()
    local unlockedIndex = -1

    local ms = getTimestampMs()
    self.lastMouseWheelMS = self.lastMouseWheelMS or 0
    local wrap = (self.containerButtonPanel.height > self.containerButtonPanel:getScrollHeight()) or (ms - self.lastMouseWheelMS > 750)
    self.lastMouseWheelMS = ms

    if del < 0 then
        unlockedIndex = self:prevUnlockedContainer(currentIndex, wrap)
    else
        unlockedIndex = self:nextUnlockedContainer(currentIndex, wrap)
    end

    if unlockedIndex ~= -1 then
        local playerObj = getSpecificPlayer(self.player)
        if playerObj and playerObj:getJoypadBind() ~= -1 then
            self.backpackChoice = unlockedIndex
        end
        self:selectContainer(self.backpacks[unlockedIndex])
    end
    return true
end

-- O auto-scroll + flash foi centralizado no prerender do ISInventoryPane
-- (ISInventoryPane_Hijack.lua): ele cobre abrir o loot, virar pra outro
-- container, clique na mochila e scroll do mouse, usando o baseY REAL do
-- flexbox (sem reimplementar o layout aqui, que ficava inconsistente com o
-- prerender). O selectContainer vanilla (chamado abaixo) já muda o
-- inventoryPane.inventory, e o prerender detecta a troca no próximo frame.
