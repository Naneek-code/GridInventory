--- ISMoveableContextMenu_Patch.lua
--- Remove a restrição vanilla que exigia que móveis estivessem no inventário principal
--- desequipados para poderem ser instalados.
--- Com o GridInventory, móveis grandes não cabem no inventário principal, então
--- permitimos instalar estando nas mãos.
--- OBS: instalar a partir de mochilas/bolsos é bugado e foi desativado
--- separadamente -- este patch só libera a opção quando o item está equipado na mão.

require "ISUI/ISMoveableContextMenu"

function ISMoveableContextMenu.createMenu(context, item, playerObj)
    -- Só libera o "Instalar" se o item estiver equipado numa das mãos.
    -- Isso exclui mochilas/bolsos de propósito (ver nota acima).
    local inHand = (playerObj:getPrimaryHandItem() == item) or (playerObj:getSecondaryHandItem() == item)
    if not inHand then
        return
    end

    -- Radio bug fix (Vanilla)
    if instanceof(item, "Radio") and item:getWorldStaticItem() then
        return
    end

    -- Libera a opção de colocar (agora só quando o item está na mão)
    local option = context:addOption(getText("IGUI_PlaceObject"), item, ISMoveableContextMenu.openMovableCursor, playerObj)
    if option then
        option.itemForTexture = item
    end
end