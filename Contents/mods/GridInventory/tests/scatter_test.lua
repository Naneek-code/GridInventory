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

-- Mock de container com explored + playerInv
local function makeContainer(explored, isPlayerInv)
    return {
        isExplored = function() return explored end,
        isInCharacterInventory = function() return isPlayerInv or false end,
        getType = function() return "crate" end,
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
    H.ok(ScatterLayout.shouldScatter(makeContainer(false, false), 0) == true, "auto: nunca explorado -> espalha")
    H.ok(ScatterLayout.shouldScatter(makeContainer(true, false), 0) == false, "auto: explorado -> não espalha")
    H.ok(ScatterLayout.shouldScatter(makeContainer(false, true), 0) == false, "auto: inventário do player -> não espalha")
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

-- ─── Leitura da Sandbox Option (getSandboxOptions) — valores 1-based ────────
do
    reset()
    local GridSandboxOptions = require("GridSandboxOptions")
    _G.getSandboxOptions = function()
        return { getOptionByName = function() return { getValue = function() return 2 end } end }
    end
    H.ok(GridSandboxOptions.getScatterMode() == "always", "sandbox value=2 -> always [" .. GridSandboxOptions.getScatterMode() .. "]")
    H.ok(ScatterLayout.shouldScatter(makeContainer(true, false), 0) == true, "via sandbox always -> espalha")

    _G.getSandboxOptions = function()
        return { getOptionByName = function() return { getValue = function() return 3 end } end }
    end
    H.ok(GridSandboxOptions.getScatterMode() == "never", "sandbox value=3 -> never [" .. GridSandboxOptions.getScatterMode() .. "]")

    _G.getSandboxOptions = function()
        return { getOptionByName = function() return { getValue = function() return 1 end } end }
    end
    H.ok(GridSandboxOptions.getScatterMode() == "auto", "sandbox value=1 -> auto [" .. GridSandboxOptions.getScatterMode() .. "]")
end

-- ─── Fallback sem getSandboxOptions → auto ──────────────────────────────────
do
    reset()
    local GridSandboxOptions = require("GridSandboxOptions")
    H.ok(GridSandboxOptions.getScatterMode() == "auto", "sem sandbox -> auto [" .. GridSandboxOptions.getScatterMode() .. "]")
end

H.finish()
