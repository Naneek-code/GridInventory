require "ISUI/ISInventoryPage"
local PaperDollWindow = require("UI/PaperDoll/PaperDollWindow")
local GlobalDragRender = require("UI/GridRender/GlobalDragRender")
local GridModOptions = require("System/GridModOptions")
local GridInventory_Search = require("System/GridInventory_Search")
local GridJoypad = require("System/GridJoypad")

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
        -- Destrói o PaperDoll anterior (se existir) antes de criar um novo.
        -- Quando o vanilla recria as janelas (joypad connect, resolution change),
        -- createChildren roda de novo e o PaperDoll antigo ficaria como "fantasma"
        -- na UIManager sem referência válida pro inv destruído.
        local oldPD = GridInventory_PaperDollWindow[self.player]
        if oldPD then
            oldPD:removeFromUIManager()
            GridInventory_PaperDollWindow[self.player] = nil
        end

        -- Largura do PaperDoll acompanha o UI Scale (slots laterais maiores).
        local uiScale = GridInventory_uiScale or 100
        local scale = uiScale / 100
        local paperDollWidth = math.floor(350 * scale)
        
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
    -- Roda o Zomboid primeiro!
    og_update(self)

    -- OTIMIZAÇÃO DE FPS: o UIManager chama update() em TODO elemento todo
    -- frame, mesmo os invisíveis. O vanilla ISInventoryPage:update já faz
    -- early-return quando invisível, mas o nosso corpo (layout de grids,
    -- setWidth/X/Y/Height, etc — tudo JNI) rodava mesmo com o inventário
    -- FECHADO. Pulamos TUDO aqui (inclusive o coalesce — o dirty flag fica
    -- pendente e roda quando o painel reabrir, que é quando importa).
    if not self:getIsVisible() then return end

    if GridInventory_Profiler then GridInventory_Profiler.count("pageUpdate") end

    -- Marca o início do frame pro cache de busca (Tarkov) UMA vez por frame
    -- (não por grid): needsSearch / isItemHidden / countHiddenStacks
    -- compartilham UMA varredura do container por frame em vez de re-iterar os
    -- itens a cada consulta do render E em vez de G vezes (uma por grid) como
    -- acontecia quando cada GridRender:update chamava beginFrame().
    GridInventory_Search.beginFrame()

    -- Joypad: só o pollNav gerencia o modo navegação do bumper segurado (o
    -- update do painel focado cuida do ciclo). O analógico NÃO move o cursor.
    if JoypadState and JoypadState.players and JoypadState.players[self.player + 1] then
        GridJoypad.pollNav(self.player, self)
        -- Resolve tap vs hold do A sobre pilha (peel de 1 vs pilha inteira).
        GridJoypad.pollA(self.player, self)
    end

    -- Coalesce do onInventoryUpdate: o refreshContainer (remap de todos os
    -- containers) roda no maximo 1x por frame e apenas com o painel visivel.
    local pane = self.inventoryPane
    if pane and pane.gridRefreshDirty then
        pane.gridRefreshDirty = nil
        if pane:getIsVisible() then
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
    -- Largura do PaperDoll acompanha o UI Scale (senão os slots laterais
    -- maiores estouram a largura reservada).
    local uiScale = GridInventory_uiScale or 100
    local paperDollW = math.floor(350 * (uiScale / 100))

    -- Mod Option "Fullscreen Panel": ligada (padrão) = o painel ocupa metade
    -- da tela e NÃO pode ser redimensionado. Desligada = o painel volta ao
    -- comportamento nativo (resize habilitado, tamanho do usuário respeitado).
    local isFullscreen = GridModOptions.isFullscreenPanel()

    local panelW
    if isFullscreen then
        -- Base: metade da tela (descontando o PaperDoll). Com UI Scale alto, o
        -- grid interno pode exigir MAIS largura que a metade — expandimos até
        -- caber o grid ativo, limitado à largura máxima disponível na tela.
        panelW = (screenW - paperDollW) / 2
        local maxW = screenW - paperDollW
        local gridW = 0
        if self.inventoryPane and self.inventoryPane.gridContainerUis then
            for _, g in ipairs(self.inventoryPane.gridContainerUis) do
                if not g.isOverflow then
                    gridW = math.max(gridW, g:getWidth())
                end
            end
        end
        if gridW > 0 then
            local needed = gridW + self.buttonSize
            if needed > panelW then
                panelW = math.min(needed, maxW)
            end
        end
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
            self:setX(GridModOptions.isPaperDollLeft() and paperDollW or 0)
        end
        
        -- Inventário do Jogador: Grid na ESQUERDA (borda), Mochilas na DIREITA (centro)
        if self.containerButtonPanel then
            local titleH = self:titleBarHeight()
            local resizeH = self.resizeWidget and self.resizeWidget.height or 0
            self.containerButtonPanel:setX(panelW - self.buttonSize)
            self.containerButtonPanel:setHeight(self.height - titleH - resizeH)
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
            local titleH = self:titleBarHeight()
            local resizeH = self.resizeWidget and self.resizeWidget.height or 0
            self.containerButtonPanel:setX(0)
            self.containerButtonPanel:setHeight(self.height - titleH - resizeH)
        end
        if self.inventoryPane then
            self.inventoryPane:setX(self.buttonSize)
            self.inventoryPane:setWidth(self.width - self.buttonSize)
        end
    end
    
    -- (O autor original do mod movia os botões da titlebar. A pedido do usuário,
    -- foi removido para restaurar o comportamento 100% nativo)
    if self.infoButton then
        self.infoButton:setVisible(false)
    end
    if isFullscreen then
        if self.pinButton then self.pinButton:setVisible(false) end
        if self.collapseButton then self.collapseButton:setVisible(false) end
    else
        if self.pinButton then self.pinButton:setVisible(not self.pin) end
        if self.collapseButton then self.collapseButton:setVisible(self.pin) end
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
    --
    -- FLICKER FIX (timing): o flexbox do ISInventoryPane:prerender reposiciona
    -- os grids TODO frame (baseY) — e o controlsUI precisa seguir ESSE mesmo
    -- valor no MESMO frame. Posicionar no update (como antes) usava o getY() do
    -- frame ANTERIOR: quando o grid crescia pro footer ou o flexbox quebrava
    -- coluna, a barra ficava 1 frame ancorada no Y velho e "pulava" pro lugar
    -- certo no frame seguinte = a flickada do loot. Por isso o posicionamento
    -- foi movido pro prerender do pane (gridInv_positionControlsUI), usando o
    -- baseY/baseX recém-calculados. Aqui no update só garantimos o re-parent
    -- e a reserva de altura do grid (que o flexbox lê no mesmo frame).
    if self.controlsUI and self.inventoryPane then
        self.controlsUI:setAnchors(false)
        -- Re-parenta pro pane (uma vez; addChild já desanexa da página)
        if self.controlsUI.parent ~= self.inventoryPane then
            self.inventoryPane:addChild(self.controlsUI)
        end
        -- Reserva o rodapé no grid ativo; restaura a altura dos demais grids.
        -- (O posicionamento em si acontece no prerender do pane, depois do
        -- flexbox calcular os baseY — gridInv_positionControlsUI.)
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
        -- No CONTROLE não dá pra clicar nos botões (Take All etc.) — não
        -- reserva o rodapé e o grid mantém a altura de conteúdo (sem "crescer"
        -- como se os botões existissem).
        local usingJoypad = JoypadState and JoypadState.players
            and JoypadState.players[self.player + 1] ~= nil
        local hasButtons = (gridUi and self.controlsUI.controls and #self.controlsUI.controls > 0)
            and not usingJoypad
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
        if not hasButtons then
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
        -- Margem entre o grupo ESQUERDO e o grupo DIREITO (mesma linha): o
        -- vanilla usa UI_MARGIN=5 entre todos os botões. Como compactamos cada
        -- grupo com gap 1px, o vão entre os dois grupos também deve ser 1px —
        -- senão sobra um "buraco" de 5px exatamente entre os botões
        -- "Transfer to displayed" e "Transfer to nearby".
        local lastLeft = nil
        for i = rightStart - 1, 1, -1 do
            local c = controls[i]
            if c:getY() == controls[rightStart]:getY() then
                lastLeft = c
                break
            end
        end
        if lastLeft then
            controls[rightStart]:setX(lastLeft:getRight() + 1)
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
--
-- FLICKER FIX (mesmo do painel do jogador): o vanilla `arrange()` remove TODOS
-- os controles e re-adiciona A CADA FRAME. Aqui calculamos a assinatura dos
-- handlers VISÍVEIS (objeto + floor) e só fazemos o rebuild vanilla quando ela
-- muda — caso contrário os botões ficam na árvore e só re-compatamos o layout.
GridInventory_ControlsArrangeInstalled = GridInventory_ControlsArrangeInstalled or false
if not GridInventory_ControlsArrangeInstalled and ISLootWindowContainerControls then
    GridInventory_ControlsArrangeInstalled = true
    local og_lootControlsArrange = ISLootWindowContainerControls.arrange

    -- Retorna os handlers visíveis (objeto OU floor, igual ao vanilla).
    local function lootVisibleHandlers(self)
        local container = self:getDisplayedContainer()
        local object = self:getDisplayedObject()
        local out = {}
        if object then
            for _, handlerClass in ipairs(ISLootWindowContainerControls_HandlerList) do
                local handler = self:checkHandler(handlerClass, object, container)
                if handler:shouldBeVisible() then
                    table.insert(out, handler)
                end
            end
        elseif container and container:getType() == "floor" then
            for _, handlerClass in ipairs(ISLootWindowContainerControls_FloorHandlerList) do
                local handler = self:checkHandler(handlerClass, nil, container)
                if handler:shouldBeVisible() then
                    table.insert(out, handler)
                end
            end
        end
        return out
    end

    function ISLootWindowContainerControls:arrange()
        local desired = lootVisibleHandlers(self)
        -- Assinatura SÓ dos handlers visíveis (NÃO inclui o width): o width é
        -- re-sincronizado todo frame (grid ativa) e não muda o CONJUNTO de
        -- botões — incluir ele na assinatura fazia o rebuild rodar 2x seguidas
        -- (sig salvo com width antigo, sig novo com width syncado) e o vanilla
        -- arrange derrubava/recriava os botões a cada vez → flicker no loot.
        local sig = ""
        for i, h in ipairs(desired) do
            sig = sig .. tostring(h)
            if i < #desired then sig = sig .. ";" end
        end
        -- Sincroniza a largura da controlsUI com a grid ativa ANTES de decidir
        -- rebuild ou não (os botões displayToRight ancoram na largura atual).
        local lootWin = self.lootWindow
        local pane = lootWin and lootWin.inventoryPane
        local savedWidth = pane and pane.width
        if pane then
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
        if self._gridInvArrSig == sig then
            -- Nada mudou: mantém os controles na árvore e só re-flui o layout
            -- (com a largura já sincronizada acima).
            gridInv_compactControls(self)
            if pane then pane.width = savedWidth end
            return
        end
        self._gridInvArrSig = sig
        -- REPOSITION FIX (loot): o vanilla arrange() ancora a controlsUI no
        -- rodapé do PANE — setX(0), setY(resizeWidget.y - height) e
        -- setWidth(lootWindow:getWidth()) (largura do painel inteiro). No loot
        -- o mod re-parenta a barra pra dentro da grid e controla X/Y/Width no
        -- update. Deixar o vanilla setar isso aqui jogava a barra pro canto
        -- errado por alguns frames a cada troca de container (o "pulo" do loot).
        -- Salvamos X/Y/Width ANTES e restauramos DEPOIS do vanilla: ele só
        -- serve pra (re)montar os botões, o posicionamento é 100% nosso.
        local savedX = self.x
        local savedY = self.y
        local savedW = self.width
        og_lootControlsArrange(self)
        if self.x ~= savedX then self:setX(savedX) end
        if self.y ~= savedY then self:setY(savedY) end
        if self.width ~= savedW then self:setWidth(savedW) end
        if pane then
            pane.width = savedWidth
        end
        -- Compacta os botões com gap de 1px (vanilla usa 5px)
        gridInv_compactControls(self)
    end
end

-- Mesma compactação (1px) para a controlsUI do PAINEL DO JOGADOR
-- (ISInventoryWindowContainerControls: Take All/Transfer All/etc.).
--
-- FLICKER FIX: o vanilla `arrange()` remove TODOS os controles (setVisible
-- false + removeChild) e re-adiciona, e isso roda A CADA FRAME (chamado do
-- ISInventoryPage:update). Com o re-parent da controlsUI no pane, cada frame
-- a árvore Java dos botões é derrubada e reconstruída → flicker dos botões.
-- Aqui calculamos a "assinatura" dos handlers VISÍVEIS: se nada mudou, pulamos
-- o rebuild inteiro (os controles continuam na árvore, só re-compatamos o
-- layout). Só quando um botão aparece/some (ex.: container esvaziou, trocou
-- de bag) fazemos o rebuild vanilla.
GridInventory_InvControlsArrangeInstalled = GridInventory_InvControlsArrangeInstalled or false
if not GridInventory_InvControlsArrangeInstalled and ISInventoryWindowContainerControls then
    GridInventory_InvControlsArrangeInstalled = true
    local og_invControlsArrange = ISInventoryWindowContainerControls.arrange

    -- Retorna os handlers que deveriam ficar visíveis (na ordem do HandlerList).
    local function invVisibleHandlers(self)
        local container = self:getDisplayedContainer()
        local lootWindow = getPlayerLoot(self.inventoryWindow.player)
        if not lootWindow or not lootWindow.inventoryPane.inventory then
            container = nil
        end
        local out = {}
        if container ~= nil then
            for _, handlerClass in ipairs(ISInventoryWindowContainerControls_HandlerList) do
                local handler = self:checkHandler(handlerClass, container)
                if handler:shouldBeVisible() then
                    table.insert(out, handler)
                end
            end
        end
        return out
    end

    function ISInventoryWindowContainerControls:arrange()
        local desired = invVisibleHandlers(self)
        -- Assinatura SÓ dos handlers visíveis (NÃO inclui o width): o width da
        -- controlsUI é controlado pelo update do mod e não muda o conjunto de
        -- botões — incluir ele na assinatura causava rebuild duplo (sig salvo
        -- com width antigo, sig novo com width syncado) = flicker.
        local sig = ""
        for i, h in ipairs(desired) do
            sig = sig .. tostring(h)
            if i < #desired then sig = sig .. ";" end
        end
        if self._gridInvArrSig == sig then
            -- Nada mudou: mantém os controles na árvore e só re-flui o layout.
            gridInv_compactControls(self)
            return
        end
        self._gridInvArrSig = sig
        -- REPOSITION FIX (mesmo do loot): o vanilla arrange ancora a controlsUI
        -- no rodapé do painel (setX(0)/setY(resizeWidget.y - height)/
        -- setWidth(inventoryWindow:getWidth())). O mod controla X/Y/Width no
        -- update (barra dentro da grid ativa). Restauramos pra evitar o pulo
        -- quando o sig muda (ex.: troca de container no inv também).
        local savedX = self.x
        local savedY = self.y
        local savedW = self.width
        og_invControlsArrange(self)
        if self.x ~= savedX then self:setX(savedX) end
        if self.y ~= savedY then self:setY(savedY) end
        if self.width ~= savedW then self:setWidth(savedW) end
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
-- O botão é configurado UMA vez por handler (cache `handler._gridInvIcon`):
-- o vanilla arrange() chama getControl() a cada rebuild, e o
-- getImageButtonControl re-set image/forceImageSize/width/height em cada
-- chamada — churn desnecessário que contribui pro flicker.
local function GridInventory_iconButtonControl(handler, imagePath, tooltipText)
    if handler._gridInvIconDone then
        return handler.control
    end
    handler._gridInvIconDone = true
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

    -- Fechou o inventário: cancela o drag de joypad (o item preso no cursor
    -- volta pra origem — ele nunca saiu do container durante o drag).
    if not visible and GridJoypad.isDragging(self.player) then
        GridJoypad.cancelDrag(self.player)
    end

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
    local opacity = GridInventory_PanelOpacity or 0.9
    -- Oculte o fundo nativo ANTES de chamar o vanilla para impedir que ele
    -- desenhe um fundo repetido no lado direito (bug do Zomboid vanilla)
    -- que causava a coluna do Inv (direita) ficar mais escura que a do Loot (esquerda)
    local ogAlpha = self.backgroundColor.a
    if GridInventory_PanelOpacity ~= nil then
        self.backgroundColor.a = 0
    end
    
    local oldTitle = self.title
    
    if GridModOptions.isFullscreenPanel() then
        self.title = ""
    end
    
    og_pagePrerender(self)
    
    self.title = oldTitle
    
    -- Sobrescreve o fundo "branco/cinza" (0.7, 0.7, 0.7) que o Vanilla aplica na bolsa ativa
    if not self.blinkContainer and self.backpacks then
        for _, btn in ipairs(self.backpacks) do
            if btn.backgroundColor then
                if btn.inventory == self.inventoryPane.inventory then
                    btn.backgroundColor.r = 1.0
                    btn.backgroundColor.g = 0.9
                    btn.backgroundColor.b = 0.3
                    btn.backgroundColor.a = 0.35
                else
                    btn.backgroundColor.a = 0
                end
            end
        end
    end
    
    -- Restaura o alpha original para manter o estado consistente no objeto (caso algo mais precise)
    self.backgroundColor.a = ogAlpha
    
    local collapsed = self.isCollapsed
    local w = self:getWidth()
    local h = self:getHeight()
    local titleH = self:titleBarHeight()
    
    if not collapsed then
        -- Fundo unificado do painel usando as exatas cores que o PaperDoll usa (a base do Zomboid).
        -- Como desativamos o desenho duplo do vanilla (self.backgroundColor.a = 0 acima),
        -- este é o ÚNICO background renderizado no painel, garantindo paridade perfeita 1:1.
        self:drawRect(0, titleH, w, h - titleH, opacity, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b)
    end
    
    -- A coluna de mochilas não precisa de um segundo fundo hardcoded agora! 
    -- Como o fundo unificado acima cobre de X=0 a X=Width, ele já preenche a área da coluna
    -- tanto se ela estiver na direita (Inv) quanto na esquerda (Loot). 
    -- Mas se a coluna VAZA para fora ou quisermos a bordinha bonitinha de volta:
    if self.containerButtonPanel and not collapsed then
        local bx = self.containerButtonPanel:getX()
        local by = self.containerButtonPanel:getY()
        local bw = self.containerButtonPanel:getWidth()
        local bh = self.containerButtonPanel:getHeight()
        
        -- Adiciona uma camada extra de preto escalando com a opacidade para dar profundidade
        local extraAlpha = opacity * 0.5
        self:drawRect(bx, by, bw, bh, extraAlpha, 0.15, 0.15, 0.15)
        
        local borderAlpha = opacity > 0 and 0.5 or 0
        self:drawRectBorder(bx, by, bw, bh, borderAlpha, 0.5, 0.5, 0.5)
    end
end

-- Hook no render: suprime a barra de status e a borda fantasma da controlsUI
-- que o vanilla desenhava no rodapé (agora a controlsUI vive dentro do pane,
-- no grid ativo). Redesenha apenas a borda externa do painel.
local og_pageRender = ISInventoryPage.render
-- Closure única compartilhada: não alocar uma nova closure a cada frame do
-- render (mesmo padrão do ISInventoryPane:render). Suprime o drawRectBorder/
-- drawTextureScaled do vanilla durante o og_pageRender.
local function noop() end
function ISInventoryPage:render()
    local ogDRB = self.drawRectBorder
    local ogDTS = self.drawTextureScaled
    self.drawRectBorder = noop
    self.drawTextureScaled = noop
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
    if not self.isCollapsed then
        local rwH = self.resizeWidget and self.resizeWidget.height or 0
        if rwH > 0 then
            local footerY = self:getHeight() - rwH
            local opacity = GridInventory_PanelOpacity or 0.9
            local extraAlpha = opacity * 0.4
            local borderAlpha = opacity > 0 and 0.5 or 0
            
            -- Desenha o fundo escurecido pro rodapé fantasma
            self:drawRect(0, footerY, self:getWidth(), rwH, extraAlpha, 0.15, 0.15, 0.15)
            -- Borda superior do rodapé (separando do grid)
            self:drawRectBorder(0, footerY, self:getWidth(), rwH, borderAlpha, 0.5, 0.5, 0.5)
        end
        
        -- Grip de redimensionamento
        if not GridModOptions.isFullscreenPanel() and self.resizeimage then
            local rh = rwH
            if rh > 0 then
                self:drawTextureScaled(self.resizeimage, self:getWidth() - rh + 1, self:getHeight() - rh + 1, rh - 2, rh - 2, 1, 1, 1, 1)
            end
        end
    end
    -- Overlay do modo navegação (RB segurado): o Lua render da página roda
    -- DEPOIS dos filhos (verificamos no bytecode do UIElement.render), então
    -- os ícones D-pad e o destaque ficam por cima dos grids/pane.
    GridJoypad.renderNavOverlay(self)
    
    -- Drag & Drop de containers (mochilas)
    if self.GridInventory_DragContainer then
        local panel = self.containerButtonPanel
        if panel then
            local mouseY = panel:getMouseY()
            
            if not self.GridInventory_IsDragging then
                local startY = self.GridInventory_DragStartY or 0
                if math.abs(mouseY - startY) > 5 then
                    self.GridInventory_IsDragging = true
                end
            end
            
            if not isMouseButtonDown(0) then
                local dragBtn = self.GridInventory_DragContainer
                local wasDragging = self.GridInventory_IsDragging
                
                self.GridInventory_DragContainer = nil
                self.GridInventory_IsDragging = false
                
                if wasDragging and dragBtn.parent == panel then
                    local buttonSize = self.buttonSize or 32
                    local rawIndex = math.floor(mouseY / buttonSize) + 1
                    if rawIndex < 2 then rawIndex = 2 end
                    
                    local tempList = {}
                    for i = 2, #self.backpacks do
                        if self.backpacks[i] ~= dragBtn then
                            table.insert(tempList, self.backpacks[i])
                        end
                    end
                    table.sort(tempList, function(a, b)
                        return (a.y or 0) < (b.y or 0)
                    end)
                    
                    local insertIndex = rawIndex - 1
                    if insertIndex > #tempList + 1 then insertIndex = #tempList + 1 end
                    if insertIndex < 1 then insertIndex = 1 end
                    
                    table.insert(tempList, insertIndex, dragBtn)
                    
                    local str = ""
                    for i, b in ipairs(tempList) do
                        local id = ""
                        if b.inventory then
                            local item = b.inventory:getContainingItem()
                            if item then
                                local iID = item:getID()
                                if iID and iID ~= -1 and iID ~= 0 then
                                    id = tostring(iID)
                                else
                                    id = item:getFullType() or ""
                                end
                            else
                                id = b.name or ""
                            end
                        end
                        if id ~= "" then
                            str = str .. id .. ":" .. tostring(i) .. ","
                        end
                    end
                    
                    local modData = getSpecificPlayer(self.player):getModData()
                    modData.GridInventory_ContainerOrderStr = str
                    
                    self:refreshBackpacks()
                end
            elseif self.GridInventory_IsDragging then
                -- Desenhando a linha indicadora
                local buttonSize = self.buttonSize or 32
                local rawIndex = math.floor(mouseY / buttonSize)
                if rawIndex < 1 then rawIndex = 1 end
                if rawIndex > #self.backpacks then rawIndex = #self.backpacks end
                
                local yScroll = panel:getYScroll() or 0
                local lineY = panel:getY() + yScroll + (rawIndex * buttonSize)
                local lineX = panel:getX()
                local lineW = panel:getWidth()
                
                self:drawRect(lineX, lineY - 2, lineW, 4, 0.8, 1.0, 1.0, 0.0)
                self:drawRectBorder(lineX, lineY - 2, lineW, 4, 1.0, 0.0, 0.0, 0.0)
            end
        else
            if not isMouseButtonDown(0) then
                self.GridInventory_DragContainer = nil
                self.GridInventory_IsDragging = false
            end
        end
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
-- Sincroniza a navegação vanilla (Joypad LB/RB) com a ordem visual
local og_selectNextContainer = ISInventoryPage.selectNextContainer
function ISInventoryPage:selectNextContainer()
    if not self.backpacks or #self.backpacks == 0 then return end
    local originalOrder = {}
    for i, button in ipairs(self.backpacks) do originalOrder[i] = button end
    table.sort(self.backpacks, function(a, b) return (a.y or 0) < (b.y or 0) end)

    local currentIndex = self:getCurrentBackpackIndex()
    local unlockedIndex = self:nextUnlockedContainer(currentIndex, true)
    
    local selectedBtn = nil
    if unlockedIndex ~= -1 then selectedBtn = self.backpacks[unlockedIndex] end

    for i, button in ipairs(originalOrder) do self.backpacks[i] = button end

    if selectedBtn then
        for i, b in ipairs(self.backpacks) do
            if b == selectedBtn then
                self.backpackChoice = i
                break
            end
        end
        self:selectContainer(selectedBtn)
    end
end

local og_selectPrevContainer = ISInventoryPage.selectPrevContainer
function ISInventoryPage:selectPrevContainer()
    if not self.backpacks or #self.backpacks == 0 then return end
    local originalOrder = {}
    for i, button in ipairs(self.backpacks) do originalOrder[i] = button end
    table.sort(self.backpacks, function(a, b) return (a.y or 0) < (b.y or 0) end)

    local currentIndex = self:getCurrentBackpackIndex()
    local unlockedIndex = self:prevUnlockedContainer(currentIndex, true)
    
    local selectedBtn = nil
    if unlockedIndex ~= -1 then selectedBtn = self.backpacks[unlockedIndex] end

    for i, button in ipairs(originalOrder) do self.backpacks[i] = button end

    if selectedBtn then
        for i, b in ipairs(self.backpacks) do
            if b == selectedBtn then
                self.backpackChoice = i
                break
            end
        end
        self:selectContainer(selectedBtn)
    end
end

function ISInventoryPage:cycleContainer(del)
    if not self.backpacks or #self.backpacks == 0 then return true end

    -- Snapshot the original array order
    local originalOrder = {}
    for i, button in ipairs(self.backpacks) do
        originalOrder[i] = button
    end

    -- Temporarily sort by visual Y position so scrolling feels natural
    table.sort(self.backpacks, function(a, b)
        return (a.y or 0) < (b.y or 0)
    end)

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

    local selectedBtn = nil
    if unlockedIndex ~= -1 then
        selectedBtn = self.backpacks[unlockedIndex]
    end

    -- Restore the original array order IMMEDIATELY to prevent GridInventory hashes from breaking
    for i, button in ipairs(originalOrder) do
        self.backpacks[i] = button
    end

    if selectedBtn then
        local playerObj = getSpecificPlayer(self.player)
        if playerObj and playerObj:getJoypadBind() ~= -1 then
            for i, b in ipairs(self.backpacks) do
                if b == selectedBtn then
                    self.backpackChoice = i
                    break
                end
            end
        end
        self:selectContainer(selectedBtn)
    end
    return true
end

-- O auto-scroll + flash foi centralizado no prerender do ISInventoryPane
-- (ISInventoryPane_Hijack.lua): ele cobre abrir o loot, virar pra outro
-- container, clique na mochila e scroll do mouse, usando o baseY REAL do
-- flexbox (sem reimplementar o layout aqui, que ficava inconsistente com o
-- prerender). O selectContainer vanilla (chamado abaixo) já muda o
-- inventoryPane.inventory, e o prerender detecta a troca no próximo frame.

-- TROCA DE CONTAINER = REFRESH IMEDIATO DAS GRIDS:
-- O selectContainer vanilla muda inventoryPane.inventory na hora, mas o mod
-- só reconstrói os gridContainerUis quando gridRefreshDirty é setado (via
-- onInventoryUpdate/OnContainerUpdate/polling de 300ms). No loot, isso deixava
-- o controlsUI:arrange() rodando com o container NOVO mas as grids do ANTIGO
-- por vários frames: o width sync não achava a grid ativa e os botões
-- (Take All/Move To Floor) pulavam pra posição errada até o refresh nascer.
-- Interceptamos o selectContainer pra marcar o refresh imediatamente, então as
-- grids certas existem já no frame seguinte ao clique.
local og_pageSelectContainer = ISInventoryPage.selectContainer
function ISInventoryPage:selectContainer(button)
    og_pageSelectContainer(self, button)
    if self.inventoryPane and self.inventoryPane.gridRefreshDirty ~= nil then
        self.inventoryPane.gridRefreshDirty = true
    end
    -- Cursor do joypad acompanha o container ativo (mochila clicada, etc).
    GridJoypad.reanchorToActive(self.player, self)
end

local og_pageSetNewContainer = ISInventoryPage.setNewContainer
function ISInventoryPage:setNewContainer(inventory)
    og_pageSetNewContainer(self, inventory)
    if self.inventoryPane and self.inventoryPane.gridRefreshDirty ~= nil then
        self.inventoryPane.gridRefreshDirty = true
    end
    GridJoypad.reanchorToActive(self.player, self)
end

-- HEIGHT FIX (respirar do painel): o vanilla refreshBackpacks termina com
-- inventoryPane:setHeight(... - controlsUI.height) (linha 1896 do vanilla) —
-- desconto fantasma da barra de Take All que o mod moveu pra dentro do grid.
-- Isso encolhia o pane (e a coluna de bolsas acompanha) por 1 frame a cada
-- troca de container. Restauramos a altura cheia logo após o vanilla.
local og_pageRefreshBackpacks = ISInventoryPage.refreshBackpacks
function ISInventoryPage:refreshBackpacks()
    og_pageRefreshBackpacks(self)
    
    if self.backpacks then
        for _, btn in ipairs(self.backpacks) do
            btn.drawBorder = false
            btn.isBorderVisible = false
            btn.borderColor = {r=0, g=0, b=0, a=0} -- Força o alpha para 0 garantindo invisibilidade
            
            -- Troca o fundo cinza de hover pro amarelo do projeto
            btn.backgroundColorMouseOver = {r=1.0, g=0.9, b=0.3, a=0.35}
            btn.backgroundColorPressed = {r=1.0, g=0.9, b=0.3, a=0.15}
        end
    end
    
    if self.onCharacter and self.backpacks and #self.backpacks > 1 then
        local pObj = getSpecificPlayer(self.player)
        if pObj then
            local modData = pObj:getModData()
            if modData then
                local orderStr = modData.GridInventory_ContainerOrderStr or ""
                local order = {}
                for id, i in string.gmatch(orderStr, "([^:,]+):([^:,]+)") do
                    order[id] = tonumber(i)
                end
                
                local function getContainerId(btn)
                    if not btn.inventory then return "" end
                    local item = btn.inventory:getContainingItem()
                    if item then
                        local id = item:getID()
                        if id and id ~= -1 and id ~= 0 then
                            return tostring(id)
                        end
                        return item:getFullType() or ""
                    end
                    return btn.name or ""
                end
                
                local buttonsWithSort = {}
                for i, button in ipairs(self.backpacks) do
                    local isMain = (i == 1)
                    local id = getContainerId(button)
                    local priority = order[id]
                    
                    if isMain then
                        priority = -1
                    elseif not priority then
                        priority = i * 1000 -- vanilla fallback
                    end
                    
                    table.insert(buttonsWithSort, {
                        button = button,
                        priority = priority,
                        vanillaIndex = i
                    })
                end
                
                table.sort(buttonsWithSort, function(a, b)
                    if a.priority ~= b.priority then
                        return a.priority < b.priority
                    end
                    return a.vanillaIndex < b.vanillaIndex
                end)
                
                for index, data in ipairs(buttonsWithSort) do
                    local targetY = ((index - 1) * self.buttonSize) - 1
                    if data.button.y ~= targetY then
                        data.button:setY(targetY)
                    end
                end
            end
        end
    end

    if self.inventoryPane and self.resizeWidget then
        local resizeH = self.resizeWidget and self.resizeWidget.height or 0
        local fullH = self.height - self.inventoryPane.y - resizeH
        if self.inventoryPane.height ~= fullH then
            self.inventoryPane:setHeight(fullH)
        end
        if self.containerButtonPanel and self.containerButtonPanel:getHeight() ~= fullH then
            self.containerButtonPanel:setHeight(fullH)
        end
    end
end

-- COLLAPSE FIX (modo resize): o vanilla auto-colapsa o painel quando o mouse
-- SAI dele (onMouseMoveOutside incrementa collapseCounter) E instantaneamente
-- quando um clique (direito ou esquerdo) acontece FORA do painel
-- (onRightMouseDownOutside / onMouseDownOutside → collapseNow). No modo resize
-- o PaperDoll colapsa/expande JUNTO com o inv — então clicar/mexer no
-- PaperDoll (que fica ao lado) colapsava o inv junto imediatamente.
-- Aqui evitamos os DOIS caminhos enquanto:
--   * houver um context-menu aberto (interação ativa, ex.: clique direito num
--     slot do PaperDoll — o menu fica por cima e rouba o hit-test), OU
--   * o mouse estiver DENTRO DO RETÂNGULO do PaperDoll (posição absoluta, não
--     isMouseOver — o menu aberto rouba o hit-test do isMouseOver).

--- O mouse está "no inv" (PaperDoll ou context menu) e não deve colapsar?
---@return boolean
local function gridInv_mouseIsOnPaperDollOrMenu(self)
    if not (self.onCharacter and not GridModOptions.isFullscreenPanel()) then return false end
    -- Context-menu aberto (clique direito em slot/item): interação ativa.
    local ctx = getPlayerContextMenu and getPlayerContextMenu(self.player)
    if ctx and ctx:getIsVisible() then
        return true
    end
    -- Mouse dentro do retângulo do PaperDoll (extensão do inv no modo resize).
    local pd = GridInventory_PaperDollWindow and GridInventory_PaperDollWindow[self.player]
    if pd and pd:getIsVisible() then
        local mx = getMouseX()
        local my = getMouseY()
        local ax = pd:getAbsoluteX()
        local ay = pd:getAbsoluteY()
        local aw = pd:getWidth()
        local ah = pd:getHeight()
        if mx >= ax and mx <= ax + aw and my >= ay and my <= ay + ah then
            return true
        end
    end
    return false
end

local og_pageMouseMoveOutside = ISInventoryPage.onMouseMoveOutside
function ISInventoryPage:onMouseMoveOutside(dx, dy)
    if self.moving then
        self:setX(self.x + dx)
        self:setY(self.y + dy)
    end

    if gridInv_mouseIsOnPaperDollOrMenu(self) then
        self.collapseCounter = 0
        return
    end

    og_pageMouseMoveOutside(self, dx, dy)
end

-- Clique direito FORA do inv (ex.: no PaperDoll ou num slot dele): o vanilla
-- chama collapseNow() na hora — isso colapsava o inv (e o PaperDoll junto)
-- ao abrir o context menu de um slot. Bloqueamos quando o clique é no
-- PaperDoll / context menu.
local og_pageRightMouseDownOutside = ISInventoryPage.onRightMouseDownOutside
function ISInventoryPage:onRightMouseDownOutside(x, y)
    if gridInv_mouseIsOnPaperDollOrMenu(self) then
        return
    end
    og_pageRightMouseDownOutside(self, x, y)
end

-- Clique esquerdo FORA do inv: mesmo tratamento (evita colapsar ao clicar no
-- PaperDoll em modo resize).
local og_pageMouseDownOutside = ISInventoryPage.onMouseDownOutside
function ISInventoryPage:onMouseDownOutside(x, y)
    if gridInv_mouseIsOnPaperDollOrMenu(self) then
        return
    end
    og_pageMouseDownOutside(self, x, y)
end
-- ============================================================================
-- SUPORTE A CONTROLE (JOYPAD)
-- ============================================================================
-- O foco do joypad continua na ISInventoryPage (vanilla). Interceptamos os
-- métodos de joypad da página e roteamos pro GridJoypad, que mantém o cursor
-- virtual (col,row) sobre as grids do mod. A/D-pad/analógico navegam, e os
-- botões replicam o mapeamento vanilla:
--   A = contexto do item sob o cursor   X = pegar/transferir
--   B = abrir/selecionar mochila        Y = fechar inventário
--   LB/RB = trocar container (3 modos do vanilla)
-- Sempre que a ISInventoryPage perde o foco (ex.: menu de contexto aberto),
-- quem recebe os eventos é o menu (o B do menu devolve o foco pra cá).

local og_pageGainJoypadFocus = ISInventoryPage.onGainJoypadFocus
function ISInventoryPage:onGainJoypadFocus(joypadData)
    og_pageGainJoypadFocus(self, joypadData)
    GridJoypad.anchorOnFocus(self.player, self)
end

local og_pageJoypadDown = ISInventoryPage.onJoypadDown
function ISInventoryPage:onJoypadDown(button, joypadData)
    ISContextMenu.globalPlayerContext = self.player
    local playerObj = getSpecificPlayer(self.player)

    -- STACK PICKER aberto pelo controle: A tira o item destacado, B e Select
    -- (Back) fecham. O D-pad navega a lista (ver onJoypadDirUp/Down).
    if GridJoypad.isPickerActive(self.player) then
        if button == Joypad.AButton then
            GridJoypad.pickerTake(self.player)
        elseif button == Joypad.BButton or button == Joypad.Back then
            GridJoypad.closePicker(self.player)
        end
        return
    end

    -- A = pegar/soltar item (drag); no modo PaperDoll, A equipa o item
    -- arrastado no slot selecionado. B = contexto / cancelar drag, X =
    -- rotacionar (enquanto arrasta). No PaperDoll o cursor das grids fica
    -- oculto: os botões de grid ficam inertes (LB/RB saem do paperdoll; Y fecha
    -- o inventário).
    if button == Joypad.AButton then
        -- No PaperDoll, A equipa o item arrastado no slot (se arrastando).
        if GridJoypad.isPaperdollActive(self.player) then
            GridJoypad.pdActivate(self.player)
        else
            GridJoypad.grab(self.player, self)
        end
    elseif button == Joypad.BButton then
        if isPlayerDoingActionThatCanBeCancelled(playerObj) then
            stopDoingActionThatCanBeCancelled(playerObj)
            return
        end
        if GridJoypad.isPaperdollActive(self.player) then
            -- No PaperDoll, B cancela o drag (se arrastando); senão abre o menu.
            if GridJoypad.isDragging(self.player) then
                GridJoypad.cancelDrag(self.player)
            else
                GridJoypad.pdContext(self.player, self)
            end
        else
            GridJoypad.activateB(self.player, self)
        end
    elseif button == Joypad.XButton and not JoypadState.disableGrab then
        if GridJoypad.isPaperdollActive(self.player) then
            -- No PaperDoll, X roda o menu CÍCLICO do slot.
            GridJoypad.pdCycle(self.player)
        elseif GridJoypad.isDragging(self.player) then
            -- Com drag: rotaciona o item segurado.
            GridJoypad.rotate(self.player, self)
        else
            -- Sem drag: transferência RÁPIDA inv<->loot (comportamento vanilla).
            GridJoypad.quickTransfer(self.player, self)
        end
    elseif button == Joypad.YButton and not JoypadState.disableYInventory then
        setJoypadFocus(self.player, nil)
    elseif button == Joypad.Back then
        -- Select: abre o STACK PICKER da pilha sob o cursor (navegação D-pad).
        GridJoypad.openStackPicker(self.player, self)
    end

    -- LB/RB: no modo PaperDoll a saída é decidida no RELEASE (pollNav) — aqui
    -- não faz nada pro bumper. Fora dele, a ação (trocar painel / ciclar
    -- container) NÃO roda no aperto — só no SOLTAR, se foi um tap curto
    -- (<250ms). Segurar o bumper >=250ms ativa o modo NAVEGAÇÃO do painel dele
    -- (pollNav no update). LB+RB juntos (pollNav) entra no PaperDoll.
    if button == Joypad.LBumper then
        if not GridJoypad.isPaperdollActive(self.player) then
            GridJoypad.bumperDown(self.player, "LB")
        end
    end
    if button == Joypad.RBumper then
        if not GridJoypad.isPaperdollActive(self.player) then
            GridJoypad.bumperDown(self.player, "RB")
        end
    end
end

local og_pageJoypadDirUp = ISInventoryPage.onJoypadDirUp
function ISInventoryPage:onJoypadDirUp(joypadData)
    -- STACK PICKER do controle: D-pad navega a lista da janela.
    if GridJoypad.isPickerActive(self.player) then
        GridJoypad.pickerMove(self.player, -1)
        return
    end
    -- MODO PAPERDOLL (LB+RB): o D-pad navega os slots.
    if GridJoypad.isPaperdollActive(self.player) then
        GridJoypad.pdDir(self.player, 0, -1)
        return
    end
    -- MODO NAVEGAÇÃO (bumper segurado): o D-pad pula de grid em grid / pro
    -- painel oposto. Tem que vir ANTES do modo 3 (bumper segurado + D-pad cicla
    -- container) — durante o nav o bumper está segurado e dispararia o ciclo.
    if GridJoypad.isNavActive(self.player) then
        GridJoypad.navDir(self.player, self, 0, -1)
        return
    end
    local shoulderSwitch = getCore():getOptionShoulderButtonContainerSwitch()
    if shoulderSwitch == 3 then
        if JoypadButton.LeftBump:isDown(joypadData.id) then
            getPlayerInventory(self.player):selectPrevContainer()
            GridJoypad.reanchorToActive(self.player, self)
            return
        end
        if JoypadButton.RightBump:isDown(joypadData.id) then
            getPlayerLoot(self.player):selectPrevContainer()
            GridJoypad.reanchorToActive(self.player, self)
            return
        end
    end
    GridJoypad.handleDir(self.player, self, 0, -1)
end

local og_pageJoypadDirDown = ISInventoryPage.onJoypadDirDown
function ISInventoryPage:onJoypadDirDown(joypadData)
    -- STACK PICKER do controle: D-pad navega a lista da janela.
    if GridJoypad.isPickerActive(self.player) then
        GridJoypad.pickerMove(self.player, 1)
        return
    end
    if GridJoypad.isPaperdollActive(self.player) then
        GridJoypad.pdDir(self.player, 0, 1)
        return
    end
    if GridJoypad.isNavActive(self.player) then
        GridJoypad.navDir(self.player, self, 0, 1)
        return
    end
    local shoulderSwitch = getCore():getOptionShoulderButtonContainerSwitch()
    if shoulderSwitch == 3 then
        if JoypadButton.LeftBump:isDown(joypadData.id) then
            getPlayerInventory(self.player):selectNextContainer()
            GridJoypad.reanchorToActive(self.player, self)
            return
        end
        if JoypadButton.RightBump:isDown(joypadData.id) then
            getPlayerLoot(self.player):selectNextContainer()
            GridJoypad.reanchorToActive(self.player, self)
            return
        end
    end
    GridJoypad.handleDir(self.player, self, 0, 1)
end

local og_pageJoypadDirLeft = ISInventoryPage.onJoypadDirLeft
function ISInventoryPage:onJoypadDirLeft(joypadData)
    if GridJoypad.isPaperdollActive(self.player) then
        GridJoypad.pdDir(self.player, -1, 0)
        return
    end
    if GridJoypad.isNavActive(self.player) then
        GridJoypad.navDir(self.player, self, -1, 0)
        return
    end
    local shoulderSwitch = getCore():getOptionShoulderButtonContainerSwitch()
    if shoulderSwitch == 3 then
        if JoypadButton.LeftBump:isDown(joypadData.id) then
            getPlayerInventory(self.player):selectPrevContainer()
            GridJoypad.reanchorToActive(self.player, self)
            return
        end
        if JoypadButton.RightBump:isDown(joypadData.id) then
            getPlayerLoot(self.player):selectPrevContainer()
            GridJoypad.reanchorToActive(self.player, self)
            return
        end
    end
    GridJoypad.handleDir(self.player, self, -1, 0)
end

local og_pageJoypadDirRight = ISInventoryPage.onJoypadDirRight
function ISInventoryPage:onJoypadDirRight(joypadData)
    if GridJoypad.isPaperdollActive(self.player) then
        GridJoypad.pdDir(self.player, 1, 0)
        return
    end
    if GridJoypad.isNavActive(self.player) then
        GridJoypad.navDir(self.player, self, 1, 0)
        return
    end
    local shoulderSwitch = getCore():getOptionShoulderButtonContainerSwitch()
    if shoulderSwitch == 3 then
        if JoypadButton.LeftBump:isDown(joypadData.id) then
            getPlayerInventory(self.player):selectNextContainer()
            GridJoypad.reanchorToActive(self.player, self)
            return
        end
        if JoypadButton.RightBump:isDown(joypadData.id) then
            getPlayerLoot(self.player):selectNextContainer()
            GridJoypad.reanchorToActive(self.player, self)
            return
        end
    end
    GridJoypad.handleDir(self.player, self, 1, 0)
end

-- ─── Joypad + resize: reservar espaço pro PaperDoll ─────────────────────────
-- O vanilla placeInventoryScreens divide a tela ao meio (inv = metade esquerda,
-- loot = metade direita), mas não sabe do PaperDollWindow. Hookamos pra
-- encolher o inv e deslocar o loot quando o PaperDoll estiver visível.
-- Roda UMA vez na ativação do joypad (e no resolution change), NÃO a cada frame.
local og_placeScreens = ISPlayerDataObject.placeInventoryScreens
function ISPlayerDataObject:placeInventoryScreens(id, numPlayers, isMouse)
    og_placeScreens(self, id, numPlayers, isMouse)
    if isMouse then return end
    local pdW = math.floor(350 * ((GridInventory_uiScale or 100) / 100))
    if pdW <= 0 then return end
    -- Divide igualmente: cada painel recebe (screenW - pdW) / 2.
    local screenW = self.w1 + self.w2
    local half = (screenW - pdW) / 2
    self.w1 = half
    self.w2 = half
    if GridModOptions.isPaperDollLeft() then
        self.x1 = self.x1 + pdW
        self.x2 = self.x1 + self.w1
    else
        self.x2 = self.x1 + self.w1 + pdW
    end
end

local og_onBackpackMouseDown = ISInventoryPage.onBackpackMouseDown
function ISInventoryPage.onBackpackMouseDown(page, button, x, y)
    if og_onBackpackMouseDown then
        og_onBackpackMouseDown(page, button, x, y)
    end
    if page.onCharacter and page.backpacks and page.backpacks[1] ~= button then
        page.GridInventory_DragContainer = button
        if page.containerButtonPanel then
            page.GridInventory_DragStartY = page.containerButtonPanel:getMouseY()
        else
            page.GridInventory_DragStartY = 0
        end
        page.GridInventory_IsDragging = false
    end
end
