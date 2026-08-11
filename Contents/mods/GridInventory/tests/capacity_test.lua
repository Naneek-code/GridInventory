-- capacity_test.lua — teto de PESO real (gridCapacity).
-- O inventário do jogador mostra getMaxWeight() = "confortável" (força, ex.: 12)
-- mas o teto que o jogo aplica (getEffectiveCapacity, o mesmo do hasRoomFor) é
-- maior (ex.: 50). O feedback de Overloaded deve usar o TETO real.

local H = require("harness")
H.setName("capacity_test")

-- Cópia fiel da gridCapacity do GridRender (precedência: effectiveCapacity >
-- maxWeight > capacity). Mantida em sincronia com o GridRender.
local function gridCapacity(container, playerObj)
    if container and container.getEffectiveCapacity and playerObj then
        local ec = container:getEffectiveCapacity(playerObj)
        if ec and tonumber(ec) and ec > 0 then return ec end
    end
    if container and container.getMaxWeight then
        local mw = container:getMaxWeight()
        if mw and tonumber(mw) and mw > 0 then return mw end
    end
    if container and container.getCapacity then
        return container:getCapacity()
    end
    return 0
end

-- Inventário do JOGADOR: getMaxWeight()=12 ("confortável", força), getEffectiveCapacity=50 (teto real)
local playerInv = {
    getMaxWeight = function() return 12 end,
    getEffectiveCapacity = function() return 50 end,
    getCapacity = function() return 50 end,
}
H.ok(gridCapacity(playerInv, {}) == 50,
    "player usa o TETO real (50), não o confortável (12) [" .. tostring(gridCapacity(playerInv, {})) .. "]")

-- BOLSA: getEffectiveCapacity = capacidade (12)
local bag = {
    getMaxWeight = function() return 12 end,
    getEffectiveCapacity = function() return 12 end,
    getCapacity = function() return 12 end,
}
H.ok(gridCapacity(bag, {}) == 12,
    "bolsa usa a capacidade dela (12) [" .. tostring(gridCapacity(bag, {})) .. "]")

-- Fallback: container SEM getEffectiveCapacity cai no getMaxWeight
local legacy = {
    getMaxWeight = function() return 20 end,
    getCapacity = function() return 20 end,
}
H.ok(gridCapacity(legacy, nil) == 20,
    "fallback sem effectiveCapacity usa maxWeight (20) [" .. tostring(gridCapacity(legacy, nil)) .. "]")

-- Sem playerObj -> cai no maxWeight (não pode chamar effectiveCapacity sem player)
H.ok(gridCapacity(playerInv, nil) == 12,
    "sem playerObj cai no maxWeight (12) [" .. tostring(gridCapacity(playerInv, nil)) .. "]")

-- nil seguro
H.ok(gridCapacity(nil, nil) == 0, "container nil -> 0")

-- getEffectiveCapacity retornando nil/0 cai no fallback
local weird = {
    getEffectiveCapacity = function() return 0 end,
    getMaxWeight = function() return 30 end,
}
H.ok(gridCapacity(weird, {}) == 30, "effectiveCapacity 0 cai pro maxWeight (30)")

-- ─── Matemática do feedback (overload) ───────────────────────────────────────
local function weightOver(cap, currentWeight, addWeight)
    return cap and (currentWeight + addWeight) > cap or false
end
H.ok(weightOver(50, 14, 0) == false, "14/50 não é overload")
H.ok(weightOver(12, 14, 0) == true, "14/12 seria overload (comportamento antigo)")
H.ok(weightOver(50, 49, 3) == true, "49+3=52 > 50 é overload")
H.ok(weightOver(50, 50, 0) == false, "50/50 = exatamente no teto, ainda não overload")

H.finish()
