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
-- MISC = PRATA (degrade cinza escuro → prata na base, itens sem categoria).
-- Matizes redistribuídos no círculo cromático (~20-25° de separação) pra
-- eliminar colisões visuais.
ItemCategory.colors = {
    -- neutros (sem carga emocional, itens "de fundo")
    [ItemCategory.MISC]          = { r = 0.39, g = 0.40, b = 0.41 }, -- prata neutro
    [ItemCategory.MOVEABLE]      = { r = 0.33, g = 0.31, b = 0.37 }, -- cinza-violeta (mobília)
    [ItemCategory.CONTAINER]     = { r = 0.31, g = 0.26, b = 0.21 }, -- marrom lona/madeira

    -- perigo / carne / violência
    [ItemCategory.MELEE]         = { r = 0.48, g = 0.14, b = 0.12 }, -- vermelho sangue
    [ItemCategory.CORPSEANIMAL]  = { r = 0.27, g = 0.13, b = 0.15 }, -- vinho escuro/carne podre

    -- comida, metal quente (latão/ouro), papel
    [ItemCategory.FOOD]          = { r = 0.69, g = 0.44, b = 0.15 }, -- âmbar apetitoso (pão, assado)
    [ItemCategory.AMMO]          = { r = 0.41, g = 0.31, b = 0.15 }, -- latão/bronze fosco (cartucho)
    [ItemCategory.KEY]           = { r = 0.79, g = 0.66, b = 0.13 }, -- dourado brilhante
    [ItemCategory.BOOK]          = { r = 0.39, g = 0.34, b = 0.21 }, -- bege/papel envelhecido

    -- vida / plantas
    [ItemCategory.SEED]          = { r = 0.28, g = 0.43, b = 0.16 }, -- verde broto
    [ItemCategory.HEALING]       = { r = 0.18, g = 0.54, b = 0.30 }, -- verde saúde

    -- metal de arma / tecido
    [ItemCategory.ATTACHMENT]    = { r = 0.15, g = 0.53, b = 0.46 }, -- teal metal
    [ItemCategory.MAGAZINE]      = { r = 0.17, g = 0.52, b = 0.63 }, -- ciano aço
    [ItemCategory.RANGED]        = { r = 0.17, g = 0.32, b = 0.59 }, -- azul aço/arma de fogo
    [ItemCategory.CLOTHING]      = { r = 0.25, g = 0.22, b = 0.46 }, -- índigo tecido

    -- diversão
    [ItemCategory.ENTERTAINMENT] = { r = 0.62, g = 0.18, b = 0.47 }, -- magenta
}

-- Cache por fullType: a categoria é 100% determinada pelo tipo do item.
local _categoryCache = {}

-- Caches dos degrades: o resultado depende SÓ de (fullType, heightPx) pro
-- getGradient (a cor da categoria é fixa por tipo) e de heightPx pro
-- getSubtleGradient. Antes cada chamada alocava ~12 sub-tabelas POR ITEM POR
-- FRAME no render; agora o mesmo (tipo, altura) reutiliza a MESMA lista de
-- faixas (read-only — o drawGradientBorder só lê).
local _gradientCache = {}
local _subtleGradientCache = {}

--- Limpa os caches (hot-reload no dev / se overrides de fullType mudarem).
function ItemCategory.clearCache()
    _categoryCache = {}
    _gradientCache = {}
    _subtleGradientCache = {}
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
ItemCategory.neutralColor = { r = 0.32, g = 0.32, b = 0.32 }

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
    local fullType = item and item.getFullType and item:getFullType() or ""
    local cacheKey = fullType .. "|" .. tostring(heightPx)
    local cached = _gradientCache[cacheKey]
    if cached then return cached end

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
    _gradientCache[cacheKey] = bands
    return bands
end

-- Cor alvo do degrade SUTIL (usado na borda de itens MISC): próximo da cor do
-- slot vazio (0.45), sem o brilho metálico da prata — sutil, não puxa o olhar.
ItemCategory.subtleNeutralColor = { r = 0.45, g = 0.45, b = 0.45 }

--- Variante sutil do getGradient: desvanece do neutro até subtleNeutralColor
--- (em vez da cor da categoria). Usado na borda de itens MISC pra dar um
--- degradezim discreto, quase imperceptível, no lugar da borda sólida.
---@param heightPx number altura total do footprint em pixels
---@return table lista de faixas
function ItemCategory.getSubtleGradient(heightPx)
    local cacheKey = "s|" .. tostring(heightPx)
    local cached = _subtleGradientCache[cacheKey]
    if cached then return cached end

    local neutral = ItemCategory.neutralColor
    local target = ItemCategory.subtleNeutralColor
    local steps = ItemCategory.gradientSteps
    local bands = {}
    for i = 0, steps - 1 do
        local yTop = math.floor(heightPx * i / steps)
        local yBot = math.floor(heightPx * (i + 1) / steps)
        if yBot > yTop then
            local t = i / (steps - 1) -- 0 no topo (neutro), 1 na base (alvo sutil)
            local r, g, b = ItemCategory.lerpColor(neutral, target, t)
            bands[#bands + 1] = { y = yTop, h = yBot - yTop, r = r, g = g, b = b }
        end
    end
    _subtleGradientCache[cacheKey] = bands
    return bands
end

return ItemCategory
