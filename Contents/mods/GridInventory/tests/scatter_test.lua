-- scatter_test.lua — ScatterLayout.shouldScatter com os 3 modos da Sandbox
-- Option "GridInventoryScatterMode":
--   auto   → só container NUNCA VASCULHADO (isExplored=false) espalha.
--   always → espalha em tudo, inclusive inventário do jogador.
--   never  → nunca espalha, nem em world containers.

local H = require("harness")
H.setName("scatter_test")

_G.getSpecificPlayer = function() return { _mockPlayer = true } end
_G.getSandboxOptions = function() return nil end
local ScatterLayout = require("Algorithm/ScatterLayout")

-- Mock de container com explored + playerInv + itens (getItems). O modo AUTO
-- agora decide pelo estado das posições salvas (não pelo isExplored — o vanilla
-- marca explored na abertura ANTES do nosso refresh). items = lista de mocks
-- de item com getModData (gridX/gridY salvos).
local function makeContainer(explored, isPlayerInv, items)
    local list = items or {}
    return {
        isExplored = function() return explored end,
        isInCharacterInventory = function() return isPlayerInv or false end,
        getType = function() return "crate" end,
        getItems = function()
            return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
        end,
    }
end

-- Mock de container de CHÃO (getType() == "floor")
local function makeFloor()
    return {
        isExplored = function() return false end,
        isInCharacterInventory = function() return false end,
        getType = function() return "floor" end,
        getItems = function()
            return { size = function() return 0 end, get = function() return nil end }
        end,
    }
end

-- Mock de item com posição salva (ou sem)
local function makeItem(gx, gy)
    return {
        getModData = function()
            local md = {}
            if gx then md.gridX = gx end
            if gy then md.gridY = gy end
            return md
        end,
    }
end

local function reset()
    ScatterLayout.enabled = true
    ScatterLayout.scatterModeOverride = nil
    _G.getSandboxOptions = function() return nil end
end

-- ─── Teste 1: desligado → nunca espalha ─────────────────────────────────────
do
    reset()
    ScatterLayout.enabled = false
    H.ok(ScatterLayout.shouldScatter(makeContainer(false, false), 0) == false, "enabled=false -> false")
end

-- ─── Modo AUTO (padrão) ─────────────────────────────────────────────────────
do
    reset()
    H.ok(ScatterLayout.shouldScatter(makeContainer(false, false), 0) == true, "auto: container SEM itens posicionados -> espalha")
    H.ok(ScatterLayout.shouldScatter(makeContainer(true, false, { makeItem(1, 1) }), 0) == false, "auto: com item posicionado -> não espalha")
    H.ok(ScatterLayout.shouldScatter(makeContainer(false, true), 0) == false, "auto: inventário do player -> não espalha")
    -- isExplored NÃO decide mais (o vanilla marca explored na abertura antes do refresh)
    H.ok(ScatterLayout.shouldScatter(makeContainer(true, false), 0) == true, "auto: explorado mas SEM itens posicionados -> espalha (fix do bug)")
end

-- ─── Modo ALWAYS (Desorganizado) ────────────────────────────────────────────
do
    reset()
    ScatterLayout.scatterModeOverride = "always"
    H.ok(ScatterLayout.shouldScatter(makeContainer(true, false), 0) == true, "always: world explorado -> espalha")
    H.ok(ScatterLayout.shouldScatter(makeContainer(false, true), 0) == true, "always: inventário do player -> espalha (penalidade)")
    H.ok(ScatterLayout.shouldScatter(makeContainer(true, true), 0) == true, "always: tudo espalha, ignora trait/explorado")
end

-- ─── Modo NEVER (Organizado) ────────────────────────────────────────────────
do
    reset()
    ScatterLayout.scatterModeOverride = "never"
    H.ok(ScatterLayout.shouldScatter(makeContainer(false, false), 0) == false, "never: world nunca explorado -> NÃO espalha")
    H.ok(ScatterLayout.shouldScatter(makeContainer(true, false), 0) == false, "never: world explorado -> NÃO espalha")
    H.ok(ScatterLayout.shouldScatter(makeContainer(false, true), 0) == false, "never: inventário -> NÃO espalha")
end

-- ─── CHÃO: NUNCA espalha (em qualquer modo) ─────────────────────────────────
-- O chão não persiste posição salva (fix do flicker); com scatter ativo, todo
-- item re-sortearia posição a cada refresh → grid pula de lugar ao adicionar/
-- remover. Sem scatter, o auto-fit é estável (itens novos na 1ª vaga livre).
do
    reset()
    H.ok(ScatterLayout.shouldScatter(makeFloor(), 0) == false, "chão auto -> não espalha")

    reset()
    ScatterLayout.scatterModeOverride = "always"
    H.ok(ScatterLayout.shouldScatter(makeFloor(), 0) == false, "chão always -> NÃO espalha (forçado)")

    reset()
    ScatterLayout.scatterModeOverride = "never"
    H.ok(ScatterLayout.shouldScatter(makeFloor(), 0) == false, "chão never -> não espalha")
end

-- ─── Leitura da Sandbox Option (getSandboxOptions) — valores 1-based ────────
do
    reset()
    local GridSandboxOptions = require("GridSandboxOptions")
    GridSandboxOptions.invalidateCache()
    _G.getSandboxOptions = function()
        return { getOptionByName = function() return { getValue = function() return 2 end } end }
    end
    H.ok(GridSandboxOptions.getScatterMode() == "always", "sandbox value=2 -> always [" .. GridSandboxOptions.getScatterMode() .. "]")
    H.ok(ScatterLayout.shouldScatter(makeContainer(true, false), 0) == true, "via sandbox always -> espalha")

    GridSandboxOptions.invalidateCache()
    _G.getSandboxOptions = function()
        return { getOptionByName = function() return { getValue = function() return 3 end } end }
    end
    H.ok(GridSandboxOptions.getScatterMode() == "never", "sandbox value=3 -> never [" .. GridSandboxOptions.getScatterMode() .. "]")

    GridSandboxOptions.invalidateCache()
    _G.getSandboxOptions = function()
        return { getOptionByName = function() return { getValue = function() return 1 end } end }
    end
    H.ok(GridSandboxOptions.getScatterMode() == "auto", "sandbox value=1 -> auto [" .. GridSandboxOptions.getScatterMode() .. "]")
end

-- ─── Fallback sem getSandboxOptions → auto ──────────────────────────────────
do
    reset()
    local GridSandboxOptions = require("GridSandboxOptions")
    GridSandboxOptions.invalidateCache()
    _G.getSandboxOptions = nil
    H.ok(GridSandboxOptions.getScatterMode() == "auto", "sem sandbox -> auto [" .. GridSandboxOptions.getScatterMode() .. "]")
end

-- ─── Cache do GridSandboxOptions: hit + invalidação ─────────────────────────
do
    reset()
    local GridSandboxOptions = require("GridSandboxOptions")
    GridSandboxOptions.invalidateCache()
    local calls = 0
    _G.getSandboxOptions = function()
        calls = calls + 1
        return { getOptionByName = function() return { getValue = function() return 2 end } end }
    end
    GridSandboxOptions.getScatterMode()
    GridSandboxOptions.getScatterMode()
    GridSandboxOptions.getScatterMode()
    H.ok(calls == 1, "cache: 3 leituras do MESMO getter -> 1 getSandboxOptions [calls=" .. calls .. "]")

    GridSandboxOptions.invalidateCache()
    GridSandboxOptions.getScatterMode()
    H.ok(calls == 2, "invalidateCache: próxima leitura busca de novo [calls=" .. calls .. "]")

    GridSandboxOptions.invalidateCache()
    _G.getSandboxOptions = nil
    H.ok(GridSandboxOptions.getScatterMode() == "auto", "cache sem sandbox -> fallback auto")
    _G.getSandboxOptions = nil
end

H.finish()
