require "ISUI/ISInventoryPage"
local PaperDollWindow = require("UI/PaperDoll/PaperDollWindow")
local GlobalDragRender = require("UI/GridRender/GlobalDragRender")
local GridModOptions = require("System/GridModOptions")

-- Precisamos manter uma referência global para o PaperDoll
GridInventory_PaperDollWindow = GridInventory_PaperDollWindow or {}

-- Resize do painel: desligado no modo Fullscreen (Mod Option padrão). Quando o
-- usuário desliga "Fullscreen Panel", os handles nativos de resize voltam a
-- funcionar (redimensionamento restaurado). O despacho acontece no momento do
-- evento (não na criação), então a troca da opção vale no frame seguinte.
local og_resizeInit = ISResizeWidget.initialise
function ISResizeWidget:initialise()
    og_resizeInit(self)
    local ogDown = self.onMouseDown
    local ogMove = self.onMouseMove
    local ogMoveOut = self.onMouseMoveOutside
    self.onMouseDown = function(self, x, y)
        if GridModOptions.isFullscreenPanel() then return end
        return ogDown(self, x, y)
    end
    self.onMouseMove = function(self, dx, dy)
        if GridModOptions.isFullscreenPanel() then return end
        return ogMove(self, dx, dy)
    end
    self.onMouseMoveOutside = function(self, dx, dy)
        if GridModOptions.isFullscreenPanel() then return end
        return ogMoveOut(self, dx, dy)
    end
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

-- Padding interno da barra de controles dentro do rodapé reservado da grid
-- ativa (pra não ficar grudada nas extremidades).
local CONTROLS_PAD = 1

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

    -- A controlsUI nasce com âncoras bottom/right. Como redimensionamos a
    -- página todo frame, o layout reaplica essas âncoras e JOGARIA os botões
    -- de volta pro rodapé (atrás da grid de altura total) e piscaria a cada
    -- troca de container. Desligamos TODAS as âncoras: a posição passa a ser
    -- 100% controlada por nós (setX/setY abaixo).
    if self.controlsUI then
        self.controlsUI:setAnchors(false)
    end

    local core = getCore()
    local screenW = core:getScreenWidth()
    local screenH = core:getScreenHeight()
    local paperDollW = 350

    -- Mod Option "Fullscreen Panel": ligada (padrão) = o painel ocupa metade
    -- da tela e NÃO pode ser redimensionado. Desligada = o painel volta ao
    -- comportamento nativo (resize habilitado, tamanho do usuário respeitado).
    local isFullscreen = GridModOptions.isFullscreenPanel()

    local panelW
    if isFullscreen then
        panelW = (screenW - paperDollW) / 2
    else
        panelW = self.width
    end

    -- Destruir a maldição do Zomboid que limita a altura da janela!
    -- EXCETO quando COLAPSADO: o vanilla usa maxDrawHeight = titleBarHeight()
    -- pra encolher a área de HIT-TEST do Java (isMouseOver/isPointOver). Se
    -- limparmos aqui, o painel colapsado fica "invisível" mas a área clicável
    -- continua do tamanho cheio — o clique atravessa pro grid (que computa a
    -- interação) e nullifyAiming dispara, fazendo o jogador PARAR DE MIRAR.
    if not self.isCollapsed then
        self:clearMaxDrawHeight()
        self.maxDrawHeight = -1
    else
        self:setMaxDrawHeight(self:titleBarHeight())
    end

    -- Define o tamanho do painel base (fullscreen força; resize preserva)
    if isFullscreen then
        self:setWidth(panelW)
        self:setHeight(screenH)
        self:setY(0)
    end
    
    if self.onCharacter then
        local pd = GridInventory_PaperDollWindow[self.player]
        if pd then
            if isFullscreen then
                pd:setHeight(screenH)
            end
            -- PaperDoll colapsa/expande JUNTO com o painel de inventário (modo
            -- resize): espelha o estado de collapse do inv a cada frame.
            local wantCollapsed = (not isFullscreen) and self.isCollapsed
            if pd.isCollapsed ~= wantCollapsed then
                pd.isCollapsed = wantCollapsed
                if wantCollapsed then
                    pd:setMaxDrawHeight(pd:titleBarHeight())
                else
                    pd:clearMaxDrawHeight()
                end
            end
        end
    end

    -- Layout das mochilas e grids
    if self.onCharacter then
        -- No modo resize o painel é uma janela nativa e pode ser MOVIDA pela
        -- titlebar (o onMouseDown restaura o moving); não forçamos o X.
        if isFullscreen then
            self:setX(0)
        end
        
        -- Inventário do Jogador: Grid na ESQUERDA (borda), Mochilas na DIREITA (centro)
        if self.containerButtonPanel then
            self.containerButtonPanel:setX(panelW - self.buttonSize)
            self.containerButtonPanel:setHeight(self.height)
        end
        if self.inventoryPane then
            self.inventoryPane:setX(0)
            self.inventoryPane:setWidth(panelW - self.buttonSize)
        end
    else
        -- Loot: posiciona à direita do PaperDoll. No modo resize usa a largura
        -- REAL do inventário do jogador (o painel já não é mais fullscreen).
        local invW = panelW
        if not isFullscreen then
            local invPage = getPlayerInventory(self.player)
            if invPage then
                invW = invPage:getWidth()
            end
        end
        if isFullscreen then
            self:setX(invW + paperDollW)
        end
        
        -- Loot: Mochilas na ESQUERDA (centro), Grid na DIREITA (borda)
        if self.containerButtonPanel then
            self.containerButtonPanel:setX(0)
            self.containerButtonPanel:setHeight(self.height)
        end
        if self.inventoryPane then
            self.inventoryPane:setX(self.buttonSize)
            self.inventoryPane:setWidth(self.width - self.buttonSize)
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
    -- Pin/Collapse: no fullscreen ficam ocultos (painel fixo e sempre aberto).
    -- No resize restauramos o comportamento nativo (vanilla): o pinButton
    -- (visível quando NÃO pinado) trava a janela aberta; o collapseButton
    -- (visível quando pinado) destrava — e aí a janela auto-colapsa pra
    -- titlebar quando o mouse sai, expandindo ao passar o mouse na titlebar.
    if isFullscreen then
        if self.pinButton then self.pinButton:setVisible(false) end
        if self.collapseButton then self.collapseButton:setVisible(false) end
    else
        if self.pinButton then self.pinButton:setVisible(not self.pin) end
        if self.collapseButton then self.collapseButton:setVisible(self.pin) end
        -- Pin/Collapse à ESQUERDA do botão de fechar (no loot o close fica no
        -- canto e, sem isso, os dois ocupariam o MESMO lugar na titlebar).
        local closeX = self.closeButton and self.closeButton:getX() or (btnOffset - 24)
        if self.pinButton then
            self.pinButton:setX(closeX - self.pinButton:getWidth() - 2)
            self.pinButton:setY(1)
        end
        if self.collapseButton then
            self.collapseButton:setX(closeX - self.collapseButton:getWidth() - 2)
            self.collapseButton:setY(1)
        end
    end

    -- O SEGREDO DE TUDO:
    -- O Zomboid recalcula a posição do footer (controlsUI) baseado na posição Y do resizeWidget!
    -- Como a gente escondia o resizeWidget mas não atualizava a posição dele,
    -- o Zomboid ficava puxando os botões pro meio da tela (a altura antiga).
    -- Aqui nós ancoramos o fantasma do resizeWidget perto do fundo da tela (1080p).
    -- Subimos uns pixels (screenH - 20) para dar espaço e não bugar a engine.
    -- No modo resize os handles são reais e usam as âncoras nativas do PZ.
    if isFullscreen then
        if self.resizeWidget then
            self.resizeWidget:setY(screenH - 15)
            self.resizeWidget:setX(self.width)
        end
        if self.resizeWidget2 then
            self.resizeWidget2:setY(screenH - 15)
            self.resizeWidget2:setX(self.width)
        end
    end

    -- A "controlsUI" (Take All / Transfer All / botões do objeto, ex: ligar e
    -- desligar o fogão) NÃO fica mais numa barra perdida no rodapé do painel.
    -- Ela é re-parentada para DENTRO do pane e vive no RODAPÉ RESERVADO do
    -- grid ATIVO: o grid ativo ganha +altura (a barra) e o grid debaixo desce
    -- (nunca sobrepõe). Usar coords locais do pane + setScrollChildren faz o
    -- scroll acompanhar a grid, e re-adicionar como ÚLTIMO filho do pane garante
    -- que renderiza por cima das grids. Sem grid/botões, a barra simplesmente some
    -- e o grid ativo volta à altura normal.
    if self.controlsUI and self.inventoryPane then
        self.controlsUI:setAnchors(false)
        -- Re-parenta pro pane (uma vez; addChild já desanexa da página)
        if self.controlsUI.parent ~= self.inventoryPane then
            self.inventoryPane:addChild(self.controlsUI)
        end
        local gridUi = nil
        if self.inventoryPane.gridContainerUis then
            local activeInv = self.inventoryPane.inventory
            for _, g in ipairs(self.inventoryPane.gridContainerUis) do
                if not g.isOverflow and g.inventoryContainer == activeInv then
                    gridUi = g
                    break
                end
            end
        end
        local hasButtons = (gridUi and self.controlsUI.controls and #self.controlsUI.controls > 0)
        -- Reserva o rodapé no grid ativo; restaura a altura dos demais grids
        local footerH = 0
        if hasButtons then
            footerH = math.max(24, (self.controlsUI:getHeight() or 0) + (CONTROLS_PAD * 2))
        end
        if self.inventoryPane.gridContainerUis then
            for _, g in ipairs(self.inventoryPane.gridContainerUis) do
                if not g.isOverflow then
                    if not g.baseGridHeight then
                        g.baseGridHeight = g:getHeight()
                    end
                    local targetH = g.baseGridHeight
                    if g == gridUi and footerH > 0 then
                        targetH = targetH + footerH
                    end
                    if g:getHeight() ~= targetH then
                        g:setHeight(targetH)
                    end
                end
            end
        end
        if hasButtons then
            -- Posiciona a barra dentro do rodapé reservado da grid ativa, com
            -- um pequeno padding pra não ficar grudada nas extremidades.
            self.controlsUI:setX(gridUi:getX() + CONTROLS_PAD)
            self.controlsUI:setY(gridUi:getY() + gridUi.baseGridHeight + CONTROLS_PAD)
            self.controlsUI:setWidth(gridUi:getWidth() - (CONTROLS_PAD * 2))
            self.controlsUI:setVisible(true)
            -- Último filho do pane → renderiza por cima das grids
            self.inventoryPane:removeChild(self.controlsUI)
            self.inventoryPane:addChild(self.controlsUI)
        else
            self.controlsUI:setVisible(false)
        end
        -- Devolve pro pane a altura que a barra ocupava no rodapé
        local resizeH = 0
        if self.resizeWidget and self.resizeWidget.height then
            resizeH = self.resizeWidget.height
        end
        self.inventoryPane:setHeight(self.height - self.inventoryPane.y - resizeH)
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

    -- No fullscreen destruímos a habilidade de redimensionar; no modo resize
    -- o usuário pode redimensionar (os handles nativos voltam a funcionar).
    self.resizable = not isFullscreen
    -- No fullscreen o painel é fixo e nunca colapsa (pin travado). No resize o
    -- usuário controla pin/collapse pelos botões da titlebar (vanilla) — o
    -- estado de pin/isCollapsed dele não é sobrescrito aqui.
    if isFullscreen then
        self.pin = true
        self.isCollapsed = false
    end
end

-- Re-flui os botões da controlsUI com gap de 1px (o vanilla usa UI_MARGIN=5,
-- uma local inacessível). Separa o grupo ancorado à direita (Turn On, Settings)
-- do grupo à esquerda e compacta cada um, preservando as ancoragens.
local function gridInv_compactControls(controlsUI)
    local controls = controlsUI.controls
    local uiW = controlsUI.width or 0
    if not controls or #controls < 2 or uiW <= 0 then return end

    -- Índice do 1º botão do grupo direito (borda direita encosta na largura).
    -- Se não houver, todos os botões pertencem ao grupo esquerdo.
    local rightStart = #controls + 1
    for i, c in ipairs(controls) do
        if c.getRight and c:getRight() >= uiW - 6 then
            rightStart = i
            break
        end
    end

    -- Grupo esquerdo: compacta por linha (mesmo getY), da esquerda pra direita.
    local rows = {}
    for i = 1, rightStart - 1 do
        local c = controls[i]
        local row = rows[c:getY()]
        if not row then
            row = {}
            rows[c:getY()] = row
        end
        table.insert(row, c)
    end
    for _, row in pairs(rows) do
        table.sort(row, function(a, b) return a:getX() < b:getX() end)
        local prevRight = row[1]:getRight()
        for j = 2, #row do
            row[j]:setX(prevRight + 1)
            prevRight = row[j]:getRight()
        end
    end

    -- Grupo direito: ancorado à direita, gap de 1px (cada um 1px à esquerda
    -- do botão já reposicionado).
    if rightStart <= #controls then
        local prevLeft = controls[rightStart]:getX()
        for i = rightStart + 1, #controls do
            local c = controls[i]
            c:setX(prevLeft - c:getWidth() - 1)
            prevLeft = c:getX()
        end
    end
end

-- A controlsUI do loot ancora os botões "displayToRight" (Turn On, Settings,
-- Light Fire, Add Fuel, etc.) na largura do PANE inteiro. Como a controlsUI
-- agora é filha do pane com a largura da grid ativa, ancoramos esses botões
-- na largura da PRÓPRIA controlsUI (a grid), não no canto do painel.
-- ATENÇÃO: este override TEM que ficar em nível de módulo (fora do update)!
-- Se ficar dentro do update, ele re-captura `arrange` e re-embrulha a função a
-- cada frame → recursão infinita → stack overflow (crash da UI inteira).
GridInventory_ControlsArrangeInstalled = GridInventory_ControlsArrangeInstalled or false
if not GridInventory_ControlsArrangeInstalled and ISLootWindowContainerControls then
    GridInventory_ControlsArrangeInstalled = true
    local og_lootControlsArrange = ISLootWindowContainerControls.arrange
    function ISLootWindowContainerControls:arrange()
        local lootWin = self.lootWindow
        local pane = lootWin and lootWin.inventoryPane
        local savedWidth = pane and pane.width
        if pane then
            -- Sincroniza a largura da controlsUI com a grid ativa ANTES do
            -- vanilla posicionar os botões: evita o flicker onde o Turn On/
            -- Settings nasce ancorado no canto direito (largura do pane) e é
            -- puxado pra dentro da grid no frame seguinte.
            if pane.gridContainerUis then
                local activeInv = pane.inventory
                for _, g in ipairs(pane.gridContainerUis) do
                    if not g.isOverflow and g.inventoryContainer == activeInv then
                        local w = g:getWidth() - (CONTROLS_PAD * 2)
                        if self.width ~= w then
                            self:setWidth(w)
                        end
                        break
                    end
                end
            end
            pane.width = self.width
        end
        og_lootControlsArrange(self)
        if pane then
            pane.width = savedWidth
        end
        -- Compacta os botões com gap de 1px (vanilla usa 5px)
        gridInv_compactControls(self)
    end
end

-- Mesma compactação (1px) para a controlsUI do PAINEL DO JOGADOR
-- (ISInventoryWindowContainerControls: Take All/Transfer All/etc.).
GridInventory_InvControlsArrangeInstalled = GridInventory_InvControlsArrangeInstalled or false
if not GridInventory_InvControlsArrangeInstalled and ISInventoryWindowContainerControls then
    GridInventory_InvControlsArrangeInstalled = true
    local og_invControlsArrange = ISInventoryWindowContainerControls.arrange
    function ISInventoryWindowContainerControls:arrange()
        og_invControlsArrange(self)
        gridInv_compactControls(self)
    end
end

-- Substitui os botões de TEXTO do rodapé (Take All / Transfer All / Move To
-- Floor) por ÍCONES (common/media/UI/*.png). O vanilla continua posicionando
-- tudo no `arrange`; trocamos só o controle que cada handler cria: em vez de
-- `getButtonControl("Take All")` usamos o ícone compacto (altura = fonte,
-- largura = proporção do ícone) com tooltip mantendo o rótulo. Overrides em
-- nível de módulo = executados UMA vez no load, sem closure/wrapper (idempotente).
-- Se a textura não carregar (ex.: caminho errado), cai de volta pro texto.
local function GridInventory_iconButtonControl(handler, imagePath, tooltipText)
    if getTexture(imagePath) == nil then
        handler.control = handler:getButtonControl(tooltipText)
    else
        handler.control = handler:getImageButtonControl(imagePath)
        handler.control:setTooltip(tooltipText)
    end
    return handler.control
end

if ISLootWindowObjectControlHandler_TakeAll then
    function ISLootWindowObjectControlHandler_TakeAll:getControl()
        return GridInventory_iconButtonControl(self, "media/UI/TakeAll.png", getText("IGUI_invpage_Loot_all"))
    end
end
if ISLootWindowFloorControlHandler_TakeAll then
    function ISLootWindowFloorControlHandler_TakeAll:getControl()
        return GridInventory_iconButtonControl(self, "media/UI/TakeAll.png", getText("IGUI_invpage_Loot_all"))
    end
end
if ISLootWindowObjectControlHandler_MoveToFloor then
    function ISLootWindowObjectControlHandler_MoveToFloor:getControl()
        return GridInventory_iconButtonControl(self, "media/UI/MoveToFloor.png", getText("ContextMenu_MoveToFloor"))
    end
end
if ISInventoryWindowControlHandler_TransferAll then
    function ISInventoryWindowControlHandler_TransferAll:getControl()
        return GridInventory_iconButtonControl(self, "media/UI/TransferAll.png", getText("IGUI_invpage_Transfer_all"))
    end
end

-- Hook para mostrar/esconder os painéis acoplados (PaperDoll + Loot juntos).
-- No FULLSCREEN os painéis são um conjunto dockado: abrir/fechar um abre/fecha
-- todos (inv ↔ loot ↔ paperdoll). No modo RESIZE (fullscreen desligado) cada
-- painel tem seu próprio controle: o inv abre/fecha só ele + paperdoll (que é
-- parte da janela de inventário e não tem botão próprio), e o loot só ele mesmo.
local og_setVisible = ISInventoryPage.setVisible
function ISInventoryPage:setVisible(visible)
    og_setVisible(self, visible)
    
    if visible then
        self:bringToTop()
    end
    
    -- Floating grids: ao fechar o inventário, fecha as janelas não-pinadas.
    if not visible and GridInventory_closeFloatingBags then
        GridInventory_closeFloatingBags(self.player)
    end
    
    local synced = GridModOptions.isFullscreenPanel()
    
    if self.onCharacter then
        local paperDoll = GridInventory_PaperDollWindow[self.player]
        if paperDoll then
            paperDoll:setVisible(visible)
            if visible then paperDoll:bringToTop() end
        end
        -- Loot só acompanha o inv no fullscreen (painéis dockados).
        if synced then
            local lootPage = getPlayerLoot(self.player)
            if lootPage then
                if lootPage:getIsVisible() ~= visible then
                    lootPage:setVisible(visible)
                end
                if visible then lootPage:bringToTop() end
            end
        end
    else
        -- Inv (e paperdoll) só acompanham o loot no fullscreen.
        if synced then
            local invPage = getPlayerInventory(self.player)
            if invPage then
                if invPage:getIsVisible() ~= visible then
                    invPage:setVisible(visible)
                end
                if visible then invPage:bringToTop() end
            end
        end
    end

    -- Floating grids (pinadas) por CIMA dos painéis ao abrir: a abertura do
    -- inventário/paperdoll/loot os traz pra frente; sem isso a janela flutuante
    -- fica renderizada ATRÁS depois que o painel é aberto de novo.
    -- (Roda por último, DEPOIS de todos os bringToTop dos painéis acima.)
    if visible and GridInventory_raiseFloating then
        GridInventory_raiseFloating(self.player)
    end
end

local og_pagePrerender = ISInventoryPage.prerender
function ISInventoryPage:prerender()
    local oldTitle = self.title
    
    -- No modo fullscreen ocultamos APENAS o título para que a classe pai não
    -- desenhe o nome do container; no modo resize o título nativo é restaurado
    -- (só o PaperDoll ficaria com o nome "Equipment", o que fica estranho).
    if GridModOptions.isFullscreenPanel() then
        self.title = ""
    end
    
    og_pagePrerender(self)
    
    self.title = oldTitle
    
    -- Quando colapsado (modo resize, pin destravado) desenhamos só a titlebar:
    -- o fundo escuro e a coluna de mochilas não são desenhados pra não sobrar
    -- "fantasma" do corpo do painel.
    local collapsed = self.isCollapsed
    local w = self:getWidth()
    local h = self:getHeight()
    local titleH = self:titleBarHeight()
    
    if not collapsed then
        -- Desenha um fundo sólido escuro (estilo Tarkov/Zomboid) em TODO o painel!
        -- Reduzi a opacidade de 0.85 para 0.65 para que o jogador consiga ver os zumbis!
        self:drawRect(0, titleH, w, h - titleH, 0.65, 0.08, 0.08, 0.08)
        self:drawRectBorder(0, titleH, w, h - titleH, 0.5, 0.5, 0.5, 0.5)
    end
    
    -- (Bordas dos botões suspensas a pedido do usuário devido a spam de erros no console)
    
    -- Restaura a borda bonitinha exclusiva da coluna de mochilas
    -- E também mantemos um fundo mais opaco (0.85) só pra essa coluna,
    -- garantindo que os botões não fiquem confusos com o chão!
    if self.containerButtonPanel and not collapsed then
        local bx = self.containerButtonPanel:getX()
        local by = self.containerButtonPanel:getY()
        local bw = self.containerButtonPanel:getWidth()
        local bh = self.containerButtonPanel:getHeight()
        
        -- Fundo mais forte pra coluna das mochilas
        self:drawRect(bx, by, bw, bh, 0.85, 0.08, 0.08, 0.08)
        self:drawRectBorder(bx, by, bw, bh, 0.5, 0.5, 0.5, 0.5)
    end
end

-- Hook no render: suprime a barra de status e a borda fantasma da controlsUI
-- que o vanilla desenhava no rodapé (agora a controlsUI vive dentro do pane,
-- no grid ativo). Redesenha apenas a borda externa do painel.
local og_pageRender = ISInventoryPage.render
function ISInventoryPage:render()
    local ogDRB = self.drawRectBorder
    local ogDTS = self.drawTextureScaled
    self.drawRectBorder = function() end
    self.drawTextureScaled = function() end
    og_pageRender(self)
    self.drawRectBorder = ogDRB
    self.drawTextureScaled = ogDTS
    -- Quando colapsado (modo resize, pin destravado) só a titlebar aparece:
    -- a borda externa acompanha a altura visível pra não sobrar um retângulo
    -- "fantasma" do corpo do painel.
    local borderH = self:getHeight()
    if self.isCollapsed then
        borderH = self:titleBarHeight()
    end
    self:drawRectBorder(0, 0, self:getWidth(), borderH,
        self.borderColor.a, self.borderColor.r, self.borderColor.g, self.borderColor.b)
    -- Modo resize: redesenha o grip de redimensionar (o vanilla o desenha via
    -- drawTextureScaled, que suprimimos acima no og_pageRender).
    if not GridModOptions.isFullscreenPanel() and not self.isCollapsed and self.resizeimage then
        local rh = (BUTTON_HGT or 34) / 2 + 2
        self:drawTextureScaled(self.resizeimage, self:getWidth() - rh + 1, self:getHeight() - rh + 1, rh - 2, rh - 2, 1, 1, 1, 1)
    end
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

-- Movimento da janela: DESTRUÍDO no fullscreen (painel fixo) e RESTAURADO no
-- modo resize (painel nativo). Salvamos o onMouseDown vanilla (que seta
-- moving=true + setCapture(true)) e só o chamamos quando não estamos fullscreen.
local og_pageMouseDown = ISInventoryPage.onMouseDown
function ISInventoryPage:onMouseDown(x, y)
    if not self:getIsVisible() then return end
    -- COLAPSADO: só a titlebar é interativa. O clique no corpo do painel não
    -- pode nullifyAiming nem propagar pro pane/grids — senão clicar "através"
    -- do painel colapsado faz o jogador parar de mirar.
    if self.isCollapsed then return end
    -- Z-INDEX: qualquer clique no painel o traz pra frente; re-sobemos a janela
    -- flutuante junto (método do InvTetris — sem flicker de bringToTop por frame).
    if GridInventory_raiseFloating then
        GridInventory_raiseFloating(self.player)
    end
    -- Modo resize: o vanilla seta moving=true + setCapture(true), então o drag
    -- pela titlebar move a janela (e continua fora dos limites via
    -- onMouseMoveOutside). No fullscreen o update() fixa as posições, então o
    -- painel não pode ser arrastado.
    if not GridModOptions.isFullscreenPanel() and og_pageMouseDown then
        return og_pageMouseDown(self, x, y)
    end
    getSpecificPlayer(self.player):nullifyAiming()
end

-- Z-INDEX: quando o painel (inventário OU loot) é trazido pra frente por
-- QUALQUER caminho (abrir, selecionar container, etc.), a janela flutuante é
-- re-sobida junto. É o mesmo mecanismo do InvTetris (keepChildWindowsOnTop).
local og_pageBringToTop = ISInventoryPage.bringToTop
function ISInventoryPage:bringToTop()
    og_pageBringToTop(self)
    if GridInventory_raiseFloating then
        GridInventory_raiseFloating(self.player)
    end
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
