--- ISInventoryPane_Hijack.lua
--- Este arquivo sequestra a janela de inventário original do Zomboid,
--- desliga o texto e as listas chatas, e injeta nossa classe GridRender!

require("ISUI/ISInventoryPane")
local GridContainer = require("DataModel/GridContainer")
local GridRender = require("UI/GridRender/GridRender")
local ItemFootprint = require("Algorithm/ItemFootprint")

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
        self.isRefreshingHotbar = true
        og_hotbarRefresh(self, ...)
        self.isRefreshingHotbar = false
        
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
        -- Lê a lista oficial de botões gerados pela UI do Zomboid (backpacks)
        if self.inventoryPage and self.inventoryPage.backpacks then
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
            gc:refresh()
            local newUnpos = gc.unpositioned and #gc.unpositioned or 0
            currentBackpackHash = currentBackpackHash .. "UNPOS:" .. newUnpos .. "|"
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
    end

    -- 3. Limpamos a tela de lixo visual do Zomboid e atualizamos o scroll!
    local og_prerender = ISInventoryPane.prerender
    function ISInventoryPane:prerender()
        -- Polling de Segurança de Alta Performance (Smart Hash)
        -- O Zomboid frequentemente falha em disparar OnContainerUpdate (ex: admin commands, 
        -- consumes, alguns crafts). Checamos matematicamente se o conteúdo mudou.
        local now = getTimestampMs()
        self.lastGridHashCheck = self.lastGridHashCheck or 0
        
        if now - self.lastGridHashCheck > 300 then
            self.lastGridHashCheck = now
            
            local currentHash = 0
            if self.inventoryPage and self.inventoryPage.backpacks then
                for _, button in ipairs(self.inventoryPage.backpacks) do
                    if button.inventory then
                        local jItems = button.inventory:getItems()
                        local size = jItems:size()
                        currentHash = currentHash + size
                        -- Varre todos os IDs de forma hiper rápida pra não deixar NENHUMA mudança escapar
                        for i = 0, size - 1 do
                            currentHash = (currentHash + jItems:get(i):getID()) % 9999999
                        end
                    end
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
                            
                            gridContainer:refresh()
                            
                            local newUnpositioned = gridContainer.unpositioned and #gridContainer.unpositioned or 0
                            
                            -- Se um overflow grid precisar nascer ou morrer, precisamos de um hard refresh!
                            if (oldUnpositioned == 0 and newUnpositioned > 0) or (oldUnpositioned > 0 and newUnpositioned == 0) then
                                needsHardRefresh = true
                            end
                        end
                    end
                else
                    needsHardRefresh = true
                end
                
                if needsHardRefresh then
                    self:refreshContainer()
                    return -- aborta este frame pra evitar conflitos de UI enquanto redesenha
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
        local paneWidth = panelW - (self.inventoryPage and self.inventoryPage.buttonSize or 32)
        
        local xMargin = isPlayer and 25 or 10
        
        local curX = isPlayer and (paneWidth - xMargin) or xMargin
        local curY = 15
        local rowTallest = 0
        
        local xGap = 15
        local yGap = 15
        
        for _, gridUi in ipairs(self.gridContainerUis) do
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
    end
end)



-- ============================================================================
-- 3. Forca a atualizacao da UI em TODO evento de atualizacao de container.
-- O mod renderiza todas as mochilas de uma vez, entao se qualquer uma 
-- atualizar, precisamos setar a flag "dirty" no painel principal!
-- ============================================================================
local og_onInventoryUpdate = ISInventoryPage.onInventoryUpdate
function ISInventoryPage.onInventoryUpdate(inv, item)
    if og_onInventoryUpdate then og_onInventoryUpdate(inv, item) end
    
    print("DEBUG: Zomboid chamou onInventoryUpdate! Container: " .. tostring(inv:getType()))
    
    for p = 0, getNumActivePlayers()-1 do
        local pInv = getPlayerInventory(p)
        if pInv and pInv.inventoryPane then 
            pInv.inventoryPane:refreshContainer() 
        end
        
        local pLoot = getPlayerLoot(p)
        if pLoot and pLoot.inventoryPane then 
            pLoot.inventoryPane:refreshContainer() 
        end
    end
end
