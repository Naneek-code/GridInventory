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

        local function spriteMatches( item )
            if not item or not item.getWorldSprite then return false end
            local ws = item:getWorldSprite();
            if not ws then return false end
            if ws == _spriteName then return true end
            local worldSprite = getSprite(ws);
            if worldSprite and worldSprite.getSpriteGrid and worldSprite:getSpriteGrid() and worldSprite:getSpriteGrid():getAnchorSprite() and worldSprite:getSpriteGrid():getAnchorSprite():getName() == _spriteName then
                return true;
            end
            return false;
        end

        -- 1) Mãos: móveis grandes segurados pelo jogador (GridInventory).
        local allItems = {}
        getAllMoveables(_character, allItems)
        for _, item in ipairs(allItems) do
            if spriteMatches(item) then
                return item;
            end
        end

        -- 2) Inventário COMPLETO (inclui mãos/vestidos): quando o place exige
        --    ferramenta (ex: martelo), o vanilla walkToAndEquip equipa a
        --    ferramenta na mão primária, DESEQUIPANDO o móvel que estava lá —
        --    o móvel volta pro inventário. Sem essa busca o servidor não
        --    encontra o móvel (mãos agora têm o martelo).
        if _character.getInventory then
            local items = _character:getInventory():getItems();
            if items then
                for i=0,items:size()-1 do
                    local item = items:get(i);
                    if item and instanceof(item, "Moveable") and spriteMatches(item) then
                        return item;
                    end
                end
            end
        end

        -- 3) Floor search: necessário pra multi-sprite -- a outra peça (ex: "armario 2/2")
        --    pode estar no chão enquanto o jogador segura só a primeira na mão.
        --    Também previne o crash vanilla quando o item já está no chão.
        local radius = ISMoveableSpriteProps.multiSpriteFloorRadius or 2;
        local square = _character.getSquare and _character:getSquare();
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
                                local item = wo.getItem and wo:getItem();
                                if item and instanceof(item, "Moveable") and spriteMatches(item) then
                                    return item;
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
        
        local function itemMatches( item )
            if not item then return false end
            if self.customItem and item.getFullType and (item:getFullType() == self.customItem) and item.getName and (item:getName() == self.name) then
                return true
            end
            if item.getCustomNameFull and item:getCustomNameFull() == _spriteName then
                return true
            end
            return false
        end

        local allItems = {}
        getAllMoveables(_character, allItems)
        
        for _, item in ipairs(allItems) do
            if itemMatches(item) then
                return item, item:getContainer() or _character:getInventory()
            end
        end

        -- Inventário completo (inclui mãos/vestidos): o walkToAndEquip pode ter
        -- desequipado o móvel pra equipar a ferramenta — o móvel volta pro
        -- inventário. Sem essa busca o servidor não encontra a peça.
        if _character.getInventory then
            local items = _character:getInventory():getItems();
            if items then
                for i=0,items:size()-1 do
                    local item = items:get(i);
                    if item and instanceof(item, "Moveable") and itemMatches(item) then
                        return item, item.getContainer and item:getContainer() or _character:getInventory()
                    end
                end
            end
        end

        -- Vanilla logic for searching the floor around the player
        local radius = ISMoveableSpriteProps.multiSpriteFloorRadius;
        local square = _character.getSquare and _character:getSquare();
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
                                local item = wo.getItem and wo:getItem();
                                if item and instanceof(item, "Moveable") and itemMatches(item) then
                                    return item, "floor";
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end)