--- ISWearClothing_Hijack.lua
--- O GridInventory permite segurar QUALQUER item nas mãos (espaço extra, já que
--- o inventário é reduzido). O problema: o vanilla ISWearClothing:complete()
--- só limpa as mãos no ramo de mochila/container vestível
--- (`removeFromHands`), NÃO no ramo de roupas (categoria "Clothing"). Então uma
--- roupa segurada na mão e depois VESTIDA ficava VESTIDA e TAMBÉM na mão —
--- comportamento estranho. Aqui garantimos que, se o item terminou vestido,
--- a mão é liberada (no-op se o item não estiver na mão).

require "TimedActions/ISWearClothing"

GridInventory_WearClothingInstalled = GridInventory_WearClothingInstalled or false
if not GridInventory_WearClothingInstalled and ISWearClothing and ISWearClothing.complete then
    GridInventory_WearClothingInstalled = true
    local og_wearClothingComplete = ISWearClothing.complete
    function ISWearClothing:complete()
        local done = og_wearClothingComplete(self)

        -- Item terminou vestido (roupa OU container vestível)? Libera a mão.
        if self.character and self.item then
            local isWorn = self.character.isEquippedClothing and self.character:isEquippedClothing(self.item)
                or (self.isAlreadyEquipped and self:isAlreadyEquipped(self.item))
            if isWorn then
                self.character:removeFromHands(self.item)
            end
        end

        return done
    end
end
