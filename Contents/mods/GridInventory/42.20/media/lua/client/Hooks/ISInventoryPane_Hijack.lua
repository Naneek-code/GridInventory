--- ISInventoryPane_Hijack.lua
--- Este arquivo sequestra a janela de inventário original do Zomboid,
--- desliga o texto e as listas chatas, e injeta nossa classe GridRender!

require("ISUI/ISInventoryPane")
local GridContainer = require("DataModel/GridContainer")
local GridRender = require("UI/GridRender/GridRender")
local ItemFootprint = require("Algorithm/ItemFootprint")
local GridModOptions = require("System/GridModOptions")

-- Mesmo padding usado no ISInventoryPage_Hijack (barra de controles dentro do
-- rodapé reservado do grid ativo). Mantido em 1px nos dois arquivos.
local CONTROLS_PAD = 1

-- ============================================================================
-- A interceptação do ISHotbar foi movida para dentro do OnGameBoot
-- para garantir que o ISHotbar nativo já foi instanciado.
-- ============================================================================

-- Garante que o AutoDrop está instanciado na memória e atrelado ao ciclo de vida
require("System/GridAutoDropSystem")

Events.OnGameBoot.Add(function()

    -- 0. Intercepta ISHotbar:refresh()
    local og_hotbarRefresh = ISHotbar.refresh
    function ISHotbar:refresh(...)
        local args = { n = select("#", ...), ... }
        self.isRefreshingHotbar = true
        -- pcall: se o refresh do hotbar quebrar (ex.: MP no login, item em
        -- trânsito), o flag NÃO fica preso em true — senão o GridContainer:
        -- refresh retorna cedo pra sempre e NENHUM item é posicionado no grid
        -- (sintoma: itens no inventário mas fora de qualquer grid).
        local ok, err = pcall(function()
            og_hotbarRefresh(self, unpack(args, 1, args.n))
        end)
        self.isRefreshingHotbar = false
        if not ok then
            print("[GridInventory] ERRO no hotbar refresh: " .. tostring(err))
        end
        
        -- Força um refresh limpo agora que o Hotbar terminou de re-anexar os itens
        local pInv = getPlayerInventory(self.playerNum)
        if pInv then pInv:refreshBackpacks() end
    end

    -- 1. Injetar nossa estrutura ao criar o painel
    local og_createChildren = ISInventoryPane.createChildren
    function ISInventoryPane:createChildren()
        og_createChildren(self)

        -- Escondendo os botões chatos de expandir listas
        if self.expandAll then self.expandAll:setVisible(false) end
        if self.collapseAll then self.collapseAll:setVisible(false) end
        if self.filterMenu then self.filterMenu:setVisible(false) end

        -- Forçamos o modo "grid" nulo para que o Zomboid não desenhe o modo "details"
        self.mode = "GridInventory" 

        self.gridContainerUis = {}
    end

    -- 2. Sempre que a mochila muda, recriamos nossos blocos
    local og_refreshContainer = ISInventoryPane.refreshContainer
    function ISInventoryPane:refreshContainer()
        og_refreshContainer(self)

        if not self.inventory then return end

        local containersToRender = {}
        -- Mod Option "multiContainer": ligada (padrão) renderiza TODAS as
        -- mochilas/containers abertos. Desligada, renderiza apenas o container
        -- ATIVO do painel (self.inventory) — menos grids, mais performance.
        local multiEnabled
        if self.inventoryPage and self.inventoryPage.onCharacter then
            multiEnabled = GridModOptions.isMultiContainerInv()
        else
            multiEnabled = GridModOptions.isMultiContainerLoot()
        end
        -- Lê a lista oficial de botões gerados pela UI do Zomboid (backpacks)
        if multiEnabled and self.inventoryPage and self.inventoryPage.backpacks then
            for _, button in ipairs(self.inventoryPage.backpacks) do
                if button.inventory then
                    table.insert(containersToRender, { 
                        inv = button.inventory, 
                        item = button.inventory:getContainingItem(),
                        icon = button.image
                    })
                end
            end
        else
            table.insert(containersToRender, { inv = self.inventory, item = nil, icon = nil })
        end

        -- MP FLICKER FIX: Só recriamos os GridRenders se a estrutura de mochilas mudou
        -- ou se algum inventário overflow precisou nascer/morrer.
        local currentBackpackHash = ""
        for _, c in ipairs(containersToRender) do
            currentBackpackHash = currentBackpackHash .. tostring(c.inv) .. "|"
            local gc = GridContainer.getOrCreate(c.inv, self.player)
            local okRefresh, refreshErr = pcall(function() gc:refresh() end)
            if not okRefresh then
                print("[GridInventory] ERRO no refreshContainer: " .. tostring(refreshErr))
            end
            local newUnpos = gc.unpositioned and #gc.unpositioned or 0
            currentBackpackHash = currentBackpackHash .. "UNPOS:" .. newUnpos .. "|"
            -- Nº de grids: o chão abre grids extras (overflow vira grid real).
            -- Como nesses casos o unpositioned fica 0, sem contar os grids o hash
            -- NÃO muda e a 2ª grid de chão nunca nasceria na UI.
            currentBackpackHash = currentBackpackHash .. "GRIDS:" .. (#gc.grids or 0) .. "|"
        end

        -- DETECÇÃO DE STALE: se o GridDevTool limpar as instâncias (GridContainer.
        -- instances = {} — sync de overrides no join, save do dev), os GridRenders
        -- antigos ficam apontando pra instâncias ÓRFÃS e nunca mais atualizam (o
        -- refresh atualiza a instância NOVA, mas o render mostra a antiga). Se o
        -- gridCore de um GridRender != instância atual do container → força rebuild.
        if self.gridContainerUis and #self.gridContainerUis > 0 then
            for _, g in ipairs(self.gridContainerUis) do
                if g.inventoryContainer and g.gridCore then
                    local gc = GridContainer.instances[g.inventoryContainer]
                    if gc and gc.grids and gc.grids[1] and g.gridCore ~= gc.grids[1] then
                        self.lastBackpackHash = nil
                        break
                    end
                end
            end
        end
        
        -- Se a estrutura está igualzinha, a matemática do GridContainer já foi atualizada no loop acima.
        -- Não precisamos destruir os botões e painéis, apenas deixamos eles renderizarem!
        if self.lastBackpackHash == currentBackpackHash and self.gridContainerUis and #self.gridContainerUis > 0 then
            return 
        end
        
        self.lastBackpackHash = currentBackpackHash

        -- Limpa a UI de Grids antigos se fomos recriar
        if self.gridContainerUis then
            for _, gridUi in ipairs(self.gridContainerUis) do
                if gridUi.destroy then gridUi:destroy() end
                self:removeChild(gridUi)
            end
        end
        self.gridContainerUis = {}

        local maxGridWidth = 0
        local allPlayerUnpositioned = {}

        -- Para cada mochila/container, pegamos os grids matemáticos e criamos UIs
        for _, containerData in ipairs(containersToRender) do
            local inv = containerData.inv
            local cItem = containerData.item
            local cIcon = containerData.icon
            local gridContainer = GridContainer.getOrCreate(inv, self.player)
            -- A chamada gridContainer:refresh() já foi feita no loop de hash acima!

            
            for i, gridCoreInstance in ipairs(gridContainer.grids) do
                -- Inicializamos sempre no Y=0. O prerender vai distribuir eles via FlexBox!
                -- Passar yOffset aqui fazia a UI Java gravar um tamanho gigantesco no cache
                local gridUi = GridRender:new(10, 0, gridCoreInstance, self.player, inv, i, cItem, cIcon)
                gridUi:initialise()
                -- Altura base (SEM o footer da controlsUI): usada pelo
                -- gridInv_positionControlsUI pra ancorar a barra logo abaixo do
                -- conteúdo. Capturada aqui (e não no update) pra nunca ficar nil
                -- no primeiro frame após o rebuild.
                gridUi.baseGridHeight = gridUi.height
                -- Marca o grid do CHÃO (assinatura "floor") pra ele ser SEMPRE o
                -- último painel no FlexBox (ver prerender).
                gridUi.isFloor = GridContainer.containerSignature(inv) == "floor"
                
                if self.inventoryPage and self.inventoryPage.onCharacter then
                    -- Margem de 25px para dar espaço para a scrollbar
                    gridUi.baseX = self.width - gridUi.width - 25
                else
                    gridUi.baseX = 10
                end
                
                gridUi:setX(gridUi.baseX)
                gridUi.baseY = 0
                
                self:addChild(gridUi)
                table.insert(self.gridContainerUis, gridUi)
                
                if gridUi.width > maxGridWidth then
                    maxGridWidth = gridUi.width
                end
            end
            -- Cria Overflow colado se for o painel de Loot
            if gridContainer.unpositioned and #gridContainer.unpositioned > 0 then
                local isLootMode = not (self.inventoryPage and self.inventoryPage.onCharacter)
                
                if isLootMode then
                    local OverflowGridRender = require("UI/GridRender/OverflowGridRender")
                    local overflowUi = OverflowGridRender:new(10, 0, gridContainer.unpositioned, self.player, true, inv, cItem, cIcon)
                    overflowUi:initialise()
                    overflowUi.baseGridHeight = overflowUi.height
                    overflowUi.isFloor = GridContainer.containerSignature(inv) == "floor"
                    
                    overflowUi.baseX = 10
                    overflowUi:setX(overflowUi.baseX)
                    overflowUi.baseY = 0
                    
                    self:addChild(overflowUi)
                    table.insert(self.gridContainerUis, overflowUi)
                    
                    if overflowUi.width > maxGridWidth then
                        maxGridWidth = overflowUi.width
                    end
                else
                    -- Jogador: Coleta todos para renderizar no final e não causar shift/flick visual na hotbar/mochilas
                    for _, uItem in ipairs(gridContainer.unpositioned) do
                        table.insert(allPlayerUnpositioned, uItem)
                    end
                end
            end
        end

        -- Renderiza o Overflow global do Jogador no fundo da janela
        if #allPlayerUnpositioned > 0 then
            local OverflowGridRender = require("UI/GridRender/OverflowGridRender")
            local overflowUi = OverflowGridRender:new(10, 0, allPlayerUnpositioned, self.player, false, self.inventory, nil, nil)
            overflowUi:initialise()
            overflowUi.baseGridHeight = overflowUi.height
            overflowUi.isFloor = GridContainer.containerSignature(self.inventory) == "floor"
            
            overflowUi.baseX = self.width - overflowUi.width - 25
            overflowUi:setX(overflowUi.baseX)
            overflowUi.baseY = 0
            
            self:addChild(overflowUi)
            table.insert(self.gridContainerUis, overflowUi)
            
            if overflowUi.width > maxGridWidth then
                maxGridWidth = overflowUi.width
            end
        end

        -- A altura do scroll NÃO é mais definida aqui, pois o prerender cuida do FlexBox real
        self:setScrollWidth(maxGridWidth + 20)
        self:setScrollChildren(true)
        
        -- Traz a scrollbar do Zomboid pra frente dos nossos painéis
        if self.vscroll then
            self.vscroll:bringToTop()
        end

        -- HEIGHT FIX: o vanilla ISInventoryPage (update e refreshBackpacks)
        -- desconta controlsUI.height da altura do PANE — reserva do rodapé
        -- nativo onde os botões Take All viveriam. O mod moveu a barra pra
        -- DENTRO do grid (gridInv_positionControlsUI), então esse desconto é
        -- fantasma: faz o painel "respirar" (perder/ganhar altura) a cada troca
        -- de container. Restauramos a altura cheia do pane AQUI, no fim do
        -- refreshContainer (cobre os 2 caminhos: update via gridRefreshDirty e
        -- refreshBackpacks/selectContainer), então o vanilla nunca deixa o pane
        -- encolhido nem por 1 frame.
        local page = self.inventoryPage
        if page then
            local resizeH = 0
            if page.resizeWidget and page.resizeWidget.height then
                resizeH = page.resizeWidget.height
            end
            local fullH = page.height - self.y - resizeH
            if self.height ~= fullH then
                self:setHeight(fullH)
            end
        end
    end

    -- 3. Limpamos a tela de lixo visual do Zomboid e atualizamos o scroll!
    local og_prerender = ISInventoryPane.prerender

    -- Posiciona a controlsUI (Take All/Transfer All/objeto) no rodapé do grid
    -- ATIVO usando os valores do FLEXBOX recém-calculados (baseX/baseY deste
    -- mesmo frame). Chamado no fim do prerender — NÃO no update — pra a barra
    -- seguir o grid no MESMO frame (sem lag de 1 frame quando o grid cresce
    -- pro footer ou o flexbox quebra coluna). No update só reservamos a altura
    -- do grid; o baseY que o flexbox lê já inclui o footer.
    local function gridInv_positionControlsUI(pane)
        local page = pane.inventoryPage
        local controlsUI = page and page.controlsUI
        if not controlsUI then return end
        local gridUi = nil
        if pane.gridContainerUis then
            local activeInv = pane.inventory
            for _, g in ipairs(pane.gridContainerUis) do
                if not g.isOverflow and g.inventoryContainer == activeInv then
                    gridUi = g
                    break
                end
            end
        end
        local hasButtons = (gridUi and controlsUI.controls and #controlsUI.controls > 0)
        if not hasButtons then
            controlsUI:setVisible(false)
            return
        end
        -- Usa baseX/baseY (flexbox) + baseGridHeight (altura SEM o footer):
        -- posição exata dentro do rodapé reservado, no MESMO frame do layout.
        local bx = gridUi.baseX or gridUi:getX()
        local by = gridUi.baseY or gridUi:getY()
        controlsUI:setX(bx + CONTROLS_PAD)
        controlsUI:setY(by + (gridUi.baseGridHeight or gridUi:getHeight()) + CONTROLS_PAD)
        controlsUI:setWidth(gridUi:getWidth() - (CONTROLS_PAD * 2))
        controlsUI:setVisible(true)
        local kids = pane:getChildrenInOrder()
        local isTop = kids[#kids] == controlsUI
        if not isTop then
            controlsUI:bringToTop()
        end
    end

    function ISInventoryPane:prerender()
        -- Polling de Segurança de Alta Performance (Smart Hash)
        -- O Zomboid frequentemente falha em disparar OnContainerUpdate (ex: admin commands, 
        -- consumes, alguns crafts). Checamos matematicamente se o conteúdo mudou.
        local now = getTimestampMs()
        self.lastGridHashCheck = self.lastGridHashCheck or 0
        
        if now - self.lastGridHashCheck > 300 then
            self.lastGridHashCheck = now
            
            local currentHash = 0
            -- Mesmo conjunto de containers do refreshContainer: no modo
            -- single-container só o container ATIVO é checado (menos trabalho
            -- por frame quando a performance importa).
            local multiEnabled
            if self.inventoryPage and self.inventoryPage.onCharacter then
                multiEnabled = GridModOptions.isMultiContainerInv()
            else
                multiEnabled = GridModOptions.isMultiContainerLoot()
            end
            local pollInv = {}
            if multiEnabled and self.inventoryPage and self.inventoryPage.backpacks then
                for _, button in ipairs(self.inventoryPage.backpacks) do
                    if button.inventory then
                        table.insert(pollInv, button.inventory)
                    end
                end
            else
                table.insert(pollInv, self.inventory)
            end
            for _, inv in ipairs(pollInv) do
                local jItems = inv:getItems()
                local size = jItems:size()
                currentHash = currentHash + size
                -- Varre todos os IDs de forma hiper rápida pra não deixar NENHUMA mudança escapar
                for i = 0, size - 1 do
                    currentHash = (currentHash + jItems:get(i):getID()) % 9999999
                end
            end
            
            if self.lastGridHash ~= currentHash then
                self.lastGridHash = currentHash
                
                local needsHardRefresh = false
                
                -- Fazemos um refresh lógico/silencioso apenas
                if self.gridContainerUis then
                    for _, gridUi in ipairs(self.gridContainerUis) do
                        local inv = gridUi.inventoryContainer
                        if inv then
                            local gridContainer = GridContainer.getOrCreate(inv, self.player)
                            
                            local oldUnpositioned = gridContainer.unpositioned and #gridContainer.unpositioned or 0
                            
                            local okRefresh, refreshErr = pcall(function() gridContainer:refresh() end)
                            if not okRefresh then
                                print("[GridInventory] ERRO no refresh do container: " .. tostring(refreshErr))
                            end
                            
                            local newUnpositioned = gridContainer.unpositioned and #gridContainer.unpositioned or 0
                            
                            -- Se um overflow grid precisar nascer ou morrer, precisamos de um hard refresh!
                            if (oldUnpositioned == 0 and newUnpositioned > 0) or (oldUnpositioned > 0 and newUnpositioned == 0) then
                                needsHardRefresh = true
                            end
                            
                            -- STALE: o GridRender aponta pra instância órfã (GridDevTool
                            -- limpou GridContainer.instances) → força rebuild. Sem isso o
                            -- grid NUNCA reflete mudanças (loot congela ao pegar item).
                            if not needsHardRefresh and gridUi.gridCore then
                                local gc = GridContainer.instances[inv]
                                if gc and gc.grids and gc.grids[1] and gridUi.gridCore ~= gc.grids[1] then
                                    needsHardRefresh = true
                                end
                            end

                            -- CHÃO: grids extras. O refresh abriu/removeu grids de
                            -- chão (overflow vira grid real, unpositioned=0) → a UI
                            -- precisa nascer/morrer junto. Compara a contagem de
                            -- grids do container com as UIs não-overflow dele.
                            if not needsHardRefresh and inv.getType and inv:getType() == "floor" then
                                local uiCount = 0
                                for _, other in ipairs(self.gridContainerUis) do
                                    if not other.isOverflow and other.inventoryContainer == inv then
                                        uiCount = uiCount + 1
                                    end
                                end
                                if uiCount ~= #gridContainer.grids then
                                    needsHardRefresh = true
                                end
                            end
                        end
                    end
                else
                    needsHardRefresh = true
                end
                
                if needsHardRefresh then
                    self:refreshContainer()
                    -- NÃO aborta o frame: o FlexBox abaixo reposiciona os grids
                    -- recriados NO MESMO frame. Abortar deixava tudo no baseY=0
                    -- por 1 frame (floor "pulava" por cima dos outros grids) = flicker.
                end
            end
        end
        
        if ISMouseDrag.dragging and #ISMouseDrag.dragging > 0 then
            -- O Zomboid fica travando a tela com esse super render
        end
        
        og_prerender(self)
        
        self.mode = "GridInventory" -- Reforça pra não piscar a lista
        self.nameHeader:setVisible(false)
        self.typeHeader:setVisible(false)
        
        -- Sistema FlexBox dinâmico!
        local yScroll = self:getYScroll()
        local xScroll = self:getXScroll()
        
        local isPlayer = (self.inventoryPage and self.inventoryPage.onCharacter)
        local core = getCore()
        local screenW = core:getScreenWidth()
        local panelW = (screenW - 350) / 2
        if not GridModOptions.isFullscreenPanel() then
            panelW = self.width
        end
        local paneWidth = panelW - (self.inventoryPage and self.inventoryPage.buttonSize or 32)
        
        local xMargin = isPlayer and 25 or 10
        
        local curX = isPlayer and (paneWidth - xMargin) or xMargin
        local curY = 15
        local rowTallest = 0
        
        local xGap = 15
        local yGap = 15
        
        -- O CHÃO é sempre o ÚLTIMO painel (assinatura "floor"): passada 1 = todos
        -- os outros grids; passada 2 = floor (e seu overflow). Assim qualquer
        -- redraw o reposiciona por último, na base do loot, sem "pular" por cima.
        local orderedGrids = {}
        for _, g in ipairs(self.gridContainerUis) do
            if not g.isFloor then table.insert(orderedGrids, g) end
        end
        for _, g in ipairs(self.gridContainerUis) do
            if g.isFloor then table.insert(orderedGrids, g) end
        end
        for _, gridUi in ipairs(orderedGrids) do
            local gW = gridUi.width
            local gH = gridUi.height
            
            if isPlayer then
                -- RTL (Da direita pra esquerda)
                if curX - gW < 10 and curX < paneWidth - xMargin then
                    curX = paneWidth - xMargin
                    curY = curY + rowTallest + yGap
                    rowTallest = 0
                end
                gridUi.baseX = curX - gW
                curX = curX - gW - xGap
            else
                -- LTR (Da esquerda pra direita) - FLEXBOX RESTAURADO!
                if curX + gW > paneWidth - 25 and curX > xMargin then
                    curX = xMargin
                    curY = curY + rowTallest + yGap
                    rowTallest = 0
                end
                gridUi.baseX = curX
                curX = curX + gW + xGap
            end
            
            gridUi.baseY = curY
            if gH > rowTallest then rowTallest = gH end
            
            -- O Zomboid já translada a tela toda porque ativamos setScrollChildren(true) no refreshContainer!
            -- Se somarmos yScroll aqui, os grids andam 2x mais rápido que o mouse e somem pra fora da tela!
            gridUi:setY(gridUi.baseY)
            gridUi:setX(gridUi.baseX)
        end

        -- Posiciona a barra de controles (Take All/Transfer All/objeto) com os
        -- baseY/baseX do flexbox DESTE frame (sem lag de 1 frame vs o grid).
        gridInv_positionControlsUI(self)

        local finalHeight = curY + rowTallest + 30
        self.myFinalHeight = finalHeight
        if finalHeight ~= self:getScrollHeight() then
            self:setScrollHeight(finalHeight)
        end
        
        -- Garante que a barra rola no cantinho da tela
        if self.vscroll then
            self.vscroll:setX(self.width - 15)
            self.vscroll:bringToTop()
        end

        -- Auto-scroll para o container selecionado. No painel de LOOT o alvo é
        -- o container na frente do jogador (rola ao ABRIR e ao trocar de alvo —
        -- virou, clicou, scroll do mouse). No painel do INVENTÁRIO o alvo é a
        -- mochila clicada (restaura o comportamento do selectContainer antigo:
        -- pisca/rola SÓ quando a mochila muda, nunca na abertura). Depois de
        -- encaixar, para de mexer — o jogador rola livre até o alvo mudar.
        if self.inventoryPage then
            local targetInv = self.inventoryPage.inventory
            local changed = (targetInv ~= self.autoScrollTargetInv)
            -- Loot: flag de abertura força rolar; troca de alvo sempre rola.
            -- Inventário do jogador: rola só quando a mochila muda (a flag de
            -- abertura nunca é setada pra ele — ver setVisible).
            local shouldSnap = self.autoScrollToTarget or (changed and self.autoScrollTargetInv ~= nil)
            if targetInv and shouldSnap then
                for _, gridUi in ipairs(self.gridContainerUis) do
                    if not gridUi.isOverflow and gridUi.inventoryContainer == targetInv then
                        -- Pisca a grid alvo (mesmo efeito do selectContainer antigo),
                        -- mas não repete se for o MESMO container da última vez
                        -- (ex.: reabriu o loot sem trocar de alvo). O scroll
                        -- continua rolando até ele, só o flash não repete.
                        local isSameContainer = (targetInv == self.autoScrollTargetInv)
                        if not isSameContainer then
                            gridUi.flashAlpha = 1.0
                        end
                        local maxScroll = math.max(0, (self.myFinalHeight or finalHeight) - self:getHeight())
                        local desired = math.max(0, math.min((gridUi.baseY or 0) - 15, maxScroll))
                        self:setYScroll(-desired)
                        -- Mata o scroll suave nativo pra ele não brigar com o snap
                        self.smoothScrollTargetY = nil
                        self.autoScrollTargetInv = targetInv
                        self.autoScrollToTarget = false
                        break
                    end
                end
            end
        end
    end

    -- Quando um painel é mostrado:
    --  - Loot: marca pra rolar até o container alvo na abertura (o flash não
    --    repete se for o mesmo container).
    --  - Inventário do jogador: apenas registra o container atual como baseline,
    --    pra abrir NÃO contar como "mudança" (flash/scroll só ao trocar de mochila).
    local og_pageSetVisible = ISInventoryPage.setVisible
    function ISInventoryPage:setVisible(vis)
        og_pageSetVisible(self, vis)
        if vis and self.inventoryPane then
            if self.onCharacter then
                if self.inventoryPane.inventory then
                    self.inventoryPane.autoScrollTargetInv = self.inventoryPane.inventory
                end
            else
                self.inventoryPane.autoScrollToTarget = true
            end
        end
    end

    -- Scroll FORA de um grid = troca o container selecionado (mesmo
    -- comportamento do vanilla na coluna de mochilas/ícones), valendo para o
    -- painel de LOOT e o de INVENTÁRIO. Sobre um grid, rola o painel
    -- normalmente (comportamento vanilla).
    local og_paneOnMouseWheel = ISInventoryPane.onMouseWheel
    function ISInventoryPane:onMouseWheel(del)
        local page = self.inventoryPage
        if page and not page.isCollapsed and not self:isMouseOverAnyGrid() then
            return page:cycleContainer(del)
        end
        return og_paneOnMouseWheel(self, del)
    end

    -- Painel COLAPSADO = o pane (filho da página, altura cheia) não pode
    -- nullifyAiming nem computar seleção/clique — o corpo do painel colapsado
    -- precisa deixar o jogador mirar/clicar através dele. (Defense-in-depth:
    -- o Java pode despachar pro pane independente da página.)
    local og_paneOnMouseDown = ISInventoryPane.onMouseDown
    function ISInventoryPane:onMouseDown(x, y)
        local page = self.inventoryPage
        if page and page.isCollapsed then return end
        if og_paneOnMouseDown then
            return og_paneOnMouseDown(self, x, y)
        end
        return false
    end

    --- Verdadeiro se o mouse está em cima de qualquer grid renderizado.
    function ISInventoryPane:isMouseOverAnyGrid()
        if not self.gridContainerUis then return false end
        for _, gridUi in ipairs(self.gridContainerUis) do
            if gridUi.isMouseOver and gridUi:isMouseOver() then
                return true
            end
        end
        return false
    end

    -- FIX DO DUPLO CLIQUE (3 cliques → 2 cliques):
    -- O Java detecta double-click POR ELEMENTO (estado `clicked` + clickX/Y +
    -- leftDownTime) e, quando acha, CHAMA onMouseDoubleClick e ENGOLIRIA o 2º
    -- onMouseDown. Como o Kahlua rawget resolve metatable, o ISInventoryPane
    -- (que tem onMouseDoubleClick vanilla) DETECTA o double-click dele no 2º
    -- clique e engole o clique ANTES de chegar no grid. Aí o estado Java do
    -- grid fica "primado" do clique 1 e só dispara no 3º clique.
    -- Solução: como o Java do pane sempre retorna TRUE (não dá pra não-engolir),
    -- sobrescrevemos o onMouseDoubleClick do pane para ENCAMINHAR o duplo clique
    -- para o grid sob o cursor (mesma lógica do GridRender:onMouseDoubleClick).
    local og_paneOnMouseDoubleClick = ISInventoryPane.onMouseDoubleClick
    function ISInventoryPane:onMouseDoubleClick(x, y)
        -- Painel colapsado: nada a fazer (não encaminha pro grid)
        local page = self.inventoryPage
        if page and page.isCollapsed then return end
        -- Scrollbar: deixa o vanilla tratar (duplo clique rola até o fim)
        if self.vscroll and self:isMouseOverScrollBar() then
            return self.vscroll:onMouseDoubleClick(x - self.vscroll.x, y + self:getYScroll() - self.vscroll.y)
        end
        -- Duplo clique em cima de um grid: encaminha pro grid sob o cursor
        if self.gridContainerUis then
            for _, gridUi in ipairs(self.gridContainerUis) do
                if gridUi.isMouseOver and gridUi:isMouseOver() and gridUi.onMouseDoubleClick then
                    -- Limpa o estado custom do grid pra um 3º clique não
                    -- false-positivar no double-click que acabou de acontecer
                    gridUi.lastManualClickTime = nil
                    gridUi.lastManualClickItemId = nil
                    return gridUi:onMouseDoubleClick(gridUi:getMouseX(), gridUi:getMouseY())
                end
            end
        end
        -- Fora de grid (e sem scrollbar): comportamento vanilla (lista de itens
        -- fica oculta no mod, então na prática não faz nada).
        if og_paneOnMouseDoubleClick then
            return og_paneOnMouseDoubleClick(self, x, y)
        end
        return false
    end
end)



-- ============================================================================
-- 3. Forca a atualizacao da UI em TODO evento de atualizacao de container.
-- O mod renderiza todas as mochilas de uma vez, entao se qualquer uma 
-- atualizar, precisamos setar a flag "dirty" no painel principal!
-- NAO chamamos refreshContainer() aqui: o evento dispara varias vezes por
-- transferencia/loot e cada chamada refaz o remap matematico de todos os
-- containers. Marcamos "dirty" e o ISInventoryPage:update coalesce para
-- no maximo 1 refresh por frame.
-- ============================================================================
local og_onInventoryUpdate = ISInventoryPage.onInventoryUpdate
function ISInventoryPage.onInventoryUpdate(inv, item)
    if og_onInventoryUpdate then og_onInventoryUpdate(inv, item) end
    
    for p = 0, getNumActivePlayers()-1 do
        local pInv = getPlayerInventory(p)
        if pInv and pInv.inventoryPane then 
            pInv.inventoryPane.gridRefreshDirty = true
        end
        
        local pLoot = getPlayerLoot(p)
        if pLoot and pLoot.inventoryPane then 
            pLoot.inventoryPane.gridRefreshDirty = true
        end
    end
end

-- GATILHO REAL de container update: o evento OnContainerUpdate é o que o motor
-- dispara quando QUALQUER container muda (pegar item, transferir, etc.). O
-- vanilla só marca renderDirty; nós marcamos o refresh do grid pra reconstruir
-- os GridRenders. O polling de 300ms continua como rede de segurança (o mod
-- constatou que o OnContainerUpdate às vezes falha em disparar).
Events.OnContainerUpdate.Add(function(object)
    for p = 0, getNumActivePlayers() - 1 do
        local pInv = getPlayerInventory(p)
        if pInv and pInv.inventoryPane then
            pInv.inventoryPane.gridRefreshDirty = true
        end
        local pLoot = getPlayerLoot(p)
        if pLoot and pLoot.inventoryPane then
            pLoot.inventoryPane.gridRefreshDirty = true
        end
    end
end)
