--- ISWearClothing_Hijack.lua
--- O GridInventory permite segurar QUALQUER item nas mãos (espaço extra, já que
--- o inventário é reduzido). O problema: o vanilla ISWearClothing:complete()
--- só limpa as mãos no ramo de mochila/container vestível
--- (`removeFromHands`), NÃO no ramo de roupas (categoria "Clothing"). Então uma
--- roupa segurada na mão e depois VESTIDA ficava VESTIDA e TAMBÉM na mão.
---
--- Detecção de "item vestido": NÃO usar isEquippedClothing/isAlreadyEquipped.
--- Em MP o equip é aplicado no servidor com atraso (round-trip), então no
--- cliente esses dois retornam false no momento do complete(). A única fonte
--- confiável é o retorno do complete() vanilla: só é true quando o item foi
--- realmente equipado (ou virou arma primária REPLACE_PRIMARY). Portanto:
--- se `done == true` e o item continua na mão e NÃO é REPLACE_PRIMARY, a mão
--- é liberada (no-op caso contrário).

require "TimedActions/ISWearClothing"

GridInventory_WearClothingInstalled = GridInventory_WearClothingInstalled or false
if not GridInventory_WearClothingInstalled and ISWearClothing and ISWearClothing.complete then
    GridInventory_WearClothingInstalled = true
    local og_wearClothingComplete = ISWearClothing.complete
    function ISWearClothing:complete()
        -- Item estava na MÃO antes do vanilla? (o vanilla remove a mochila/
        -- container da mão ao vestir, mas o render 3D pode ficar com a mão
        -- "fantasma" segurando o item — ex.: mochila equipada nas costas que
        -- continua aparecendo na mão no boneco 3D).
        local wasInHand = false
        if self.character and self.item then
            local primary = self.character.getPrimaryHandItem and self.character:getPrimaryHandItem()
            local secondary = self.character.getSecondaryHandItem and self.character:getSecondaryHandItem()
            wasInHand = (primary == self.item or secondary == self.item)
        end

        local done = og_wearClothingComplete(self)

        -- Item terminou vestido E continua na mão? Libera a mão.
        if done and self.character and self.item then
            local isReplacement = self.item.hasTag and ItemTag and self.item:hasTag(ItemTag.REPLACE_PRIMARY)
            local primary = self.character.getPrimaryHandItem and self.character:getPrimaryHandItem()
            local secondary = self.character.getSecondaryHandItem and self.character:getSecondaryHandItem()
            if (primary == self.item or secondary == self.item) and not isReplacement then
                self.character:removeFromHands(self.item)
            end

            -- Item estava na mão e foi vestido: o vanilla NÃO sincroniza a mão
            -- vazia no MP (só o ISUnequipAction chama sendEquip). Sem isso o
            -- servidor mantém o item na mão e o boneco 3D continua "segurando"
            -- a mochila/roupa que acabou de ser vestida.
            if wasInHand and not isReplacement then
                local c = self.character
                if isClient and isClient() and sendEquip then
                    sendEquip(c)
                end
                -- Força o rebuild do modelo 3D (limpa o visual fantasma da mão).
                if c.resetModelNextFrame then
                    c:resetModelNextFrame()
                elseif c.resetModel then
                    c:resetModel()
                end
            end
        end

        return done
    end
end
