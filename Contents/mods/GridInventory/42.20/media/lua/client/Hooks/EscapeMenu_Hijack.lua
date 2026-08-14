-- Hook para fechar os painéis do GridInventory com o ESC antes de abrir o menu principal
Events.OnGameBoot.Add(function()
    local GridModOptions = GridInventory_ModOptions
    if not GridModOptions then
        local ok, mod = pcall(require, "System/GridModOptions")
        if ok then GridModOptions = mod end
    end

    local og_ToggleEscapeMenu = ToggleEscapeMenu

    -- O Zomboid já registrou o ponteiro original no OnKeyPressed. 
    -- Precisamos desregistrar a velha e registrar a nossa!
    Events.OnKeyPressed.Remove(og_ToggleEscapeMenu)

    ToggleEscapeMenu = function(key)
        -- Somente verificamos se for a tecla ESC (ou a tecla de menu mapeada)
        if not (getCore():isKey("Main Menu", key) or (getCore():getKey("Main Menu") == 0 and key == Keyboard.KEY_ESCAPE)) then
            return og_ToggleEscapeMenu(key)
        end

        -- Fechar os painéis com ESC é opcional (Mod Options).
        if GridModOptions and GridModOptions.isCloseOnEsc and GridModOptions.isCloseOnEsc() then
            local p1 = getPlayerInventory(0)
            local p2 = getPlayerLoot(0)
            local paperDoll = GridInventory_PaperDollWindow and GridInventory_PaperDollWindow[0]
            
            local anyVisible = false
            
            -- Fechar inventário
            if p1 and p1:getIsVisible() then
                p1:setVisible(false)
                anyVisible = true
            end
            
            -- Fechar loot
            if p2 and p2:getIsVisible() then
                p2:setVisible(false)
                anyVisible = true
            end
            
            -- Fechar painel do PaperDoll
            if paperDoll and paperDoll:getIsVisible() then
                paperDoll:setVisible(false)
                anyVisible = true
            end
            
            -- Se algum painel foi fechado, abortamos a abertura do menu principal
            if anyVisible then
                return
            end
        end
        
        -- Caso contrário, abre o menu principal normalmente
        if og_ToggleEscapeMenu then
            og_ToggleEscapeMenu(key)
        end
    end

    Events.OnKeyPressed.Add(ToggleEscapeMenu)
end)
