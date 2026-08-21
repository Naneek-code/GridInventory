--- GridIconRotation.lua
--- Ajuste visual FIXO por fullType para sprites que nascem tortos no arquivo
--- (desenhados em ângulo que não é múltiplo de 90°). O GridRender aplica isso
--- em runtime no drawItemIconRotated — nenhum arquivo de sprite é editado.
--- Footprint (w/h) não é afetado: é só o visual dentro da célula.
---
--- Três propriedades:
---   * angle: rotação em graus (corrige sprite torta).
---   * scale: multiplicador de TAMANHO sobre o min-fit (preserva o aspecto).
---     Como o caminho livre usa min-fit (não deforma), a escala permite crescer
---     a sprite até tocar a borda do footprint sem esticar o desenho.
---   * anchor: deslocamento em PIXELS do sprite dentro do footprint (x/y).
---     Compensa itens cuja "massa visual" (lâmina, cabo, bico) nasce fora do
---     centro do PNG — ao girar, a parte importante fica deslocada da célula.
---
--- A fonte de verdade do override AO VIVO é o GridDevTool.Overrides[fullType]
--- (campos .angle/.scale/.anchorX/.anchorY), salvo no GridOverrides.ini — o
--- mesmo sistema do footprint. GridIconRotation.Overrides/Scales/Anchors aqui
--- são só as tabelas FIXAS (hardcoded pelo mod).
---
--- VARIAÇÃO DE SPRITE: itens como Base.Hammer têm 2 sprites (esquerda/direita)
--- que compartilham o mesmo fullType. O sistema resolve isso com uma chave
--- composta "fullType|spriteName" que permite overrides independentes por
--- variante. Fallback: fullType puro (backward compat).

local GridIconRotation = {}

-- Sandbox option "GridInventory.IconRotation" (servidor decide): quando
-- DESLIGADA (default), o render usa os valores PADRÃO (angle=0, scale=1,
-- anchor=0) pra TODOS os jogadores, ignorando o hardcoded e os overrides salvos
-- no ini — só o footprint w/h continua aplicado. Default OFF é POR
-- COMPATIBILIDADE: saves/inis antigos (de antes de existir angle/scale/anchor)
-- não podem ver a sprite mudar do nada. O DevTool (ferramenta de admin)
-- continua lendo os valores reais via getAngle/getScale/getAnchor (sem gate) pra
-- poder editar. O gate fica nas funções getRender* usadas apenas no caminho de
-- render.
local ok, GridSandboxOptions = pcall(require, "GridSandboxOptions")
if not ok then GridSandboxOptions = nil end

local function isIconRotationEnabled()
    if not GridSandboxOptions or not GridSandboxOptions.isIconRotationEnabled then
        return false -- opção não disponível (ex.: teste) = OFF conservador
    end
    return GridSandboxOptions.isIconRotationEnabled()
end

-- Overrides fixos (hardcoded no mod): fullType -> ângulo em graus.
-- O tuning ao vivo é feito pelo GridDevTool (campo "Icon Angle"), que salva
-- em GridDevTool.Overrides[fullType].angle.
GridIconRotation.Overrides = {
    -- Exemplos para validar (descomente e ajuste o ângulo real depois):
    -- ["Base.HuntingKnife"] = 45,
}

-- Overrides fixos de ESCALA: fullType -> multiplicador (1.0 = min-fit puro,
-- >1 = maior, <1 = menor). Tuning ao vivo pelo GridDevTool (campo "Icon Scale").
GridIconRotation.Scales = {
    -- ["Base.HuntingKnife"] = 1.15,
}

-- Overrides fixos de ANCHOR: fullType -> { x = pixels, y = pixels } de
-- deslocamento da sprite dentro do footprint (positivo = pra baixo/direita).
-- Tuning ao vivo pelo GridDevTool (campo "Icon Anchor").
GridIconRotation.Anchors = {
    -- ["Base.HuntingKnife"] = { x = 0, y = -3 },
}

-- Cache por fullType: o valor da TABELA FIXA é 100% determinado pelo fullType.
-- Overrides do GridDevTool NÃO são cacheados de propósito (mesmo padrão do
-- ItemFootprint) pra refletir mudanças ao vivo sem limpar cache.
local _cache = {}
local _scaleCache = {}
local _anchorCache = {}

--- Limpa o cache. Chame se os overrides fixos mudarem em runtime (hot-reload).
function GridIconRotation.clearCache()
    _cache = {}
    _scaleCache = {}
    _anchorCache = {}
end

--- Chave de variante de sprite: permite overrides diferentes pras 2 sprites
--- do mesmo fullType (ex.: Base.Hammer esquerda vs direita). Usa o nome da
--- textura runtime (getTex():getName()) que DIFERE entre variantes.
--- Retorna "fullType|spriteName" ou só "fullType" se a sprite não for
--- distinguível (fallback backward compat).
---@param item InventoryItem
---@return string
function GridIconRotation.getVariantKey(item)
    if not item then return "" end
    local fullType = item.getFullType and item:getFullType() or ""
    local tex = item.getTex and item:getTex()
    if tex then
        local texName = tex.getName and tex:getName()
        if texName and texName ~= "" then
            return fullType .. "|" .. texName
        end
    end
    return fullType
end

--- Retorna o ângulo de rotação fixo (graus) do item, ou 0 se não houver.
--- Prioridade: GridDevTool.Overrides (ao vivo) > tabela fixa > 0.
--- Lookup: variante (fullType|spriteName) primeiro, fallback fullType puro.
--- @param item InventoryItem
--- @return number angle graus (0 = sem rotação)
function GridIconRotation.getAngle(item)
    if not item then return 0 end

    local fullType = item:getFullType()
    local variantKey = GridIconRotation.getVariantKey(item)

    -- 1. Override AO VIVO do GridDevTool (mesmo padrão do ItemFootprint):
    --    checado em cada chamada, sem cache, pra refletir o tuning na hora.
    --    Variante primeiro, fallback fullType.
    if GridDevTool and GridDevTool.Overrides then
        local live = GridDevTool.Overrides[variantKey]
        if live and live.angle ~= nil then
            return live.angle
        end
        if variantKey ~= fullType then
            live = GridDevTool.Overrides[fullType]
            if live and live.angle ~= nil then
                return live.angle
            end
        end
    end

    -- 2. Tabela fixa do mod (cacheada — sempre fullType, sem suporte a variante).
    local cached = _cache[fullType]
    if cached ~= nil then
        return cached
    end

    local angle = GridIconRotation.Overrides[fullType] or 0
    _cache[fullType] = angle
    return angle
end

--- Retorna o multiplicador de escala (tamanho) do sprite, ou 1.0 se não houver.
--- Prioridade: GridDevTool.Overrides (ao vivo) > tabela fixa > 1.0.
--- Lookup: variante primeiro, fallback fullType.
--- @param item InventoryItem
--- @return number scale multiplicador (1.0 = min-fit puro, preserva aspecto)
function GridIconRotation.getScale(item)
    if not item then return 1 end

    local fullType = item:getFullType()
    local variantKey = GridIconRotation.getVariantKey(item)

    -- 1. Override AO VIVO do GridDevTool (mesmo padrão do ângulo).
    if GridDevTool and GridDevTool.Overrides then
        local live = GridDevTool.Overrides[variantKey]
        if live and live.scale ~= nil then
            return live.scale
        end
        if variantKey ~= fullType then
            live = GridDevTool.Overrides[fullType]
            if live and live.scale ~= nil then
                return live.scale
            end
        end
    end

    -- 2. Tabela fixa do mod (cacheada — fullType puro).
    local cached = _scaleCache[fullType]
    if cached ~= nil then
        return cached
    end

    local scale = GridIconRotation.Scales[fullType] or 1
    _scaleCache[fullType] = scale
    return scale
end

--- Retorna o deslocamento (anchor) do sprite dentro do footprint, em pixels.
--- x positivo = move pra DIREITA, y positivo = move pra BAIXO. Compensa a
--- "massa visual" do item fora do centro do PNG (lâmina/cabo deslocados), que
--- ao rotacionar fica torta em relação à célula.
--- Prioridade: GridDevTool.Overrides (ao vivo) > tabela fixa > { x=0, y=0 }.
--- Lookup: variante primeiro, fallback fullType.
--- @param item InventoryItem
--- @return number, number anchorX, anchorY (pixels)
function GridIconRotation.getAnchor(item)
    if not item then return 0, 0 end

    local fullType = item:getFullType()
    local variantKey = GridIconRotation.getVariantKey(item)

    -- 2. Tabela fixa do mod (cacheada — fullType puro).
    local cached = _anchorCache[fullType]
    if cached == nil then
        local fixed = GridIconRotation.Anchors[fullType]
        cached = { x = fixed and fixed.x or 0, y = fixed and fixed.y or 0 }
        _anchorCache[fullType] = cached
    end

    -- 3. Override AO VIVO tem prioridade POR EIXO: se só o X foi definido, o
    --    Y continua vindo da tabela fixa (fallback independente por eixo).
    --    Variante primeiro, fallback fullType.
    if GridDevTool and GridDevTool.Overrides then
        local live = GridDevTool.Overrides[variantKey]
        if live then
            if live.anchorX ~= nil then cached = { x = live.anchorX, y = cached.y } end
            if live.anchorY ~= nil then cached = { x = cached.x, y = live.anchorY } end
        elseif variantKey ~= fullType then
            live = GridDevTool.Overrides[fullType]
            if live then
                if live.anchorX ~= nil then cached = { x = live.anchorX, y = cached.y } end
                if live.anchorY ~= nil then cached = { x = cached.x, y = live.anchorY } end
            end
        end
    end

    return cached.x, cached.y
end

--- Computa a escala BASE (min-fit) do sprite em px-por-texel: o maior fator que
--- acomoda a textura no footprint com o PAD=2 do GridRender. Espelha EXATAMENTE
--- a matemática do render, então é a fonte de verdade pros botões "pixel-perfect"
--- do DevTool calcularem o multiplicador exato.
--- @param texW number largura da textura (px)
--- @param texH number altura da textura (px)
--- @param footprintW number footprint em PIXELS (células * cellSize)
--- @param footprintH number footprint em PIXELS (células * cellSize)
--- @param deg number|nil ângulo fixo em graus (0/nil = caminho normal)
--- @param isRotated boolean|nil swap de 90° (tecla R)
--- @return number|nil baseScale em px-por-texel (nil se texW/H <= 0)
function GridIconRotation.computeBaseScale(texW, texH, footprintW, footprintH, deg, isRotated)
    if not texW or not texH or texW <= 0 or texH <= 0 then return nil end

    local PAD = 2
    local scaleW = math.max(1, (footprintW or 0) - PAD)
    local scaleH = math.max(1, (footprintH or 0) - PAD)

    local vw, vh
    if deg and deg ~= 0 then
        -- Caminho LIVRE: bbox do retângulo girado pelo ângulo EFETIVO
        -- (deg + isRotated*−90°, como no drawItemIconRotatedFree).
        local effDeg = deg + (isRotated and -90 or 0)
        local rad = effDeg * math.pi / 180
        local cosT, sinT = math.cos(rad), math.sin(rad)
        vw = math.abs(texW * cosT) + math.abs(texH * sinT)
        vh = math.abs(texW * sinT) + math.abs(texH * cosT)
    elseif isRotated then
        -- Caminho NORMAL: o swap de 90° troca texW/texH (como no render).
        vw, vh = texH, texW
    else
        vw, vh = texW, texH
    end

    return math.min(scaleW / vw, scaleH / vh)
end

--- Retorna os multiplicadores de escala (campo "Icon Scale" do DevTool) que
--- deixam o sprite PIXEL-PERFECT: cada texel do PNG vira um número INTEIRO de
--- pixels de tela (drawW = texW*N, drawH = texH*N, N inteiro) — sem blur de
--- interpolação. N = 1 é o tamanho nativo (1 texel = 1 px).
--- Cada item: { N = inteiro, iconScale = N/baseScale }. Inclui também N que
--- ESTOURAM o footprint (N > floor(baseScale)) — ex: N=2 numa célula pequena,
--- a sprite cresce além da borda. Ordenados do maior pro menor.
--- @return table lista de { N = number, iconScale = number }
function GridIconRotation.getPixelPerfectScales(texW, texH, footprintW, footprintH, deg, isRotated)
    local baseScale = GridIconRotation.computeBaseScale(texW, texH, footprintW, footprintH, deg, isRotated)
    if not baseScale then return {} end

    local out = {}
    -- Cap de N: até 2 acima do que cabe no footprint (floor(baseScale)), pro
    -- usuário ter opções de crescimento sem virar um zoom absurdo. Pra textura
    -- MAIOR que o footprint (baseScale < 1), nenhum N "cabe" — só o nativo 1:1
    -- é útil, então maxN = 1.
    local maxN = math.floor(baseScale + 1e-6)
    if maxN < 1 then
        maxN = 1
    else
        maxN = maxN + 2
    end
    for n = maxN, 1, -1 do
        if n / baseScale >= 0.5 then
            out[#out + 1] = { N = n, iconScale = n / baseScale }
        end
    end
    return out
end

--- Versões de RENDER dos getters acima: aplicam o gate da Sandbox Option
--- "GridInventory.IconRotation" (servidor decide). Quando desligada, TODOS os
--- jogadores veem os sprites no padrão (angle=0, scale=1, anchor=0) mesmo com
--- override salvo no DevTool — só o footprint w/h é aplicado. Usadas ÚNICAS e
--- EXCLUSIVAMENTE no caminho de render (GridRender, GlobalDragRender,
--- FloatingGridWindow). O DevTool continua usando getAngle/getScale/getAnchor
--- (sem gate) pra poder ver e editar os valores reais.

--- Ângulo para RENDER (graus): 0 quando a sandbox option desliga a rotação.
function GridIconRotation.getRenderAngle(item)
    if not isIconRotationEnabled() then return 0 end
    return GridIconRotation.getAngle(item)
end

--- Escala para RENDER: 1 (min-fit puro) quando a sandbox option desliga.
function GridIconRotation.getRenderScale(item)
    if not isIconRotationEnabled() then return 1 end
    return GridIconRotation.getScale(item)
end

--- Anchor para RENDER: (0,0) quando a sandbox option desliga.
function GridIconRotation.getRenderAnchor(item)
    if not isIconRotationEnabled() then return 0, 0 end
    return GridIconRotation.getAnchor(item)
end

return GridIconRotation
