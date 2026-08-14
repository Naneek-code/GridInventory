-- paperdoll_test.lua — slot "Extra" (overflow) do PaperDoll.
-- Regressão do commit c2fe977: o overflowSlot entrou em self.slots (pro relayout
-- reposicionar), mas o refreshOverflow itera self.slots pra montar o
-- fixedSlotsMap (itens que JÁ estão visíveis nos slots). Como o overflowSlot
-- retorna o itemsList ANTERIOR, os próprios itens do overflow viram "fixos" e
-- o addIfMissing os pula — o item some num refresh e volta no outro.

local H = require("harness")
H.setName("paperdoll_test")

-- Stubs mínimos pra carregar o PaperDollWindow.lua real.
_G.ISPanel = {}
local ISCollapsableWindow = {}
function ISCollapsableWindow:derive(name)
    local cls = {}
    cls.__index = cls
    setmetatable(cls, { __index = self })
    _G[name] = cls
    return cls
end
_G.ISCollapsableWindow = ISCollapsableWindow
_G.ISCharacterScreenAvatar = {}
_G.IsoDirections = { S = "S" }
_G.getText = function(t) return t end
_G.getTextOrNull = function(t) return t end
_G.getSpecificPlayer = function() return nil end
_G.getPlayerInventory = function() return nil end
_G.getPlayerLoot = function() return nil end
_G.getPlayerHotbar = function() return nil end
_G.getTimestampMs = function() return 0 end
_G.isClient = function() return false end

package.preload["ISUI/ISCollapsableWindow"] = function() return _G.ISCollapsableWindow end
package.preload["XpSystem/ISUI/ISCharacterScreen"] = function() return _G.ISCharacterScreenAvatar end
package.preload["UI/PaperDoll/AvatarUseDropZone"] = function() return {} end
package.preload["UI/PaperDoll/PaperDollSlot"] = function()
    return {
        derive = function() return {} end,
        new = function() return {} end,
    }
end

local pwPath = H.base .. "/42.20/media/lua/client/UI/PaperDoll/PaperDollWindow.lua"
assert(loadfile(pwPath))()
local PaperDollWindow = _G.PaperDollWindow

-- ─── Teste: item do overflow NÃO pode sumir entre refreshes ─────────────────
-- O bug: 1º refresh mostra o item; 2º refresh some (o overflowSlot em
-- self.slots marca os próprios itens como fixedSlotsMap); 3º refresh volta.
do
    local w = {}
    w.overflowSlot = {}
    w.overflowSlot.itemsList = {}
    w.overflowSlot.getEquippedItems = function(self) return self.itemsList end
    -- overflowSlot em self.slots (commit c2fe977) + um slot fixo fake
    w.slots = { w.overflowSlot }

    local wornItem = { getID = function() return 1 end }
    local wornItems = {
        size = function() return 1 end,
        get = function(i) return { getItem = function() return wornItem end } end,
    }

    local function refresh()
        PaperDollWindow.refreshOverflow(w, wornItems, nil, nil)
    end

    refresh()
    H.ok(#w.overflowSlot.itemsList == 1,
        "1º refresh: item aparece no overflow [n=" .. #w.overflowSlot.itemsList .. "]")

    refresh()
    H.ok(#w.overflowSlot.itemsList == 1,
        "2º refresh: item CONTINUA no overflow (bug: sumia) [n=" .. #w.overflowSlot.itemsList .. "]")

    refresh()
    H.ok(#w.overflowSlot.itemsList == 1,
        "3º refresh: item estável no overflow [n=" .. #w.overflowSlot.itemsList .. "]")
end

H.finish()
