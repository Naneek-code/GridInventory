--- ISMoveableCursor_Patch.lua
--- Continuação do patch para móveis: permite que o cursor de placement
--- encontre e acesse itens (Moveables) que estão equipados nas mãos,
--- e garante que o place não dependa do móvel estar nas mãos (MP).

Events.OnGameStart.Add(function()
    if not ISMoveableCursor then
        print("[GridInventory] ERRO CRÍTICO: ISMoveableCursor não encontrado!")
        return
    end

local GridClientNetwork = GridClientNetwork
if not GridClientNetwork then
    local ok, mod = pcall(require, "Network/GridClientNetwork")
    if ok then GridClientNetwork = mod end
end

    local function getAllMoveables(playerObj, resultList)
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

    -- File-level (não closure por frame): verifica se o móvel está nas MÃOS do
    -- jogador. Só mãos contam — sem containers, sem chão. Reusa getAllMoveables.
    local function isItemOnPlayer(pObj, checkItem)
        local all = {}
        getAllMoveables(pObj, all)
        for _, i in ipairs(all) do
            if i == checkItem then return true end
        end
        return false
    end

    -- Buffer reutilizado pra cor de highlight do modo scrap (evita alocar uma
    -- tabela nova por frame no isValid).
    local scrapColorBuffer = { r = 1, g = 1, b = 1 }

    function ISMoveableCursor:getInventoryObjectList()
    local objects           = {};
    local spriteBuffer      = {};
    
    local allItems = {}
    if self.character then
        getAllMoveables(self.character, allItems)
    end
    
    for _, item in ipairs(allItems) do
        -- A restrição vanilla "if self.character:getPrimaryHandItem() ~= item" foi REMOVIDA
        -- para permitir mobílias grandes que o jogador precise carregar nas mãos.
        
        local moveProps = ISMoveableSpriteProps.new( item:getWorldSprite() );
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
                table.insert(objects, { object = item, moveProps = moveProps });
                if self.cacheInvObjectSprite and self.cacheInvObjectSprite == item:getWorldSprite() then
                    self.objectIndex = #objects;
                end
            end
        end
    end

    if self.tryInitialInvItem then
        if instanceof(self.tryInitialInvItem, "Moveable") then
            local moveProps = ISMoveableSpriteProps.new(self.tryInitialInvItem:getWorldSprite());
            local sprite = moveProps.sprite;
            if moveProps.isMultiSprite then
                local spriteGrid = moveProps.sprite:getSpriteGrid();
                if spriteGrid then
                    sprite = spriteGrid:getAnchorSprite();
                end
            end
            if sprite then
                local spriteName = sprite:getName();
                for index,tableData in ipairs(objects) do
                    if tableData.moveProps.sprite == sprite then
                        self.objectIndex = index;
                        self.cacheInvObjectSprite = spriteName;
                        break;
                    end
                end
            end
        end
        self.tryInitialInvItem = nil;
    end

    return objects;
end

function ISMoveableCursor:isValid( _square )
    self.currentMoveProps   = nil;
    self.origMoveProps      = nil;
    self.canCreate          = nil;
    self.objectSprite       = nil;
    self.origSpriteName     = nil;
    self.colorMod           = ISMoveableSpriteProps.invalidColor;
    self.yOffset            = 0;

    -- Hoist do modo atual: self.player não muda durante uma chamada; evita
    -- resolver ISMoveableCursor.mode[self.player] várias vezes por frame.
    local mode = ISMoveableCursor.mode[self.player];

    if mode == "pickup" or mode == "rotate" then
        self.objectIndex    = self.currentSquare ~= _square and -1 or self.objectIndex;
    end
    if _square ~= self.currentSquare then
        self.objectListCache = nil;
    end
    self.currentSquare  = _square;

    --if self.currentSquare == nil or not self.currentSquare:isCouldSee(self.player) then
    if self.currentSquare == nil then
        self:setInfoPanel( _square, nil, nil );
        self.cursorFacing = nil;
        self.joypadFacing = nil;
        return false;
    end

    if getPlayerRadialMenu(self.player) and getPlayerRadialMenu(self.player):isReallyVisible() then
        self:setInfoPanel( _square, nil, nil )
        self.cursorFacing = nil
        self.joypadFacing = nil
        return false
    end

    if self.character:getCharacterActions():isEmpty() and not self.character:isSittingOnFurniture() then
        self.character:faceLocation(_square:getX(), _square:getY())
    end

    self.canSeeCurrentSquare = _square and _square:isCouldSee(self.player);

    if mode == "pickup" then
        local objects = self.objectListCache or self:getObjectList();
        self.objectListCache = objects;

        if #objects > 0 then
            if self.objectIndex > #objects or self.objectIndex < 1 then self.objectIndex = 1 end
            if self.objectIndex >= 1 and self.objectIndex <= #objects then
                local object = not objects[self.objectIndex].isWall and objects[self.objectIndex].object or nil;
                local moveProps = objects[self.objectIndex].moveProps;

                if moveProps and moveProps.sprite then
                    --self:setInfoPanel( _square, object, moveProps );
                    self.currentMoveProps   = moveProps;
                    self.origMoveProps      = moveProps;
                    self.canCreate          = moveProps:canPickUpMoveable( self.character, _square, object );
                    self.colorMod           = ISMoveableCursor.normalColor; --self.canCreate and ISMoveableCursor.normalColor or ISMoveableCursor.invalidColor;
                    self.objectSprite       = nil; --moveProps.sprite; disabled object sprite for pickup
                    self.origSpriteName     = moveProps.spriteName;
                    --self.cursorFacing = nil;
                    self.yOffset            = moveProps:getYOffsetCursor(); -- this is updated in moveprops in canPickUpMoveable function
                    self.isWallLike = moveProps.type == "Window"
                    self.nSprite = moveProps.spriteProps:has(IsoFlagType.WindowN) and 2 or 1
                    self:setInfoPanel( _square, object, moveProps );
                    return true;
                end
            end
        end
    elseif mode == "place" then
        local objects = self.objectListCache or self:getInventoryObjectList();
        self.objectListCache = objects;

        if #objects > 0 then
            if self.objectIndex > #objects or self.objectIndex < 1 then self.objectIndex = 1 end
            if self.objectIndex >= 1 and self.objectIndex <= #objects then
                local item = objects[self.objectIndex].object;
                local playerObj = getSpecificPlayer(self.player)
                
                if not isItemOnPlayer(playerObj, item) then
                    return false
                end
                local moveProps = objects[self.objectIndex].moveProps;
                self.origMoveProps = moveProps;
                local origName = moveProps.spriteName;

                if moveProps and moveProps:hasFaces() then
                    local faceIndex = self.cursorFacing or moveProps:snapFaceToSquare( _square );
                    if faceIndex and moveProps:getIndexedFaces()[faceIndex] then
                        local tryMoveProps = ISMoveableSpriteProps.new( moveProps:getIndexedFaces()[faceIndex] );
                        if tryMoveProps and tryMoveProps.isMoveable and tryMoveProps.sprite then
                            --self.faceIndex = faceIndex;
                            moveProps = tryMoveProps;
                        end
                    end
                end

                if moveProps and moveProps.sprite then
                    --self:setInfoPanel( _square, item, moveProps );
                    self.currentMoveProps       = moveProps;
                    self.canCreate              = moveProps:canPlaceMoveable( self.character, _square, item );
                    self.colorMod               = self.canCreate and ISMoveableCursor.normalColor or ISMoveableCursor.invalidColor;
                    self.cacheInvObjectSprite   = item:getWorldSprite();
                    self.objectSprite           = moveProps.sprite;
                    self.origSpriteName         = origName;
                    --self.cursorFacing = nil;
                    self.yOffset                = moveProps:getYOffsetCursor(); -- this is updated in moveprops in canPlaceMoveable function
                    self.isWallLike = moveProps.type == "Window"
                    self.nSprite = moveProps.spriteProps:has(IsoFlagType.WindowN) and 2 or 1
                    self:setInfoPanel( _square, item, moveProps );

                    return true;
                end

            end
        end
    elseif mode == "rotate" then
        local rotateObject = self.objectListCache or self:getRotateableObject();
        self.objectListCache = rotateObject;
        if rotateObject then
            local object = rotateObject.object;
            local moveProps = rotateObject.moveProps;
            self.origMoveProps = moveProps;
            local origProps = moveProps;
            local origName = moveProps.spriteName;
            if moveProps and moveProps:hasFaces() then
                local faces = moveProps:getIndexedFaces();

                if self.objectIndex < 1 then
                    self.objectIndex = moveProps:getFaceIndex();
                end

                if self.objectIndex > #faces or self.objectIndex < 1 then self.objectIndex = 1 end
                local faceIndex = self.cursorFacing or self.objectIndex;

                if faceIndex >= 1 and faceIndex <= #faces and faces[faceIndex] then
                    local tryMoveProps = ISMoveableSpriteProps.new( faces[faceIndex] );
                    if tryMoveProps and tryMoveProps.isMoveable and tryMoveProps.sprite then
                        --self.faceIndex = faceIndex;
                        moveProps = tryMoveProps;
                    end
                end

                if moveProps and moveProps.sprite then
                    --self:setInfoPanel( _square, object, moveProps, faces[faceIndex] );
                    self.currentMoveProps   = moveProps;
                    self.canCreate          = moveProps:canRotateMoveable( _square, object, origProps ); --FIXME
                    self.colorMod           = self.canCreate and ISMoveableCursor.normalColor or ISMoveableCursor.invalidColor; --ISMoveableCursor.normalColor;
                    self.objectSprite       = moveProps.sprite;
                    self.origSpriteName     = origName;
                    self.yOffset            = moveProps:getYOffsetCursor();
                    self:setInfoPanel( _square, object, moveProps, faces[faceIndex] );
                    --self.cursorFacing = nil;
                    return true;
                end
            end
            if moveProps and moveProps.sprite and moveProps:canRotateDirection() then
                self.currentMoveProps   = moveProps;
                self.canCreate          = moveProps:canRotateMoveable( _square, object, origProps );
                self.colorMod           = self.canCreate and ISMoveableCursor.normalColor or ISMoveableCursor.invalidColor;
                self.objectSprite       = moveProps.sprite;
                self.origSpriteName     = origName;
                self.yOffset            = moveProps:getYOffsetCursor();
                self:setInfoPanel( _square, object, moveProps );
                return true;
            end
        end
    elseif mode == "scrap" then
        local objects = self.objectListCache or self:getScrapObjectList();
        self.objectListCache = objects;
        if #objects > 0 then
            if self.objectIndex > #objects or self.objectIndex < 1 then self.objectIndex = 1 end
            if self.objectIndex >= 1 and self.objectIndex <= #objects then
                local object = objects[self.objectIndex].object;
                local moveProps = objects[self.objectIndex].moveProps;
                if moveProps and moveProps.sprite then
                    self.currentMoveProps   = moveProps;
                    self.origMoveProps      = moveProps;
                    self.canCreate          = moveProps:canScrapObject( self.character ).canScrap;
                    local colorInfo = getCore():getBadHighlitedColor() -- same color as the Disassemble context menu
                    scrapColorBuffer.r = colorInfo:getR()
                    scrapColorBuffer.g = colorInfo:getG()
                    scrapColorBuffer.b = colorInfo:getB()
                    self.colorMod = scrapColorBuffer
                    self.objectSprite       = moveProps.sprite;
                    self.origSpriteName     = moveProps.spriteName;
                    self.yOffset            = moveProps:getYOffsetCursor();
                    self:setInfoPanel( _square, object, moveProps );
                    return true;
                end
            end
        end
    elseif mode == "repair" then
        local objects = self.objectListCache or self:getRepairObjectList();
        self.objectListCache = objects;
        if #objects > 0 then
            if self.objectIndex > #objects or self.objectIndex < 1 then self.objectIndex = 1 end
            if self.objectIndex >= 1 and self.objectIndex <= #objects then
                local object = objects[self.objectIndex].object;
                local moveProps = objects[self.objectIndex].moveProps;

                if moveProps and moveProps.sprite then
                    self.currentMoveProps   = moveProps;
                    self.origMoveProps      = moveProps;
                    self.canCreate          = moveProps:canRepairObject ( self.character ).canRepair;
                    self.colorMod           = ISMoveableCursor.normalColor;
                    self.objectSprite       = nil;
                    self.origSpriteName     = moveProps.spriteName;
                    self.yOffset            = moveProps:getYOffsetCursor(); -- this is updated in moveprops in canPickUpMoveable function
                    self.isWallLike         = moveProps.type == "Window"
                    self:setInfoPanel( _square, object, moveProps );
                    return true;
                end
            end
        end
    end

    self:setInfoPanel( _square, nil, nil );
    self.cursorFacing = nil;
    self.joypadFacing = nil;
    
    return false;
end

-- FIX (place em MP): o vanilla walkToAndEquip equipa a ferramenta (ex:
-- martelo) na mão primária. Se o móvel a colocar estiver na mão, o martelo
-- o desequipa e o place falha. Aqui DESEQUIPAMOS o móvel alvo da mão ANTES
-- do vanilla equipar a ferramenta: o martelo vai para a mão livre, o móvel
-- fica no inventário, e o placeMoveable (server) o encontra lá.
    local og_walkToAndEquip = ISMoveableSpriteProps.walkToAndEquip
    function ISMoveableSpriteProps:walkToAndEquip(_character, _square, _mode, _origSpriteName)
        if _mode == "place" and _character and _origSpriteName then
            local target = self:findInInventory(_character, _origSpriteName)
            if target then
                local primary = _character.getPrimaryHandItem and _character:getPrimaryHandItem()
                local secondary = _character.getSecondaryHandItem and _character:getSecondaryHandItem()
                if (primary == target) or (secondary == target) then
                    -- Tira da mão → vai pro inventário principal (overflow).
                    _character:removeFromHands(target)
                    -- Sincroniza a mão vazia com o servidor (o vanilla não
                    -- broadcasta a mão vazia no MP).
                    if GridClientNetwork and GridClientNetwork.clearHandItem and target.getID then
                        GridClientNetwork.clearHandItem(target:getID())
                    end
                    if sendEquip then sendEquip(_character) end
                end
            end
        end

        return og_walkToAndEquip(self, _character, _square, _mode, _origSpriteName)
    end

end)
