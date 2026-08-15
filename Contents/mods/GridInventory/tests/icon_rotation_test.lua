-- grid_icon_rotation_test.lua — GridIconRotation.getAngle.
-- Foco: resolução do ângulo fixo por fullType + cache + override do GridDevTool.

local H = require("harness")
H.setName("icon_rotation_test")

local GridIconRotation = require("Algorithm/GridIconRotation")
GridIconRotation.clearCache()

-- ── Stubs do ambiente PZ ─────────────────────────────────────────────────────
_G.instanceof = function() return false end

local seq = 0
local function makeItem(fullType)
    seq = seq + 1
    return {
        getFullType = function() return fullType or ("Base.TestItem" .. seq) end,
    }
end

-- ── Sem override: ângulo 0 (hot path: deg nil/0 não entra na rotação) ────────
do
    local item = makeItem("Base.PlainKnife")
    local angle = GridIconRotation.getAngle(item)
    H.ok(angle == 0, "item sem override -> 0 (sem rotação) [" .. tostring(angle) .. "]")
end

-- ── Override fixo na tabela ──────────────────────────────────────────────────
do
    GridIconRotation.Overrides["Base.TortoKnife"] = 45
    local item = makeItem("Base.TortoKnife")
    local angle = GridIconRotation.getAngle(item)
    H.ok(angle == 45, "override fixo -> 45 [" .. tostring(angle) .. "]")

    -- Cache: segunda chamada deve dar o mesmo valor.
    local angle2 = GridIconRotation.getAngle(item)
    H.ok(angle2 == 45, "cache -> 45 na 2ª chamada [" .. tostring(angle2) .. "]")
end

-- ── Override do GridDevTool tem prioridade (ao vivo, sem cache) ──────────────
do
    GridIconRotation.Overrides["Base.DevKnife"] = 30
    local item = makeItem("Base.DevKnife")
    local angle = GridIconRotation.getAngle(item)
    H.ok(angle == 30, "sem GridDevTool -> 30 [" .. tostring(angle) .. "]")

    -- Simula o DevTools ligado: ângulo salvo em GridDevTool.Overrides[fullType].angle.
    _G.GridDevTool = { Overrides = { ["Base.DevKnife"] = { angle = -20 } } }
    local angle2 = GridIconRotation.getAngle(item)
    H.ok(angle2 == -20, "GridDevTool override -> -20 [" .. tostring(angle2) .. "]")

    -- Ao vivo: mudar a tabela do GridDevTool reflete na hora, sem clearCache
    -- (mesmo padrão do ItemFootprint).
    _G.GridDevTool.Overrides["Base.DevKnife"].angle = 90
    local angle3 = GridIconRotation.getAngle(item)
    H.ok(angle3 == 90, "GridDevTool ao vivo -> 90 sem clearCache [" .. tostring(angle3) .. "]")

    -- Remover o angle (reset) volta pra tabela fixa.
    _G.GridDevTool.Overrides["Base.DevKnife"].angle = nil
    H.ok(GridIconRotation.getAngle(item) == 30, "reset -> volta pra tabela fixa (30)")
    _G.GridDevTool = nil
end

-- ── Override fixo: muda a tabela sem clearCache não pega (é cacheado) ────────
do
    local item = makeItem("Base.CacheKnife")
    H.ok(GridIconRotation.getAngle(item) == 0, "antes do override -> 0")
    -- Tabela fixa é CACHEADA (100% determinada pelo fullType) — precisa do
    -- clearCache pra refletir mudança em runtime.
    GridIconRotation.Overrides["Base.CacheKnife"] = 90
    H.ok(GridIconRotation.getAngle(item) == 0, "tabela fixa cacheada -> ainda 0")
    GridIconRotation.clearCache()
    H.ok(GridIconRotation.getAngle(item) == 90, "após clearCache -> 90")
end

-- ── nil item → 0 ─────────────────────────────────────────────────────────────
do
    H.ok(GridIconRotation.getAngle(nil) == 0, "getAngle(nil) -> 0")
end

-- ── getScale: multiplicador de tamanho (default 1.0 = min-fit puro) ──────────
do
    local item = makeItem("Base.PlainScale")
    H.ok(GridIconRotation.getScale(item) == 1, "item sem override -> 1.0 (min-fit puro) [" .. tostring(GridIconRotation.getScale(item)) .. "]")
end

do
    -- Tabela fixa de escala.
    GridIconRotation.Scales["Base.ScaleKnife"] = 1.25
    local item = makeItem("Base.ScaleKnife")
    H.ok(GridIconRotation.getScale(item) == 1.25, "override fixo de scale -> 1.25 [" .. tostring(GridIconRotation.getScale(item)) .. "]")

    -- Cache: segunda chamada deve dar o mesmo valor.
    H.ok(GridIconRotation.getScale(item) == 1.25, "scale cache -> 1.25 na 2ª chamada [" .. tostring(GridIconRotation.getScale(item)) .. "]")
end

do
    -- GridDevTool override ao vivo tem prioridade sobre a tabela fixa.
    GridIconRotation.Scales["Base.DevScale"] = 1.1
    local item = makeItem("Base.DevScale")
    H.ok(GridIconRotation.getScale(item) == 1.1, "sem GridDevTool -> 1.1 [" .. tostring(GridIconRotation.getScale(item)) .. "]")

    _G.GridDevTool = { Overrides = { ["Base.DevScale"] = { scale = 1.4 } } }
    H.ok(GridIconRotation.getScale(item) == 1.4, "GridDevTool scale override -> 1.4 [" .. tostring(GridIconRotation.getScale(item)) .. "]")

    -- Ao vivo: mudar a tabela reflete na hora, sem clearCache.
    _G.GridDevTool.Overrides["Base.DevScale"].scale = 0.9
    H.ok(GridIconRotation.getScale(item) == 0.9, "GridDevTool scale ao vivo -> 0.9 sem clearCache [" .. tostring(GridIconRotation.getScale(item)) .. "]")

    -- Remover o scale (reset) volta pra tabela fixa.
    _G.GridDevTool.Overrides["Base.DevScale"].scale = nil
    H.ok(GridIconRotation.getScale(item) == 1.1, "reset scale -> volta pra tabela fixa (1.1)")
    _G.GridDevTool = nil
end

-- ── Tabela fixa de scale é cacheada (precisa clearCache pra refletir runtime) ─
do
    local item = makeItem("Base.ScaleCache")
    H.ok(GridIconRotation.getScale(item) == 1, "antes do override de scale -> 1.0")
    GridIconRotation.Scales["Base.ScaleCache"] = 1.5
    H.ok(GridIconRotation.getScale(item) == 1, "tabela fixa de scale cacheada -> ainda 1.0")
    GridIconRotation.clearCache()
    H.ok(GridIconRotation.getScale(item) == 1.5, "após clearCache -> 1.5")
end

-- ── getScale(nil) → 1.0 ──────────────────────────────────────────────────────
do
    H.ok(GridIconRotation.getScale(nil) == 1, "getScale(nil) -> 1.0")
end

-- ── getAnchor: deslocamento em px do sprite dentro do footprint ──────────────
do
    local item = makeItem("Base.PlainAnchor")
    local ax, ay = GridIconRotation.getAnchor(item)
    H.ok(ax == 0 and ay == 0, "item sem override -> 0,0 [" .. tostring(ax) .. "," .. tostring(ay) .. "]")
end

do
    -- Tabela fixa de anchor.
    GridIconRotation.Anchors["Base.AnchorKnife"] = { x = 3, y = -2 }
    local item = makeItem("Base.AnchorKnife")
    local ax, ay = GridIconRotation.getAnchor(item)
    H.ok(ax == 3 and ay == -2, "override fixo de anchor -> 3,-2 [" .. tostring(ax) .. "," .. tostring(ay) .. "]")

    -- Cache: segunda chamada deve dar o mesmo valor.
    local ax2, ay2 = GridIconRotation.getAnchor(item)
    H.ok(ax2 == 3 and ay2 == -2, "anchor cache -> 3,-2 na 2ª chamada [" .. tostring(ax2) .. "," .. tostring(ay2) .. "]")
end

do
    -- GridDevTool override ao vivo tem prioridade sobre a tabela fixa.
    GridIconRotation.Anchors["Base.DevAnchor"] = { x = 1, y = 1 }
    local item = makeItem("Base.DevAnchor")
    local ax, ay = GridIconRotation.getAnchor(item)
    H.ok(ax == 1 and ay == 1, "sem GridDevTool -> 1,1 [" .. tostring(ax) .. "," .. tostring(ay) .. "]")

    _G.GridDevTool = { Overrides = { ["Base.DevAnchor"] = { anchorX = -4, anchorY = 2 } } }
    local ax2, ay2 = GridIconRotation.getAnchor(item)
    H.ok(ax2 == -4 and ay2 == 2, "GridDevTool anchor override -> -4,2 [" .. tostring(ax2) .. "," .. tostring(ay2) .. "]")

    -- Ao vivo: mudar a tabela reflete na hora, sem clearCache.
    _G.GridDevTool.Overrides["Base.DevAnchor"].anchorX = 5
    local ax3 = GridIconRotation.getAnchor(item)
    H.ok(ax3 == 5 and ay2 == 2, "GridDevTool anchor ao vivo -> 5,2 sem clearCache [" .. tostring(ax3) .. "," .. tostring(ay2) .. "]")

    -- Anchor parcial: só X definido, Y vem da tabela fixa.
    _G.GridDevTool.Overrides["Base.DevAnchor"].anchorY = nil
    local ax4, ay4 = GridIconRotation.getAnchor(item)
    H.ok(ax4 == 5 and ay4 == 1, "anchor parcial (só X) -> Y volta pra tabela fixa (1) [" .. tostring(ax4) .. "," .. tostring(ay4) .. "]")

    -- Remover o anchor (reset) volta pra tabela fixa.
    _G.GridDevTool.Overrides["Base.DevAnchor"].anchorX = nil
    local ax5, ay5 = GridIconRotation.getAnchor(item)
    H.ok(ax5 == 1 and ay5 == 1, "reset anchor -> volta pra tabela fixa (1,1) [" .. tostring(ax5) .. "," .. tostring(ay5) .. "]")
    _G.GridDevTool = nil
end

-- ── Tabela fixa de anchor é cacheada (precisa clearCache pra refletir runtime) ─
do
    local item = makeItem("Base.AnchorCache")
    local ax, ay = GridIconRotation.getAnchor(item)
    H.ok(ax == 0 and ay == 0, "antes do override de anchor -> 0,0")
    GridIconRotation.Anchors["Base.AnchorCache"] = { x = 2, y = 2 }
    local ax2, ay2 = GridIconRotation.getAnchor(item)
    H.ok(ax2 == 0 and ay2 == 0, "tabela fixa de anchor cacheada -> ainda 0,0")
    GridIconRotation.clearCache()
    local ax3, ay3 = GridIconRotation.getAnchor(item)
    H.ok(ax3 == 2 and ay3 == 2, "após clearCache -> 2,2 [" .. tostring(ax3) .. "," .. tostring(ay3) .. "]")
end

-- ── getAnchor(nil) → 0,0 ─────────────────────────────────────────────────────
do
    local ax, ay = GridIconRotation.getAnchor(nil)
    H.ok(ax == 0 and ay == 0, "getAnchor(nil) -> 0,0")
end

-- ── computeBaseScale: min-fit em px-por-texel (mesma matemática do render) ───
do
    -- 32px de texura num footprint de 40x40: PAD=2 → scaleW/H = 38. Sem
    -- rotação/swap: min(38/32, 38/32) = 1.1875.
    local b = GridIconRotation.computeBaseScale(32, 32, 40, 40, 0, false)
    H.ok(math.abs(b - 1.1875) < 1e-9, "baseScale 32px em 40x40 -> 1.1875 [" .. tostring(b) .. "]")

    -- isRotated (swap 90°): 32x16 num footprint 40x40 → min(38/16, 38/32) = 1.1875.
    local b2 = GridIconRotation.computeBaseScale(32, 16, 40, 40, 0, true)
    H.ok(math.abs(b2 - 1.1875) < 1e-9, "baseScale 32x16 rotated em 40x40 -> 1.1875 [" .. tostring(b2) .. "]")

    -- Rotação livre 45°: bbox vira 32*sqrt2 ≈ 45.25 → min(38/45.25, 38/45.25) ≈ 0.8397.
    local b3 = GridIconRotation.computeBaseScale(32, 32, 40, 40, 45, false)
    local expected = 38 / (32 * math.sqrt(2))
    H.ok(math.abs(b3 - expected) < 1e-9, "baseScale 32px rot 45° -> 38/(32√2) [" .. tostring(b3) .. " vs " .. tostring(expected) .. "]")

    -- Textura maior que o footprint: 64px em 40x40 → min(38/64, 38/64) = 0.59375.
    local b4 = GridIconRotation.computeBaseScale(64, 64, 40, 40, 0, false)
    H.ok(math.abs(b4 - 0.59375) < 1e-9, "baseScale 64px em 40x40 -> 0.59375 [" .. tostring(b4) .. "]")

    -- nil/inválido.
    H.ok(GridIconRotation.computeBaseScale(0, 10, 40, 40, 0, false) == nil, "baseScale texW 0 -> nil")
    H.ok(GridIconRotation.computeBaseScale(10, 0, 40, 40, 0, false) == nil, "baseScale texH 0 -> nil")
end

-- ── getPixelPerfectScales: multiplicadores pra texel→px inteiro ──────────────
do
    -- 32px em 40x40, baseScale 1.1875 → N=1 cabe (1:1). +2 acima do floor:
    -- N=2 e N=3 estouram o footprint mas são oferecidos mesmo assim.
    local s = GridIconRotation.getPixelPerfectScales(32, 32, 40, 40, 0, false)
    H.ok(#s == 3, "32px em 40x40 -> N=3,2,1 [" .. tostring(#s) .. "]")
    if #s == 3 then
        H.ok(s[1].N == 3 and s[3].N == 1, "ordenado maior->menor N=3..1 [" .. tostring(s[1].N) .. ".." .. tostring(s[3].N) .. "]")
        H.ok(math.abs(s[3].iconScale - 1/1.1875) < 1e-9, "N=1 iconScale = 1/1.1875 [" .. tostring(s[3].iconScale) .. "]")
    end

    -- 16px em 40x40, baseScale 2.375 → N=4..1; N=1 vira 0.42 < piso 0.5, então
    -- ficam N=4,3,2 (N=4,3 estouram o footprint).
    local s2 = GridIconRotation.getPixelPerfectScales(16, 16, 40, 40, 0, false)
    H.ok(#s2 == 3 and s2[1].N == 4 and s2[3].N == 2, "16px em 40x40 -> N=4,3,2 (N=1 < piso 0.5) [" .. tostring(#s2) .. "]")

    -- 8px em 40x40, baseScale 4.75 → floor+2 = 6; N=2 vira 0.42 < piso, então
    -- ficam N=6..3 (maior primeiro).
    local s3 = GridIconRotation.getPixelPerfectScales(8, 8, 40, 40, 0, false)
    H.ok(#s3 == 4 and s3[1].N == 6 and s3[4].N == 3, "8px em 40x40 -> N=6..3 [" .. tostring(#s3) .. "]")

    -- Textura maior que o footprint: 64px em 40x40, baseScale 0.59 → nenhum N
    -- cabe, mas o nativo 1:1 (1 texel = 1px) ainda é oferecido.
    local s4 = GridIconRotation.getPixelPerfectScales(64, 64, 40, 40, 0, false)
    H.ok(#s4 == 1 and s4[1].N == 1, "64px em 40x40 -> nativo 1:1 [" .. tostring(#s4) .. "]")

    -- Rotação livre 45°: 32px baseScale 0.84 → nativo 1:1 oferecido.
    local s5 = GridIconRotation.getPixelPerfectScales(32, 32, 40, 40, 45, false)
    H.ok(#s5 == 1 and s5[1].N == 1, "32px rot 45° -> nativo 1:1 [" .. tostring(#s5) .. "]")

    -- Inválido → vazio.
    H.ok(#GridIconRotation.getPixelPerfectScales(0, 10, 40, 40, 0, false) == 0, "texW 0 -> vazio")
end

H.finish()
