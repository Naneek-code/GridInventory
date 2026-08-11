-- capacity_test.lua — teto de PESO real (gridCapacity).
-- O inventário do jogador mostra getMaxWeight() = "confortável" (força, ex.: 12)
-- mas o teto que o jogo aplica (getEffectiveCapacity, o mesmo do hasRoomFor) é
-- maior (ex.: 50). O feedback de Overloaded deve usar o TETO real.

local H = require("harness")
H.setName("capacity_test")

-- Cópia fiel da gridCapacity do GridRender (precedência: floor > effectiveCapacity
-- > maxWeight > capacity). Mantida em sincronia com o GridRender.
local FLOOR_EFFECTIVE_CAPACITY = 100
local function gridCapacity(container, playerObj)
    if container and container.getType and container:getType() == "floor" then
        return FLOOR_EFFECTIVE_CAPACITY
    end
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

-- CHÃO: mostra getMaxWeight()=50 (por pilha), mas o teto agregado real é 100.
-- O grid de chão do mod junta pilhas de VÁRIOS quadrados, então o feedback deve
-- usar 100 (o mesmo padrão do inv do jogador: display X/50, feedback no teto real).
local floor = {
    getType = function() return "floor" end,
    getMaxWeight = function() return 50 end,
    getEffectiveCapacity = function() return 50 end,
    getCapacity = function() return 50 end,
}
H.ok(gridCapacity(floor, {}) == 100,
    "chão usa o TETO agregado real (100), não o por-pilha (50) [" .. tostring(gridCapacity(floor, {})) .. "]")

-- Chão sem playerObj também retorna 100 (special-case vem antes do effectiveCapacity)
H.ok(gridCapacity(floor, nil) == 100,
    "chão sem playerObj continua 100 (special-case primeiro) [" .. tostring(gridCapacity(floor, nil)) .. "]")

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
H.ok(weightOver(100, 60, 0) == false, "60/100 não é overload (chão com teto real)")
H.ok(weightOver(100, 99, 3) == true, "99+3=102 > 100 é overload (chão)")
H.ok(weightOver(100, 100, 0) == false, "100/100 = exatamente no teto do chão")

H.finish()
