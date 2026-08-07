--- ISMoveableSpriteProps_Patch.lua
--- Faz com que as verificações nativas de "O jogador tem esse móvel?"
--- passem a procurar nas mãos do jogador (e no chão, para multi-sprite),
--- ignorando a restrição vanilla.

Events.OnGameStart.Add(function()
    if not ISMoveableSpriteProps then
        print("[GridInventory] ERRO CRÍTICO: ISMoveableSpriteProps não encontrado!")
        return
    end

local function getAllMoveables(playerObj, resultList)
    -- Só mãos contam aqui. Containers/mochilas não são posicionáveis por design.
    local seen = {}

    local primary = playerObj:getPrimaryHandItem()
    if primary and instanceof(primary, "Moveable") and not seen[primary] then
        table.insert(resultList, primary)
        seen[primary] = true
    end

    local secondary = playerObj:getSecondaryHandItem()
    if secondary and secondary ~= primary and instanceof(secondary, "Moveable") and not seen[secondary] then
        table.insert(resultList, secondary)
    end
end

    function ISMoveableSpriteProps:findInInventory( _character, _spriteName )
        if not _character or not _spriteName then return end
        
        local allItems = {}
        getAllMoveables(_character, allItems)
        
        for _, item in ipairs(allItems) do
            if item:getWorldSprite() then
                -- Removido o check de item nas mãos!
                if (item:getWorldSprite() == _spriteName) then
                    return item;
                else
                    local worldSprite = getSprite(item:getWorldSprite());
                    if worldSprite and worldSprite:getSpriteGrid() and worldSprite:getSpriteGrid():getAnchorSprite() and worldSprite:getSpriteGrid():getAnchorSprite():getName() == _spriteName then
                        return item;
                    end
                end
            end
        end

        -- Floor search: necessário pra multi-sprite -- a outra peça (ex: "armario 2/2")
        -- pode estar no chão enquanto o jogador segura só a primeira na mão.
        -- Também previne o crash vanilla quando o item já está no chão.
        local radius = ISMoveableSpriteProps.multiSpriteFloorRadius or 2;
        local square = _character:getSquare();
        if square then
            local sx,sy,sz = square:getX(), square:getY(), square:getZ();
            for x = sx-radius,sx+radius do
                for y = sy-radius,sy+radius do
                    local sq = getCell():getGridSquare(x,y,sz);
                    if sq and sq:getWorldObjects() then
                        local items = sq:getWorldObjects();
                        for i=0,items:size()-1 do
                            local wo = items:get(i)
                            if instanceof(wo, "IsoWorldInventoryObject") then
                                local item = wo:getItem();
                                if item and instanceof(item, "Moveable") and item:getWorldSprite() then
                                    if (item:getWorldSprite() == _spriteName) then
                                        return item;
                                    else
                                        local worldSprite = getSprite(item:getWorldSprite());
                                        if worldSprite and worldSprite:getSpriteGrid() and worldSprite:getSpriteGrid():getAnchorSprite() and worldSprite:getSpriteGrid():getAnchorSprite():getName() == _spriteName then
                                            return item;
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    function ISMoveableSpriteProps:findInInventoryMultiSprite( _character, _spriteName )
        if not _character or not _spriteName then return end
        
        local allItems = {}
        getAllMoveables(_character, allItems)
        
        for _, item in ipairs(allItems) do
            if self.customItem and (item:getFullType() == self.customItem) and (item:getName() == self.name) then
                return item, item:getContainer() or _character:getInventory()
            end
            if item:getCustomNameFull() then
                -- Removido o check de item nas mãos!
                if item:getCustomNameFull() == _spriteName then
                    return item, item:getContainer() or _character:getInventory()
                end
            end
        end

        -- Vanilla logic for searching the floor around the player
        local radius = ISMoveableSpriteProps.multiSpriteFloorRadius;
        local square = _character:getSquare();
        if square then
            local sx,sy,sz = square:getX(), square:getY(), square:getZ();
            for x = sx-radius,sx+radius do
                for y = sy-radius,sy+radius do
                    local sq = getCell():getGridSquare(x,y,sz);
                    if sq and sq:getWorldObjects() then
                        local items = sq:getWorldObjects();
                        for i=0,items:size()-1 do
                            local wo = items:get(i)
                            if instanceof(wo, "IsoWorldInventoryObject") then
                                local item = wo:getItem();
                                if item and instanceof(item, "Moveable") then
                                    if self.customItem and (item:getFullType() == self.customItem) and (item:getName() == self.name) then
                                        return item, "floor";
                                    end
                                    if item:getCustomNameFull() == _spriteName then
                                        return item, "floor";
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end)