-- wearhand_test.lua — vestir item que está na MÃO (SP e MP).
-- MP: a ação ISWearClothing não completa (isValid spama, complete() não roda);
-- o fix é o SANITIZADOR por frame (item vestido não pode estar na mão).
-- Cobre: roupa/mochila na mão + vestir, REPLACE_PRIMARY, sem categoria, guard,
-- e o sanitizador (remove da mão + CLEAR_HAND + CancelAction).

local H = require("harness")
H.setName("wearhand_test")

package = package or {}
package.preload = package.preload or {}
_G.ISBaseTimedAction = {}
_G.ItemTag = { REPLACE_PRIMARY = "ReplacePrimary" }
-- Stub de eventos (o hijack registra o sanitizador em OnPlayerUpdate)
local onPlayerUpdateCallbacks = {}
_G.Events = {
    OnPlayerUpdate = { Add = function(fn) table.insert(onPlayerUpdateCallbacks, fn) end },
    OnGameStart = { Add = function() end },
}
-- Stub do getFileWriter (não é mais usado, mas mantido pra segurança)
_G.getFileWriter = function()
    return {
        write = function() end,
        close = function() end,
    }
end
-- MP: o hijack usa sendEquip + CLEAR_HAND + CancelAction
_G.isClient = function() return true end
_G.getTimestampMs = function() return 1000 end
_G.sendEquip = function(c)
    if c and c.markEquipSync then c:markEquipSync() end
end
local gcn = {}
_G.GridClientNetwork = gcn
local clearHandCalls = 0
gcn.clearHandItem = function()
    clearHandCalls = clearHandCalls + 1
end
package.preload["Network/GridClientNetwork"] = function() return gcn end
local function clearHandCount() return clearHandCalls end

-- Stub do ISWearClothing simulando o vanilla: mochila limpa a mão, roupa NÃO.
_G.ISWearClothing = {}
function _G.ISWearClothing:complete()
    if self.item == nil then return false end
    if self.isAlreadyEquipped and self:isAlreadyEquipped(self.item) then return false end
    if self.item.hasTag and self.item:hasTag(_G.ItemTag.REPLACE_PRIMARY) then
        self.character:setPrimaryHandItem(self.item)   -- vanilla: item vira arma primária
        return true
    end
    if self.item.isWearableContainer then
        self.character:removeFromHands(self.item)   -- vanilla limpa (mochila)
        self.character:setWornItem("Back", self.item)
    elseif self.item.isClothing then
        self.character:setWornItem(self.item.bodyLocation, self.item)  -- NÃO limpa a mão
    else
        return false
    end
    return true
end
package.preload["TimedActions/ISWearClothing"] = function() return _G.ISWearClothing end

local hijackPath = H.base .. "/42.20/media/lua/client/Hooks/ISWearClothing_Hijack.lua"
assert(loadfile(hijackPath))()

local function makeCharacter(inHand, equipped)
    return {
        inHand = inHand,
        removeCalls = 0,
        equipSyncs = 0,
        resetCalls = 0,
        handModelResets = 0,
        getPrimaryHandItem = function(self) return self.inHand end,
        getSecondaryHandItem = function() return nil end,
        removeFromHands = function(self) self.removeCalls = self.removeCalls + 1; self.inHand = nil end,
        setPrimaryHandItem = function(self, it) self.inHand = it end,
        isEquippedClothing = function() return equipped end,
        setWornItem = function() end,
        markEquipSync = function(self) self.equipSyncs = self.equipSyncs + 1 end,
        resetModelNextFrame = function(self) self.resetCalls = self.resetCalls + 1 end,
        resetEquippedHandsModels = function(self) self.handModelResets = self.handModelResets + 1 end,
    }
end

local function makeAction(character, item, already)
    return {
        character = character,
        item = item,
        isAlreadyEquipped = already or function() return false end,
    }
end

-- ─── Teste 1: ROUBO na mão + vestir => mão liberada (SP: equip local) ─────────
do
    local item = { isClothing = true, isWearableContainer = false, bodyLocation = "Jacket", getID = function() return 7 end }
    local character = makeCharacter(item, true)
    local done = ISWearClothing.complete(makeAction(character, item))
    H.ok(done == true, "vestir roupa completa (done=true)")
    H.ok(character.removeCalls == 1 and character.inHand == nil,
        "mão liberada após vestir roupa [calls=" .. character.removeCalls .. "]")
    H.ok(character.equipSyncs == 1, "sendEquip chamado [syncs=" .. character.equipSyncs .. "]")
    H.ok(character.resetCalls >= 1, "modelo 3D reconstruído [resets=" .. character.resetCalls .. "]")
    H.ok(character.handModelResets >= 1, "modelo da mão rebuildado [handResets=" .. character.handModelResets .. "]")
    H.ok(clearHandCount() == 1, "CLEAR_HAND enviado pro servidor [clearHand=" .. clearHandCount() .. "]")
end

-- ─── Teste 2: MESMA roupa em MP (isEquippedClothing FALSE — atraso do server) ─
do
    local item = { isClothing = true, isWearableContainer = false, bodyLocation = "Jacket", getID = function() return 7 end }
    local character = makeCharacter(item, false)
    local done = ISWearClothing.complete(makeAction(character, item))
    H.ok(done == true, "MP: complete ainda retorna done=true")
    H.ok(character.removeCalls == 1 and character.inHand == nil,
        "MP: mão liberada mesmo com isEquippedClothing=false [calls=" .. character.removeCalls .. "]")
    H.ok(character.equipSyncs == 1, "MP: sendEquip chamado [syncs=" .. character.equipSyncs .. "]")
    H.ok(clearHandCount() == 2, "servidor notificado 2x [clearHand=" .. clearHandCount() .. "]")
end

-- ─── Teste 3: mochila vestível (vanilla já limpa) => não re-remove ────────────
do
    local item = { isClothing = false, isWearableContainer = true, getID = function() return 8 end }
    local character = makeCharacter(nil, true)
    local done = ISWearClothing.complete(makeAction(character, item))
    H.ok(done == true, "vestir mochila completa")
    H.ok(character.removeCalls == 1, "mochila: vanilla removeu; wrap não re-remove [calls=" .. character.removeCalls .. "]")
    H.ok(character.equipSyncs == 0, "item não estava na mão => sem sendEquip [syncs=" .. character.equipSyncs .. "]")
end

-- ─── Teste 3b: MOCHILA NA MÃO (bug do MP: fica segurando após vestir) ─────────
do
    local item = { isClothing = false, isWearableContainer = true, getID = function() return 8 end }
    local character = makeCharacter(item, false)
    local done = ISWearClothing.complete(makeAction(character, item))
    H.ok(done == true, "vestir mochila da mão completa")
    H.ok(character.inHand == nil, "mochila saiu da mão [inHand=" .. tostring(character.inHand) .. "]")
    H.ok(character.equipSyncs == 1, "mochila da mão => sendEquip [syncs=" .. character.equipSyncs .. "]")
    H.ok(character.handModelResets >= 1, "mochila da mão => modelo da mão rebuildado")
    H.ok(clearHandCount() == 3, "servidor notificado pra mochila da mão [clearHand=" .. clearHandCount() .. "]")
end

-- ─── Teste 4: REPLACE_PRIMARY (ex.: sprayer) fica na mão de propósito ─────────
do
    local item = { isClothing = false, isWearableContainer = false,
        hasTag = function(_, tag) return tag == "ReplacePrimary" end, getID = function() return 9 end }
    local character = makeCharacter(item, false)
    local done = ISWearClothing.complete(makeAction(character, item))
    H.ok(done == true, "REPLACE_PRIMARY completa")
    H.ok(character.removeCalls == 0 and character.inHand == item,
        "REPLACE_PRIMARY: item continua na mão [calls=" .. character.removeCalls .. "]")
end

-- ─── Teste 5: item que NÃO terminou vestido => mão NÃO é mexida ───────────────
do
    local item = { isClothing = false, isWearableContainer = false, getID = function() return 10 end }
    local character = makeCharacter(item, false)
    local done = ISWearClothing.complete(makeAction(character, item))
    H.ok(done == false, "item sem categoria completa com false")
    H.ok(character.removeCalls == 0 and character.inHand == item,
        "sem vestir => mão intocada [calls=" .. character.removeCalls .. "]")
end

-- ─── Teste 6: idempotência (guard) — segundo load não re-embrulha ─────────────
do
    local g1 = ISWearClothing.complete
    assert(loadfile(hijackPath))()
    H.ok(ISWearClothing.complete == g1, "guard impede re-embrulha no reload")
end

-- ─── Teste 7: SANITIZADOR — item VESTIDO que ainda está na MÃO é removido ───
-- (fix robusto: não depende do complete(), que no MP fica travado)
do
    local wornItem = { getID = function() return 55 end }
    local wornItems = {
        size = function() return 1 end,
        get = function() return { getItem = function() return wornItem end } end,
    }
    local handItem = wornItem -- mesmo objeto: vestido E na mão
    local character = makeCharacter(handItem, false)
    character.getWornItems = function() return wornItems end
    character.getPlayerNum = function() return 0 end
    _G.getPlayer = function() return character end
    local cancelCalls = 0
    _G.CancelAction = function() cancelCalls = cancelCalls + 1 end

    -- Sanitizador roda a cada 10 ticks; chama 10x pra disparar
    for _ = 1, 10 do
        for _, fn in ipairs(onPlayerUpdateCallbacks) do
            fn(character)
        end
    end

    H.ok(character.inHand == nil, "sanitizador: item vestido saiu da mão [inHand=" .. tostring(character.inHand) .. "]")
    H.ok(clearHandCount() == 4, "sanitizador: CLEAR_HAND enviado pro servidor [clearHand=" .. clearHandCount() .. "]")
    H.ok(cancelCalls == 1, "sanitizador: CancelAction chamado pra liberar a animação presa [cancel=" .. cancelCalls .. "]")
    _G.getPlayer = nil
end

H.finish()
