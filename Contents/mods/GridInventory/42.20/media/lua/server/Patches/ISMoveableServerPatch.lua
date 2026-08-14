--- ISMoveableServerPatch.lua
--- Espelho server-side dos patches client-only de móveis (ISMoveableSpriteProps_Patch
--- e ISMoveableCursor_Patch).
---
--- POR QUE EXISTE: no MP o servidor é a autoridade do place. O fluxo do vanilla:
---   ISMoveablesAction:complete() (SERVIDOR) -> placeMoveableViaCursor ->
---   placeMoveable -> findInInventory / findInInventoryMultiSprite.
--- Os patches client-side fazem findInInventory/.../getInventoryObjectList procurar
--- TAMBÉM nas mãos e no inventário (o GridInventory segura móveis grandes nas
--- mãos e o place desequipa o móvel pro inventário antes de colocar). Sem o
--- espelho, no servidor as versões VANILLA continuavam EXCLUINDO itens nas mãos
--- (ISMoveableSpriteProps.lua ~955 e ISMoveableCursor.lua ~881), então o
--- servidor nunca encontrava o móvel e o place falhava silenciosamente.
---
--- Aqui espelhamos os mesmos overrides no servidor: procurar o móvel nas mãos
--- e no inventário (e no chão ao redor, para multi-sprite). Sem UI, só lógica.

if not isServer() then return end

Events.OnGameStart.Add(function()
    if not ISMoveableSpriteProps then
        print("[GridInventory] ERRO CRÍTICO: ISMoveableSpriteProps não encontrado (server)!")
        return
    end

local function getAllMoveables(playerObj, resultList)
    if not playerObj then return end
    local seen = {}

    local primary = playerObj.getPrimaryHandItem and playerObj:getPrimaryHandItem()
    if primary and instanceof(primary, "Moveable") and not seen[primary] then
        table.insert(resultList, primary)
        seen[primary] = true
    end

    local secondary = playerObj.getSecondaryHandItem and playerObj:getSecondaryHandItem()
    if secondary and secondary ~= primary and instanceof(secondary, "Moveable") and not seen[secondary] then
        table.insert(resultList, secondary)
    end
end

local function worldSpriteMatches(item, _spriteName)
    if not item or not _spriteName then return false end
    local ws = item.getWorldSprite and item:getWorldSprite()
    if not ws then return false end
    if ws == _spriteName then return true end
    local worldSprite = getSprite(ws)
    if worldSprite and worldSprite.getSpriteGrid and worldSprite:getSpriteGrid() then
        local anchor = worldSprite:getSpriteGrid():getAnchorSprite()
        if anchor and anchor.getName and anchor:getName() == _spriteName then
            return true
        end
    end
    return false
end

    function ISMoveableSpriteProps:findInInventory( _character, _spriteName )
        if not _character or not _spriteName then return end

        local allItems = {}
        getAllMoveables(_character, allItems)

        for _, item in ipairs(allItems) do
            if worldSpriteMatches(item, _spriteName) then
                return item
            end
        end

        -- Inventário COMPLETO (inclui mãos/vestidos): quando o place exige
        -- ferramenta (ex: martelo), o vanilla walkToAndEquip equipa a
        -- ferramenta na mão primária, DESEQUIPANDO o móvel que estava lá —
        -- o móvel volta pro inventário. Sem essa busca o servidor não
        -- encontra o móvel (mãos agora têm o martelo).
        if _character.getInventory then
            local items = _character:getInventory():getItems()
            if items then
                for i=0,items:size()-1 do
                    local item = items:get(i)
                    if item and instanceof(item, "Moveable") and worldSpriteMatches(item, _spriteName) then
                        return item
                    end
                end
            end
        end

        -- Floor search: necessário pra multi-sprite -- a outra peça (ex: "armario 2/2")
        -- pode estar no chão enquanto o jogador segura só a primeira na mão.
        -- Também previne o crash vanilla quando o item já está no chão.
        local radius = ISMoveableSpriteProps.multiSpriteFloorRadius or 2
        local square = _character.getSquare and _character:getSquare()
        if square then
            local sx,sy,sz = square:getX(), square:getY(), square:getZ()
            for x = sx-radius,sx+radius do
                for y = sy-radius,sy+radius do
                    local sq = getCell() and getCell():getGridSquare(x,y,sz)
                    if sq and sq:getWorldObjects() then
                        local items = sq:getWorldObjects()
                        for i=0,items:size()-1 do
                            local wo = items:get(i)
                            if instanceof(wo, "IsoWorldInventoryObject") then
                                local item = wo.getItem and wo:getItem()
                                if item and instanceof(item, "Moveable") and worldSpriteMatches(item, _spriteName) then
                                    return item
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

        local function itemMatches(item)
            if not item then return false end
            if self.customItem and item.getFullType and item:getFullType() == self.customItem and item.getName and item:getName() == self.name then
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
                return item, item.getContainer and item:getContainer() or _character:getInventory()
            end
        end

        -- Inventário completo (inclui mãos/vestidos): o walkToAndEquip pode ter
        -- desequipado o móvel pra equipar a ferramenta — o móvel volta pro
        -- inventário. Sem essa busca o servidor não encontra a peça.
        if _character.getInventory then
            local items = _character:getInventory():getItems()
            if items then
                for i=0,items:size()-1 do
                    local item = items:get(i)
                    if item and instanceof(item, "Moveable") and itemMatches(item) then
                        return item, item.getContainer and item:getContainer() or _character:getInventory()
                    end
                end
            end
        end

        -- Vanilla logic for searching the floor around the player
        local radius = ISMoveableSpriteProps.multiSpriteFloorRadius
        local square = _character.getSquare and _character:getSquare()
        if square then
            local sx,sy,sz = square:getX(), square:getY(), square:getZ()
            for x = sx-radius,sx+radius do
                for y = sy-radius,sy+radius do
                    local sq = getCell() and getCell():getGridSquare(x,y,sz)
                    if sq and sq:getWorldObjects() then
                        local items = sq:getWorldObjects()
                        for i=0,items:size()-1 do
                            local wo = items:get(i)
                            if instanceof(wo, "IsoWorldInventoryObject") then
                                local item = wo.getItem and wo:getItem()
                                if item and instanceof(item, "Moveable") then
                                    if itemMatches(item) then
                                        return item, "floor"
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- ISMoveableCursor:getInventoryObjectList — no modo "place" o isValid do
    -- servidor (cannotCreate) usa essa lista para achar o móvel nas mãos.
    if ISMoveableCursor then
        function ISMoveableCursor:getInventoryObjectList()
            local objects           = {}
            local spriteBuffer      = {}

            local allItems = {}
            if self.character then
                getAllMoveables(self.character, allItems)
            end

            for _, item in ipairs(allItems) do
                local moveProps = ISMoveableSpriteProps.new(item:getWorldSprite())
                if moveProps and moveProps.isMoveable then
                    local ignoreMulti = false
                    if moveProps.isMultiSprite then
                        local anchorSprite = moveProps.sprite:getSpriteGrid():getAnchorSprite()
                        if spriteBuffer[anchorSprite] then
                            ignoreMulti = true
                        else
                            spriteBuffer[anchorSprite] = true
                            if moveProps.sprite ~= anchorSprite then
                                moveProps = ISMoveableSpriteProps.new(anchorSprite)
                            end
                        end
                    end
                    if not ignoreMulti then
                        table.insert(objects, { object = item, moveProps = moveProps })
                        if self.cacheInvObjectSprite and self.cacheInvObjectSprite == item:getWorldSprite() then
                            self.objectIndex = #objects
                        end
                    end
                end
            end

            if self.tryInitialInvItem then
                if instanceof(self.tryInitialInvItem, "Moveable") then
                    local moveProps = ISMoveableSpriteProps.new(self.tryInitialInvItem:getWorldSprite())
                    local sprite = moveProps.sprite
                    if moveProps.isMultiSprite then
                        local spriteGrid = moveProps.sprite:getSpriteGrid()
                        if spriteGrid then
                            sprite = spriteGrid:getAnchorSprite()
                        end
                    end
                    if sprite then
                        local spriteName = sprite:getName()
                        for index,tableData in ipairs(objects) do
                            if tableData.moveProps.sprite == sprite then
                                self.objectIndex = index
                                self.cacheInvObjectSprite = spriteName
                                break
                            end
                        end
                    end
                end
                self.tryInitialInvItem = nil
            end

            return objects
        end
    end
end)
