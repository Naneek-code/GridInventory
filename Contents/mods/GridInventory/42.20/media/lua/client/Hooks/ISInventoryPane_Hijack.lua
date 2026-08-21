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
        -- OTIMIZAÇÃO: quando o poll 300ms disparou o hard refresh, ele JÁ rodou o
        -- gc:refresh() de cada grid (linhas ~366-373). Sem essa flag o refreshContainer
        -- REFARIA o remap de todos os containers = duplo O(n*W*H) na mesma mudança.
        local skipRefresh = self._pollAlreadyRefreshed
        self._pollAlreadyRefreshed = nil
        for _, c in ipairs(containersToRender) do
            currentBackpackHash = currentBackpackHash .. tostring(c.inv) .. "|"
            local gc = GridContainer.getOrCreate(c.inv, self.player)
            if not skipRefresh then
                local okRefresh, refreshErr = pcall(function() gc:refresh() end)
                if not okRefresh then
                    print("[GridInventory] ERRO no refreshContainer: " .. tostring(refreshErr))
                end
            end
            local newUnpos = gc.unpositioned and #gc.unpositioned or 0
            currentBackpackHash = currentBackpackHash .. "UNPOS:" .. newUnpos .. "|"
            -- Conteúdo do overflow no hash: o OverflowGridRender é um SNAPSHOT, e o
            -- size pode ser o mesmo com itens DIFERENTES (um volta pro grid, outro
            -- cai no overflow). Sem os IDs o hash não muda e a UI mostra itens velhos.
            if newUnpos > 0 then
                for _, ui in ipairs(gc.unpositioned) do
                    currentBackpackHash = currentBackpackHash .. "O:" .. ui:getID() .. ";"
                end
                currentBackpackHash = currentBackpackHash .. "|"
            end
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
                    if gc and gc.grids and g.gridIndex and gc.grids[g.gridIndex] and g.gridCore ~= gc.grids[g.gridIndex] then
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

        -- Prepara para reaproveitar os GridRenders que não mudaram (evita piscar UI e tooltips no carro)
        local oldGrids = self.gridContainerUis or {}
        local gridsToKeep = {}
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
                -- Tenta reaproveitar o GridRender antigo se o inv e index forem iguais
                local gridUi = nil
                for idx, old in ipairs(oldGrids) do
                    local isSameInv = (old.inventoryContainer == inv) or (old.inventoryContainer and inv and old.inventoryContainer.getType and inv.getType and old.inventoryContainer:getType() == "floor" and inv:getType() == "floor")
                    if isSameInv and old.gridIndex == i and not old.isOverflow then
                        if old.gridCore and (old.gridCore.width ~= gridCoreInstance.width or old.gridCore.height ~= gridCoreInstance.height) then
                            -- Modificou W/H no DevTools, força recriar interface para alinhar caixa preta
                        else
                            gridUi = old
                            table.remove(oldGrids, idx)
                            break
                        end
                    end
                end

                if not gridUi then
                    -- Inicializamos sempre no Y=0. O prerender vai distribuir eles via FlexBox!
                    local newUi = GridRender:new(10, 0, gridCoreInstance, self.player, inv, i, cItem, cIcon)
                    newUi:initialise()
                    self:addChild(newUi)
                    gridUi = newUi
                else
                    -- Se reaproveitou, garante que o gridCore e o inventário atualizados estejam no render
                    gridUi.gridCore = gridCoreInstance
                    gridUi.inventoryContainer = inv
                end
                -- Recalcula a altura base pura (sem footer) baseada no gridCore atualizado.
                -- Evita o bug de expansão infinita onde o gridUi.height reciclado já continha
                -- o footer da frame anterior e somava repetidamente.
                gridUi.baseGridHeight = (gridUi.gridCore.height * gridUi.cellSize) + (gridUi.gridPadding * 2) + gridUi.headerH
                if gridUi.height ~= gridUi.baseGridHeight then
                    gridUi:setHeight(gridUi.baseGridHeight)
                end
                -- Marca o grid do CHÃO (assinatura "floor") pra ele ser SEMPRE o
                -- último painel no FlexBox (ver prerender).
                gridUi.isFloor = GridContainer.containerSignature(inv) == "floor"
                
                if self.inventoryPage and self.inventoryPage.onCharacter then
                    -- Margem de 15px para a scrollbar (mesma do flexbox no prerender)
                    gridUi.baseX = self.width - gridUi.width - 15
                else
                    -- Loot: mesma margem de 15px pro espelho simétrico (sem
                    -- scrollbar na esquerda, mas igual ao lado do jogador).
                    gridUi.baseX = 15
                end
                
                gridUi:setX(gridUi.baseX)
                gridUi.baseY = 0
                
                if not gridUi:getParent() then
                    self:addChild(gridUi)
                end
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
                    local overflowUi = nil
                    for idx, old in ipairs(oldGrids) do
                        local isSameInv = (old.inventoryContainer == inv) or (old.inventoryContainer and inv and old.inventoryContainer.getType and inv.getType and old.inventoryContainer:getType() == "floor" and inv:getType() == "floor")
                        if isSameInv and old.isOverflow then
                            overflowUi = old
                            table.remove(oldGrids, idx)
                            break
                        end
                    end
                    if not overflowUi then
                        overflowUi = OverflowGridRender:new(10, 0, gridContainer.unpositioned, self.player, true, inv, cItem, cIcon)
                        overflowUi:initialise()
                    else
                        overflowUi.unpositionedItems = gridContainer.unpositioned
                        overflowUi.inventoryContainer = inv
                        
                        -- Reconstroi o grid falso do overflow se foi reciclado
                        local columns = 6
                        local rows = math.max(1, math.ceil(#overflowUi.unpositionedItems / columns))
                        local GridCore = require("DataModel/GridCore")
                        local fakeCore = GridCore.new(columns, rows)
                        local index = 1
                        for row = 1, rows do
                            for col = 1, columns do
                                if index <= #overflowUi.unpositionedItems then
                                    local it = overflowUi.unpositionedItems[index]
                                    fakeCore:insertItem(it:getID(), col, row, 1, 1, false, it)
                                    index = index + 1
                                end
                            end
                        end
                        overflowUi.gridCore = fakeCore
                    end
                    overflowUi.baseGridHeight = (overflowUi.gridCore.height * overflowUi.cellSize) + (overflowUi.gridPadding * 2) + overflowUi.headerH
                    if overflowUi.height ~= overflowUi.baseGridHeight then
                        overflowUi:setHeight(overflowUi.baseGridHeight)
                    end
                    overflowUi.isFloor = GridContainer.containerSignature(inv) == "floor"
                    
                    overflowUi.baseX = 15
                    overflowUi:setX(overflowUi.baseX)
                    overflowUi.baseY = 0
                    
                    if not overflowUi:getParent() then
                        self:addChild(overflowUi)
                    end
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
            local overflowUi = nil
            for idx, old in ipairs(oldGrids) do
                local isSameInv = (old.inventoryContainer == self.inventory) or (old.inventoryContainer and self.inventory and old.inventoryContainer.getType and self.inventory.getType and old.inventoryContainer:getType() == "floor" and self.inventory:getType() == "floor")
                if isSameInv and old.isOverflow then
                    overflowUi = old
                    table.remove(oldGrids, idx)
                    break
                end
            end
            if not overflowUi then
                overflowUi = OverflowGridRender:new(10, 0, allPlayerUnpositioned, self.player, false, self.inventory, nil, nil)
                overflowUi:initialise()
            else
                overflowUi.unpositionedItems = allPlayerUnpositioned
                overflowUi.inventoryContainer = self.inventory
                
                local columns = 6
                local rows = math.max(1, math.ceil(#overflowUi.unpositionedItems / columns))
                local GridCore = require("DataModel/GridCore")
                local fakeCore = GridCore.new(columns, rows)
                local index = 1
                for row = 1, rows do
                    for col = 1, columns do
                        if index <= #overflowUi.unpositionedItems then
                            local it = overflowUi.unpositionedItems[index]
                            fakeCore:insertItem(it:getID(), col, row, 1, 1, false, it)
                            index = index + 1
                        end
                    end
                end
                overflowUi.gridCore = fakeCore
            end
            overflowUi.baseGridHeight = (overflowUi.gridCore.height * overflowUi.cellSize) + (overflowUi.gridPadding * 2) + overflowUi.headerH
            if overflowUi.height ~= overflowUi.baseGridHeight then
                overflowUi:setHeight(overflowUi.baseGridHeight)
            end
            overflowUi.isFloor = GridContainer.containerSignature(self.inventory) == "floor"
            
            overflowUi.baseX = self.width - overflowUi.width - 15
            overflowUi:setX(overflowUi.baseX)
            overflowUi.baseY = 0
            
            if not overflowUi:getParent() then self:addChild(overflowUi) end
            table.insert(self.gridContainerUis, overflowUi)
            
            if overflowUi.width > maxGridWidth then
                maxGridWidth = overflowUi.width
            end
        end

        -- Destrói os grids órfãos (que não foram reaproveitados)
        if oldGrids then
            for _, old in ipairs(oldGrids) do
                if old.destroy then old:destroy() end
                self:removeChild(old)
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
        -- No CONTROLE não dá pra clicar nos botões (Take All etc. — também é
        -- vanilla); esconde pra não enganar o usuário e não reserva o rodapé.
        local usingJoypad = JoypadState and JoypadState.players
            and JoypadState.players[page.player + 1] ~= nil
        if not hasButtons or usingJoypad then
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

                -- Fazemos um refresh lógico/silencioso apenas. IMPORTANTE: itera
                -- pollInv (o MESMO conjunto do refreshContainer: backpacks ou
                -- container ativo) — antes iterava gridContainerUis, que diverge
                -- (overflow/floor são UIs extras do mesmo container) e fazia o
                -- _pollAlreadyRefreshed pular o refresh de containers que o poll
                -- não tinha tocado.
                local refreshedAny = false
                for _, inv in ipairs(pollInv) do
                    if inv then
                        refreshedAny = true
                        local gridContainer = GridContainer.getOrCreate(inv, self.player)

                        local oldUnpositioned = gridContainer.unpositioned and #gridContainer.unpositioned or 0

                        local okRefresh, refreshErr = pcall(function() gridContainer:refresh() end)
                        if not okRefresh then
                            print("[GridInventory] ERRO no refresh do container: " .. tostring(refreshErr))
                        end

                        local newUnpositioned = gridContainer.unpositioned and #gridContainer.unpositioned or 0

                        -- QUALQUER mudança no overflow exige hard refresh: o
                        -- OverflowGridRender é um SNAPSHOT criado no rebuild. Se
                        -- um item de overflow volta pro grid sem zerar (ex: 2→1),
                        -- sem o rebuild a UI continua mostrando o item que já saiu
                        -- ("overflow perdido") até um rebuild forçado (trocar de
                        -- container). O crossing 0↔>0 antigo só cobria nascer/morrer.
                        if oldUnpositioned ~= newUnpositioned then
                            needsHardRefresh = true
                        end
                    end
                end

                -- Checagens UI-level (baratas, sem refresh): STALE de instância e
                -- contagem de grids de chão. Independentes do passe acima.
                if self.gridContainerUis then
                    for _, gridUi in ipairs(self.gridContainerUis) do
                        local inv = gridUi.inventoryContainer
                        if inv then
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
                                local gridContainer = GridContainer.getOrCreate(inv, self.player)
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
                elseif #pollInv > 0 then
                    needsHardRefresh = true
                end

                if needsHardRefresh then
                    -- O refresh() de todos os containers JÁ rodou neste poll (passe
                    -- acima, mesmos containers do refreshContainer). Informa o
                    -- refreshContainer pra NÃO refazer o remap (duplo custo).
                    if refreshedAny then
                        self._pollAlreadyRefreshed = true
                    end
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
        -- Largura real do painel: o ISInventoryPage_Hijack já calcula isso no
        -- update (paperDollW com UI Scale + expansão pro grid ativo caber) e
        -- seta self.width do pane. Recalcular com (screenW-350)/2 aqui deixava
        -- um GAP entre o grid e a coluna de bolsas: com UI Scale >100 ou um
        -- grid largo, o painel real fica MAIOR que essa conta, e como o layout
        -- do jogador ancora o grid pela DIREITA (paneWidth - xMargin), o grid
        -- parava antes do fim real — sobrava espaço até a coluna de bolsas.
        local paneWidth = self.width
        if paneWidth <= 0 then
            paneWidth = (screenW - 350) / 2
        end
        
        -- Margem da borda do pane. No jogador, o grid termina ANTES da
        -- scrollbar (que fica no canto direito, ~15px). No loot não há scrollbar
        -- na esquerda, mas pra manter o ESPELHO simétrico dos dois painéis
        -- (inv = grid à direita, loot = grid à esquerda) usamos a MESMA margem
        -- dos dois lados: 15px. Senão o grid do loot fica colado na coluna de
        -- bolsas enquanto o do jogador fica mais afastado — visual estranho.
        local xMargin = 15
        
        local curX = isPlayer and (paneWidth - xMargin) or xMargin
        local curY = 15
        local rowTallest = 0
        
        local xGap = 15
        local yGap = 15
        
        -- O CHÃO é sempre o ÚLTIMO painel (assinatura "floor"): passada 1 = todos
        -- os outros grids; passada 2 = floor (e seu overflow). Assim qualquer
        -- redraw o reposiciona por último, na base do loot, sem "pular" por cima.
        local orderedGrids = {}
        local nonFloor = {}
        for _, g in ipairs(self.gridContainerUis) do
            if not g.isFloor then table.insert(nonFloor, g) end
        end
        
        -- Aplica a ordenação customizada para bater com a visualização dos botões
        local playerObj = getSpecificPlayer(self.player)
        if playerObj and self.inventoryPage and self.inventoryPage.onCharacter then
            local modData = playerObj:getModData()
            local orderStr = modData.GridInventory_ContainerOrderStr or ""
            local orderTbl = {}
            for id, i in string.gmatch(orderStr, "([^:,]+):([^:,]+)") do
                orderTbl[id] = tonumber(i)
            end
            
            local function getGridId(g)
                if not g.inventoryContainer then return "" end
                local item = g.inventoryContainer:getContainingItem()
                if item then
                    local id = item:getID()
                    if id and id ~= -1 and id ~= 0 then return tostring(id) end
                    return item:getFullType() or ""
                end
                return ""
            end
            
            local sortData = {}
            for i, g in ipairs(nonFloor) do
                local id = getGridId(g)
                local priority = orderTbl[id]
                local isMain = false
                if self.inventoryPage.backpacks and self.inventoryPage.backpacks[1] and self.inventoryPage.backpacks[1].inventory == g.inventoryContainer then
                    isMain = true
                end
                
                if isMain then
                    priority = -1
                elseif not priority then
                    priority = i * 1000
                end
                
                table.insert(sortData, {
                    grid = g,
                    priority = priority,
                    vanillaIndex = i
                })
            end
            
            table.sort(sortData, function(a, b)
                if a.priority ~= b.priority then return a.priority < b.priority end
                return a.vanillaIndex < b.vanillaIndex
            end)
            
            for _, data in ipairs(sortData) do
                table.insert(orderedGrids, data.grid)
            end
        else
            for _, g in ipairs(nonFloor) do
                table.insert(orderedGrids, g)
            end
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
    -- com multiplicador pra scrollar mais rápido que o vanilla.
    local SCROLL_MULT = 3
    local og_paneOnMouseWheel = ISInventoryPane.onMouseWheel
    function ISInventoryPane:onMouseWheel(del)
        local page = self.inventoryPage
        if page and not page.isCollapsed and not self:isMouseOverAnyGrid() then
            return page:cycleContainer(del)
        end
        return og_paneOnMouseWheel(self, del * SCROLL_MULT)
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
