--- ItemCategory.lua
--- Classifica itens em categorias semânticas (estilo Tetris) e mapeia cada uma
--- pra uma COR de footprint. Usado pelo GridRender (item posicionado) e pelo
--- GlobalDragRender (ghost do drag) pra dar identidade visual por tipo de item.
---
--- Categorização determinística e cacheada por fullType (a categoria de um item
--- é fixa por tipo — mesma lógica do ItemFootprint.getSize).

local ItemCategory = {}

-- ─── Categorias ──────────────────────────────────────────────────────────────
ItemCategory.MISC = "MISC"
ItemCategory.MELEE = "MELEE"
ItemCategory.RANGED = "RANGED"
ItemCategory.AMMO = "AMMO"
ItemCategory.MAGAZINE = "MAGAZINE"
ItemCategory.ATTACHMENT = "ATTACHMENT"
ItemCategory.FOOD = "FOOD"
ItemCategory.CLOTHING = "CLOTHING"
ItemCategory.CONTAINER = "CONTAINER"
ItemCategory.HEALING = "HEALING"
ItemCategory.BOOK = "BOOK"
ItemCategory.ENTERTAINMENT = "ENTERTAINMENT"
ItemCategory.KEY = "KEY"
ItemCategory.SEED = "SEED"
ItemCategory.MOVEABLE = "MOVEABLE"
ItemCategory.CORPSEANIMAL = "CORPSEANIMAL"

-- Paleta de fundo do footprint por categoria (r, g, b; alpha fica no caller).
-- MISC = PRATA (itens sem categoria rastreada ainda ganham degrade, de cinza
-- escuro no topo até a prata na base — charme metálico). Cores das categorias
-- são VIVAS/saturadas pra se destacar no fundo escuro do grid.
-- Matizes separados por matiz + clareza pra não colidirem (ex.: FOOD vermelho
-- vs AMMO laranja; BOOK oliva vs KEY dourado).
ItemCategory.colors = {
    [ItemCategory.MISC] = { r = 0.72, g = 0.74, b = 0.78 },
    [ItemCategory.MELEE] = { r = 0.55, g = 0.20, b = 0.85 },
    [ItemCategory.RANGED] = { r = 0.30, g = 0.55, b = 1.0 },
    [ItemCategory.AMMO] = { r = 1.0, g = 0.60, b = 0.20 },
    [ItemCategory.MAGAZINE] = { r = 0.25, g = 0.75, b = 1.0 },
    [ItemCategory.ATTACHMENT] = { r = 0.20, g = 0.85, b = 0.70 },
    [ItemCategory.FOOD] = { r = 1.0, g = 0.30, b = 0.20 },
    [ItemCategory.CLOTHING] = { r = 0.30, g = 0.45, b = 0.75 },
    [ItemCategory.CONTAINER] = { r = 0.65, g = 0.48, b = 0.25 },
    [ItemCategory.HEALING] = { r = 0.40, g = 0.95, b = 0.45 },
    [ItemCategory.BOOK] = { r = 0.75, g = 0.60, b = 0.15 },
    [ItemCategory.ENTERTAINMENT] = { r = 1.0, g = 0.30, b = 0.75 },
    [ItemCategory.KEY] = { r = 0.95, g = 0.80, b = 0.30 },
    [ItemCategory.SEED] = { r = 0.25, g = 0.70, b = 0.35 },
    [ItemCategory.MOVEABLE] = { r = 0.45, g = 0.55, b = 0.75 },
    [ItemCategory.CORPSEANIMAL] = { r = 0.75, g = 0.15, b = 0.15 },
}

-- Cache por fullType: a categoria é 100% determinada pelo tipo do item.
local _categoryCache = {}

--- Limpa o cache (hot-reload no dev / se overrides de fullType mudarem).
function ItemCategory.clearCache()
    _categoryCache = {}
end

--- Classifica o item numa categoria semântica.
--- Ordem de precedência:
---   1. Moveable (móveis) — instanceof tem precedência sobre categorias genéricas.
---   2. Base.CorpseAnimal.
---   3. Container (IsInventoryContainer) — bolsas/mochilas.
---   4. Cura (FirstAid/Medical).
---   5. Armas (melee vs ranged via isRanged/getAmmoType).
---   6. Carregador (getMaxAmmo > 0).
---   7. Peça de arma (WeaponPart).
---   8. Munição (displayCategory "Ammo").
---   9. Roupa (IsClothing).
---   10. Comida/Água (IsFood / WaterContainer).
---   11. Livros (Literature/SkillBook).
---   12. Mídia (isRecordedMedia / Entertainment).
---   13. Chave (getCategory == "Key").
---   14. Sementes (fullType contém "Seed").
---   fallback: MISC.
---@param item InventoryItem
---@return string
function ItemCategory.getCategory(item)
    if not item then return ItemCategory.MISC end
    local fullType = item.getFullType and item:getFullType() or nil
    if not fullType then return ItemCategory.MISC end

    local cached = _categoryCache[fullType]
    if cached then return cached end

    local category = ItemCategory._classify(item, fullType)
    _categoryCache[fullType] = category
    return category
end

--- Classificação sem cache. Separada pra facilitar teste/override.
---@param item InventoryItem
---@param fullType string
---@return string
function ItemCategory._classify(item, fullType)
    local displayCategory = item.getDisplayCategory and item:getDisplayCategory() or nil
    local category = item.getCategory and item:getCategory() or nil

    if instanceof and instanceof(item, "Moveable") then
        return ItemCategory.MOVEABLE
    elseif fullType == "Base.CorpseAnimal" then
        return ItemCategory.CORPSEANIMAL
    elseif item.IsInventoryContainer and item:IsInventoryContainer() then
        return ItemCategory.CONTAINER
    elseif displayCategory == "FirstAid" or displayCategory == "FirstAidWeapon" or displayCategory == "Medical" then
        return ItemCategory.HEALING
    elseif item.IsWeapon and item:IsWeapon() then
        if (item.getAmmoType and item:getAmmoType()) or (item.isRanged and item:isRanged()) then
            return ItemCategory.RANGED
        end
        return ItemCategory.MELEE
    elseif item.getMaxAmmo and item:getMaxAmmo() > 0 then
        return ItemCategory.MAGAZINE
    elseif (instanceof and instanceof(item, "WeaponPart")) or displayCategory == "WeaponPart" then
        return ItemCategory.ATTACHMENT
    elseif displayCategory == "Ammo" then
        return ItemCategory.AMMO
    elseif item.IsClothing and item:IsClothing() then
        return ItemCategory.CLOTHING
    elseif (item.IsFood and item:IsFood()) or displayCategory == "WaterContainer" or displayCategory == "Water" then
        return ItemCategory.FOOD
    elseif (instanceof and instanceof(item, "Literature")) or displayCategory == "Literature" or displayCategory == "SkillBook" then
        return ItemCategory.BOOK
    elseif (item.isRecordedMedia and item:isRecordedMedia()) or displayCategory == "Entertainment" then
        return ItemCategory.ENTERTAINMENT
    elseif category == "Key" then
        return ItemCategory.KEY
    elseif fullType and string.find(fullType, "Seed") and not string.find(fullType, "Paste") then
        return ItemCategory.SEED
    end

    return ItemCategory.MISC
end

--- Cor de fundo do footprint pra um item (r, g, b).
---@param item InventoryItem
---@return table { r, g, b }
function ItemCategory.getColor(item)
    local cat = ItemCategory.getCategory(item)
    local c = ItemCategory.colors[cat]
    if not c then return ItemCategory.colors[ItemCategory.MISC] end
    return c
end

--- Cor de fundo do footprint pra uma categoria já resolvida.
---@param category string
---@return table { r, g, b }
function ItemCategory.getColorByCategory(category)
    local c = ItemCategory.colors[category]
    if not c then return ItemCategory.colors[ItemCategory.MISC] end
    return c
end

-- Faixas do degrade: a cor NEUTRA (cinza escuro) no TOPO desvanece até a cor de
-- BASE de cada item. A base é a cor da categoria (MISC = prata, então itens sem
-- categoria rastreada têm degrade cinza→prata). Quantidade de faixas (12) =
-- equilíbrio entre visual suave e performance.
ItemCategory.gradientSteps = 12

-- Cor neutra (topo do degrade) = cinza escuro FIXO (não aponta pro MISC, que é
-- a prata da BASE dos itens sem categoria — o topo precisa ser sempre o sóbrio).
ItemCategory.neutralColor = { r = 0.40, g = 0.40, b = 0.40 }

--- Interpola linear entre duas cores.
---@param from table {r,g,b}
---@param to table {r,g,b}
---@param t number 0..1 (0 = from, 1 = to)
---@return number, number, number r, g, b
function ItemCategory.lerpColor(from, to, t)
    return from.r + (to.r - from.r) * t,
           from.g + (to.g - from.g) * t,
           from.b + (to.b - from.b) * t
end

--- Gera a lista de faixas do degrade vertical do footprint de um item, com
--- posições em PIXELS INTEIROS (tile sem gaps/sobreposição — o cálculo fracionário
--- deixava linhas pretas quando a altura não dividia exato por gradientSteps).
--- Cada faixa é { y, h, r, g, b }: o caller desenha com
--- drawRect(x, drawY + y, w, h, alpha, r, g, b).
--- NEUTRO no topo → CATEGORIA na base (invertido a pedido do usuário).
---@param item InventoryItem
---@param heightPx number altura total do footprint em pixels
---@return table lista de faixas
function ItemCategory.getGradient(item, heightPx)
    local catColor = ItemCategory.getColor(item)
    local neutral = ItemCategory.neutralColor
    local steps = ItemCategory.gradientSteps
    local bands = {}
    for i = 0, steps - 1 do
        local yTop = math.floor(heightPx * i / steps)
        local yBot = math.floor(heightPx * (i + 1) / steps)
        if yBot > yTop then
            local t = i / (steps - 1) -- 0 no topo (neutro), 1 na base (categoria)
            local r, g, b = ItemCategory.lerpColor(neutral, catColor, t)
            bands[#bands + 1] = { y = yTop, h = yBot - yTop, r = r, g = g, b = b }
        end
    end
    return bands
end

return ItemCategory
