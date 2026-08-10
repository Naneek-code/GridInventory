--- ISWearClothing_Hijack.lua
---
--- PROBLEMA (MP): segurar um item na mão (bolsa/roupa) e depois VESTIR ele
--- deixava o item no estado correto (paperdoll mostra vestido) mas o modelo 3D
--- continuava "segurando" ele na mão.
---
--- CAUSA: no MP a ação ISWearClothing NÃO COMPLETA no cliente (isValid spama e
--- complete() nunca roda) — o personagem fica congelado na animação
--- "WearClothing" segurando o item. Por isso a mão nunca era limpa nem no
--- estado (roupa) nem no render 3D (mochila).
---
--- FIX: um sanitizador que roda por frame garante o INVARIANTE "nenhum item
--- pode estar VESTIDO e NA MÃO ao mesmo tempo". Quando detecta o estado
--- inválido:
---  1) tira da mão (local + servidor via CLEAR_HAND + sendEquip);
---  2) rebuilda o modelo da mão (resetEquippedHandsModels);
---  3) CANCELA a ação presa (CancelAction, cooldown) — libera a animação e o
---     personagem larga o item no render 3D.
--- Também mantemos a override do complete() (limpa a mão caso a ação complete
--- normalmente) e o CLEAR_HAND server-side (GridServerNetwork) como autoridade.

require "TimedActions/ISWearClothing"
local GridClientNetwork = require("Network/GridClientNetwork")

-- ============================================================================
-- SANITIZADOR: item vestido não pode estar na mão.
-- Roda a cada ~10 frames pro jogador local (barato: poucos itens vestidos).
-- ============================================================================
local sanitizeTick = 0
local lastCancelAt = {} -- cooldown por itemId (ms)
local function sanitizeWornInHand(playerObj)
    if not playerObj or not playerObj.getWornItems then return end
    local primary = playerObj.getPrimaryHandItem and playerObj:getPrimaryHandItem()
    local secondary = playerObj.getSecondaryHandItem and playerObj:getSecondaryHandItem()
    if not primary and not secondary then return end

    local worn = playerObj:getWornItems()
    if not worn then return end
    for i = 0, worn:size() - 1 do
        local wi = worn:get(i)
        if wi and wi.getItem then
            local witem = wi:getItem()
            if witem and (witem == primary or witem == secondary) then
                playerObj:removeFromHands(witem)
                if GridClientNetwork and GridClientNetwork.clearHandItem and witem.getID then
                    GridClientNetwork.clearHandItem(witem:getID())
                end
                if sendEquip then sendEquip(playerObj) end
                if playerObj.resetEquippedHandsModels then
                    playerObj:resetEquippedHandsModels()
                end

                -- Cancela a ação presa (cooldown 5s por item pra não ficar
                -- cancelando outras ações do jogador à toa).
                local now = getTimestampMs and getTimestampMs() or 0
                local last = lastCancelAt[witem:getID()]
                if not last or (now - last) > 5000 then
                    lastCancelAt[witem:getID()] = now
                    local num = playerObj.getPlayerNum and playerObj:getPlayerNum()
                    if num ~= nil and CancelAction then
                        CancelAction(num)
                    end
                end

                if playerObj.resetModelNextFrame then
                    playerObj:resetModelNextFrame()
                elseif playerObj.resetModel then
                    playerObj:resetModel()
                end
            end
        end
    end
end

Events.OnPlayerUpdate.Add(function(playerObj)
    sanitizeTick = sanitizeTick + 1
    if sanitizeTick % 10 ~= 0 then return end
    local localPlayer = getPlayer and getPlayer()
    if playerObj and localPlayer and playerObj == localPlayer then
        sanitizeWornInHand(playerObj)
    end
end)

-- ============================================================================
-- Override do complete(): se a ação COMPLETAR normalmente, limpa a mão quando
-- o item segurado foi vestido (no vanilla, roupa vestida da mão fica na mão).
-- ============================================================================
GridInventory_WearClothingInstalled = GridInventory_WearClothingInstalled or false
if not GridInventory_WearClothingInstalled and ISWearClothing and ISWearClothing.complete then
    GridInventory_WearClothingInstalled = true
    local og_wearClothingComplete = ISWearClothing.complete
    function ISWearClothing:complete()
        local c = self.character
        local item = self.item
        if not c or not item then
            return og_wearClothingComplete(self)
        end

        local wasInHand = false
        if c.getPrimaryHandItem then
            local primary = c:getPrimaryHandItem()
            local secondary = c.getSecondaryHandItem and c:getSecondaryHandItem()
            wasInHand = (primary == item or secondary == item)
        end

        local done = og_wearClothingComplete(self)

        if done then
            local isReplacement = item.hasTag and ItemTag and item:hasTag(ItemTag.REPLACE_PRIMARY)
            if not isReplacement then
                local primary = c.getPrimaryHandItem and c:getPrimaryHandItem()
                local secondary = c.getSecondaryHandItem and c:getSecondaryHandItem()
                local removedLocal = false
                if primary == item or secondary == item then
                    c:removeFromHands(item)
                    removedLocal = true
                end
                if (wasInHand or removedLocal) then
                    if isClient and isClient() then
                        if GridClientNetwork and GridClientNetwork.clearHandItem and item.getID then
                            GridClientNetwork.clearHandItem(item:getID())
                        end
                        if sendEquip then sendEquip(c) end
                        if c.resetEquippedHandsModels then c:resetEquippedHandsModels() end
                    end
                    if c.resetModelNextFrame then
                        c:resetModelNextFrame()
                    elseif c.resetModel then
                        c:resetModel()
                    end
                end
            end
        end

        return done
    end
end
