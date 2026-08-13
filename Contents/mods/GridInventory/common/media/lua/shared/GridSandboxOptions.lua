--- GridSandboxOptions.lua
--- Leitura das Sandbox Options do GridInventory.
---
--- As opções são DEFINIDAS em media/sandbox-options.txt (mecanismo NATIVO do
--- B42: o jogo registra e cria a página no menu de sandbox automaticamente a
--- partir desse arquivo — sem bootstrap Lua). Este módulo só expõe leituras.

local GridSandboxOptions = {}

-- Nome completo da opção (prefixo da página + ponto + opção), como o
-- getOptionByName espera. Valores do enum são 1-BASED (padrão do PZ):
--   1 = auto, 2 = always, 3 = never
local OPTION_NAME_SCATTER = "GridInventory.ScatterMode"
local SCATTER_AUTO, SCATTER_ALWAYS, SCATTER_NEVER = 1, 2, 3

-- Reorder dentro do mesmo grid: 1 = animação de transferência (padrão), 2 = instantâneo.
local OPTION_NAME_REORDER_TIME = "GridInventory.ReorderTimeAction"
local REORDER_TIMED = 1

--- Lê o modo de scatter atual.
--- @return "auto" | "always" | "never"
function GridSandboxOptions.getScatterMode()
    if getSandboxOptions then
        local ok, opt = pcall(function()
            return getSandboxOptions():getOptionByName(OPTION_NAME_SCATTER)
        end)
        if ok and opt and opt.getValue then
            local v = opt:getValue()
            if v == SCATTER_ALWAYS then return "always" end
            if v == SCATTER_NEVER then return "never" end
        end
    end
    return "auto"
end

--- Se o reorder dentro do MESMO grid usa a ação de transferência (animação +
--- pequena latência que dá tempo do servidor processar antes do broadcast).
--- false = aplica instantaneamente, como antes.
--- @return boolean
function GridSandboxOptions.isReorderTimed()
    if getSandboxOptions then
        local ok, opt = pcall(function()
            return getSandboxOptions():getOptionByName(OPTION_NAME_REORDER_TIME)
        end)
        if ok and opt and opt.getValue then
            return opt:getValue() == REORDER_TIMED
        end
    end
    return true
end

-- Reorder pode continuar enquanto o jogador ANDA (mas não corre): default true.
local OPTION_NAME_REORDER_WALK = "GridInventory.ReorderMoveWhileWalking"

--- Se a ação de reorder NÃO cancela quando o jogador anda (continua até o
--- perform; parar de andar não interrompe). false = a ação só roda parado.
--- @return boolean
function GridSandboxOptions.isReorderMoveWhileWalking()
    if getSandboxOptions then
        local ok, opt = pcall(function()
            return getSandboxOptions():getOptionByName(OPTION_NAME_REORDER_WALK)
        end)
        if ok and opt and opt.getValue then
            return opt:getValue()
        end
    end
    return true
end

-- Busca de containers do mundo (estilo Tarkov): default DESLIGADA.
local OPTION_NAME_SEARCH_WORLD = "GridInventory.SearchWorldContainers"
local OPTION_NAME_SEARCH_TIME = "GridInventory.SearchTimePerItem"

--- Se containers do mundo precisam ser vasculhados pra revelar os itens.
--- @return boolean
function GridSandboxOptions.isSearchWorldContainers()
    if getSandboxOptions then
        local ok, opt = pcall(function()
            return getSandboxOptions():getOptionByName(OPTION_NAME_SEARCH_WORLD)
        end)
        if ok and opt and opt.getValue then
            return opt:getValue()
        end
    end
    return false
end

--- Tempo (ms) por pilha revelada durante a busca. 0 = instantâneo.
--- @return number
function GridSandboxOptions.getSearchTimePerItem()
    if getSandboxOptions then
        local ok, opt = pcall(function()
            return getSandboxOptions():getOptionByName(OPTION_NAME_SEARCH_TIME)
        end)
        if ok and opt and opt.getValue then
            return tonumber(opt:getValue()) or 300
        end
    end
    return 300
end

-- DevTools do GridInventory: habilita o menu de contexto "[DevTool] Edit Grid
-- Size" SEM precisar iniciar o jogo com -debug.
local OPTION_NAME_DEVTOOLS = "GridInventory.EnableDevTools"

--- Se o jogador pode usar o DevTool de footprint/grid (override por item).
--- @return boolean
function GridSandboxOptions.isDevToolsEnabled()
    if getSandboxOptions then
        local ok, opt = pcall(function()
            return getSandboxOptions():getOptionByName(OPTION_NAME_DEVTOOLS)
        end)
        if ok and opt and opt.getValue then
            return opt:getValue()
        end
    end
    return false
end

-- Teto geral do grid de containers de mundo (ajuste em poucos cliques).
-- Substitui o antigo teto hardcoded de 15 linhas. O override específico do
-- DevTool pode EXPANDIR além desse teto (override firme, como footprints).
local OPTION_NAME_MAX_GRID = "GridInventory.MaxContainerGridSize"

--- Teto geral (linhas) do grid de containers de mundo.
--- @return number
function GridSandboxOptions.getMaxContainerGridSize()
    if getSandboxOptions then
        local ok, opt = pcall(function()
            return getSandboxOptions():getOptionByName(OPTION_NAME_MAX_GRID)
        end)
        if ok and opt and opt.getValue then
            local v = tonumber(opt:getValue())
            if v and v > 0 then return v end
        end
    end
    return 15
end

-- Largura base dos containers de mundo (ajuste geral em poucos cliques). O
-- override específico do DevTool por tipo continua substituindo.
local OPTION_NAME_MIN_GRID_W = "GridInventory.MinWorldWidthGridSize"

--- Largura base (colunas) do grid de containers de mundo (default 6).
--- @return number
function GridSandboxOptions.getMinWorldGridWidth()
    if getSandboxOptions then
        local ok, opt = pcall(function()
            return getSandboxOptions():getOptionByName(OPTION_NAME_MIN_GRID_W)
        end)
        if ok and opt and opt.getValue then
            local v = tonumber(opt:getValue())
            if v and v > 0 then return v end
        end
    end
    return 6
end

-- Tamanho do grid do INVENTÁRIO do jogador (largura/altura fixas — o jogador
-- não tem nada que "escalone" o tamanho; o override ["player"] firme pode
-- sobrescrever pra gostos específicos).
local OPTION_NAME_INV_W = "GridInventory.InventoryPlayerWidth"
local OPTION_NAME_INV_H = "GridInventory.InventoryPlayerHeight"

--- Largura do grid do inventário do jogador (default 3).
--- @return number
function GridSandboxOptions.getPlayerInventoryWidth()
    if getSandboxOptions then
        local ok, opt = pcall(function()
            return getSandboxOptions():getOptionByName(OPTION_NAME_INV_W)
        end)
        if ok and opt and opt.getValue then
            local v = tonumber(opt:getValue())
            if v and v > 0 then return v end
        end
    end
    return 3
end

--- Altura do grid do inventário do jogador (default 4).
--- @return number
function GridSandboxOptions.getPlayerInventoryHeight()
    if getSandboxOptions then
        local ok, opt = pcall(function()
            return getSandboxOptions():getOptionByName(OPTION_NAME_INV_H)
        end)
        if ok and opt and opt.getValue then
            local v = tonumber(opt:getValue())
            if v and v > 0 then return v end
        end
    end
    return 4
end

return GridSandboxOptions
