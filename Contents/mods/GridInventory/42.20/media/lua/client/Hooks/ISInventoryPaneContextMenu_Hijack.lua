--- ISInventoryPaneContextMenu_Hijack.lua
--- Como o mod transforma o inventário, o loot e o PaperDoll num conjunto de
--- tela cheia, ao usar "Place Item" (posicionar item 3D no chão) precisamos
--- fechar esses painéis para liberar a visão do mundo.

require "ISUI/ISInventoryPaneContextMenu"

local og_onPlaceItemOnGround = ISInventoryPaneContextMenu.onPlaceItemOnGround

function ISInventoryPaneContextMenu.onPlaceItemOnGround(items, playerObj)
    local playerNum = playerObj:getPlayerNum()

    -- Fecha os painéis do GridInventory para deixar a tela livre para o cursor 3D
    local pInv = getPlayerInventory(playerNum)
    local pLoot = getPlayerLoot(playerNum)
    local paperDoll = GridInventory_PaperDollWindow and GridInventory_PaperDollWindow[playerNum]

    if pInv and pInv:getIsVisible() then pInv:setVisible(false) end
    if pLoot and pLoot:getIsVisible() then pLoot:setVisible(false) end
    if paperDoll and paperDoll:getIsVisible() then paperDoll:setVisible(false) end

    og_onPlaceItemOnGround(items, playerObj)
end
