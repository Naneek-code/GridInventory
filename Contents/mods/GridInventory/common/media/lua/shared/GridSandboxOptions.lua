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

-- Cache das leituras: cada getter nativo custa um pcall + getOptionByName (Java),
-- e os hot paths (render por item/frame) chamam isso MUITAS vezes por frame.
-- As opções só mudam no menu de sandbox (fora do jogo ou com o painel fechado),
-- então o cache invalida via Events.OnSandboxOptionChanged quando disponível e
-- também é limpo pelo setSandboxOptionChanged no boot. Leitura é O(1).
local _cache = {}

local _registered = false
local function registerInvalidation()
    if _registered then return end
    _registered = true
    if Events and Events.OnSandboxOptionChanged and Events.OnSandboxOptionChanged.Add then
        Events.OnSandboxOptionChanged.Add(function(opt)
            if not opt then
                _cache = {}
                return
            end
            local name = opt.getName and opt:getName() or nil
            if name then
                -- zera só o cache da opção mudada (lazy re-leitura)
                if name == OPTION_NAME_SCATTER then _cache.scatterMode = nil
                elseif name == OPTION_NAME_REORDER_TIME then _cache.reorderTimed = nil
                elseif name == OPTION_NAME_REORDER_WALK then _cache.reorderWalk = nil
                elseif name == OPTION_NAME_SEARCH_WORLD then _cache.searchWorld = nil
                elseif name == OPTION_NAME_SEARCH_TIME then _cache.searchTime = nil
                elseif name == OPTION_NAME_DEVTOOLS then _cache.devTools = nil
                elseif name == OPTION_NAME_MAX_GRID then _cache.maxGrid = nil
                elseif name == OPTION_NAME_MIN_GRID_W then _cache.minGridW = nil
                elseif name == OPTION_NAME_INV_W then _cache.invW = nil
                elseif name == OPTION_NAME_INV_H then _cache.invH = nil
                elseif name == OPTION_NAME_ICON_ROTATION then _cache.iconRotation = nil
                else _cache = {} end
            else
                _cache = {}
            end
        end)
    end
end

--- Limpa o cache inteiro (usado no boot / troca de mundo). Também registra a
--- invalidação se ainda não registrada.
function GridSandboxOptions.invalidateCache()
    _cache = {}
    registerInvalidation()
end

-- Troca de mundo = sandbox options podem ser diferentes. Zera o cache.
if Events then
    if Events.OnGameStart and Events.OnGameStart.Add then
        Events.OnGameStart.Add(GridSandboxOptions.invalidateCache)
    end
    if Events.OnMainMenuEnter and Events.OnMainMenuEnter.Add then
        Events.OnMainMenuEnter.Add(GridSandboxOptions.invalidateCache)
    end
end

-- Sentinel: diferencia "ainda não cacheado" de "cacheado como nil".
local _NIL = {}

--- Lê uma opção com cache O(1). O valor só é buscado no Java na primeira
--- chamada; depois fica em cache até a opção mudar (invalidação por evento).
local function readOption(cacheKey, optionName, transform, fallback)
    local cached = _cache[cacheKey]
    if cached ~= nil then
        if cached == _NIL then return fallback end
        return cached
    end
    local result = _NIL
    if getSandboxOptions then
        if GridInventory_Profiler then GridInventory_Profiler.count("sandbox") end
        local ok, opt = pcall(function()
            return getSandboxOptions():getOptionByName(optionName)
        end)
        if ok and opt and opt.getValue then
            local raw = opt:getValue()
            if raw ~= nil then
                result = transform(raw)
                if result == nil then result = _NIL end
            end
        end
    end
    _cache[cacheKey] = result
    if result == _NIL then return fallback end
    return result
end

--- Lê o modo de scatter atual.
--- @return "auto" | "always" | "never"
function GridSandboxOptions.getScatterMode()
    return readOption("scatterMode", OPTION_NAME_SCATTER, function(v)
        if v == SCATTER_ALWAYS then return "always" end
        if v == SCATTER_NEVER then return "never" end
        return "auto"
    end, "auto")
end

--- Se o reorder dentro do MESMO grid usa a ação de transferência (animação +
--- pequena latência que dá tempo do servidor processar antes do broadcast).
--- false = aplica instantaneamente, como antes.
--- @return boolean
function GridSandboxOptions.isReorderTimed()
    return readOption("reorderTimed", OPTION_NAME_REORDER_TIME, function(v)
        return v == REORDER_TIMED
    end, true)
end

-- Reorder pode continuar enquanto o jogador ANDA (mas não corre): default true.
local OPTION_NAME_REORDER_WALK = "GridInventory.ReorderMoveWhileWalking"

--- Se a ação de reorder NÃO cancela quando o jogador anda (continua até o
--- perform; parar de andar não interrompe). false = a ação só roda parado.
--- @return boolean
function GridSandboxOptions.isReorderMoveWhileWalking()
    return readOption("reorderWalk", OPTION_NAME_REORDER_WALK, function(v)
        return v == true
    end, true)
end

-- Busca de containers do mundo (estilo Tarkov): default DESLIGADA.
local OPTION_NAME_SEARCH_WORLD = "GridInventory.SearchWorldContainers"
local OPTION_NAME_SEARCH_TIME = "GridInventory.SearchTimePerItem"

--- Se containers do mundo precisam ser vasculhados pra revelar os itens.
--- @return boolean
function GridSandboxOptions.isSearchWorldContainers()
    return readOption("searchWorld", OPTION_NAME_SEARCH_WORLD, function(v)
        return v == true
    end, false)
end

--- Tempo (ms) por pilha revelada durante a busca. 0 = instantâneo.
--- @return number
function GridSandboxOptions.getSearchTimePerItem()
    return readOption("searchTime", OPTION_NAME_SEARCH_TIME, function(v)
        local n = tonumber(v)
        if n == nil then return nil end
        return n
    end, 300)
end

-- DevTools do GridInventory: habilita o menu de contexto "[DevTool] Edit Grid
-- Size" SEM precisar iniciar o jogo com -debug.
local OPTION_NAME_DEVTOOLS = "GridInventory.EnableDevTools"

--- Se o jogador pode usar o DevTool de footprint/grid (override por item).
--- @return boolean
function GridSandboxOptions.isDevToolsEnabled()
    return readOption("devTools", OPTION_NAME_DEVTOOLS, function(v)
        return v == true
    end, false)
end

-- Teto geral do grid de containers de mundo (ajuste em poucos cliques).
-- Substitui o antigo teto hardcoded de 15 linhas. O override específico do
-- DevTool pode EXPANDIR além desse teto (override firme, como footprints).
local OPTION_NAME_MAX_GRID = "GridInventory.MaxContainerGridSize"

--- Teto geral (linhas) do grid de containers de mundo.
--- @return number
function GridSandboxOptions.getMaxContainerGridSize()
    return readOption("maxGrid", OPTION_NAME_MAX_GRID, function(v)
        local n = tonumber(v)
        if n == nil or n <= 0 then return nil end
        return n
    end, 15)
end

-- Largura base dos containers de mundo (ajuste geral em poucos cliques). O
-- override específico do DevTool por tipo continua substituindo.
local OPTION_NAME_MIN_GRID_W = "GridInventory.MinWorldWidthGridSize"

--- Largura base (colunas) do grid de containers de mundo (default 6).
--- @return number
function GridSandboxOptions.getMinWorldGridWidth()
    return readOption("minGridW", OPTION_NAME_MIN_GRID_W, function(v)
        local n = tonumber(v)
        if n == nil or n <= 0 then return nil end
        return n
    end, 6)
end

-- Tamanho do grid do INVENTÁRIO do jogador (largura/altura fixas — o jogador
-- não tem nada que "escalone" o tamanho; o override ["player"] firme pode
-- sobrescrever pra gostos específicos).
local OPTION_NAME_INV_W = "GridInventory.InventoryPlayerWidth"
local OPTION_NAME_INV_H = "GridInventory.InventoryPlayerHeight"

--- Largura do grid do inventário do jogador (default 3).
--- @return number
function GridSandboxOptions.getPlayerInventoryWidth()
    return readOption("invW", OPTION_NAME_INV_W, function(v)
        local n = tonumber(v)
        if n == nil or n <= 0 then return nil end
        return n
    end, 3)
end

--- Altura do grid do inventário do jogador (default 4).
--- @return number
function GridSandboxOptions.getPlayerInventoryHeight()
    return readOption("invH", OPTION_NAME_INV_H, function(v)
        local n = tonumber(v)
        if n == nil or n <= 0 then return nil end
        return n
    end, 4)
end

-- Rotação/escala/anchor de sprites (override visual do DevTool): default
-- DESLIGADO (false). Ligado só quando o servidor quer aplicar os ajustes
-- visuais do hardcoded/ini. Default OFF é POR COMPATIBILIDADE: jogadores com
-- save/ini antigos (criados antes de existir angle/scale/anchor) não podem ver
-- o sprite deles mudar do nada — então a opção nasce desligada e o servidor
-- liga se quiser o tuning visual.
local OPTION_NAME_ICON_ROTATION = "GridInventory.IconRotation"

--- Se os overrides de rotação/escala/anchor de sprite são aplicados na render.
--- false (default) = todos os jogadores veem os sprites no padrão (angle=0,
--- scale=1, anchor=0), independente do que o hardcoded/ini tem. true = aplica
--- os overrides visuais. O servidor decide (a opção de sandbox é do mundo,
--- sincronizada pra todos).
--- @return boolean
function GridSandboxOptions.isIconRotationEnabled()
    return readOption("iconRotation", OPTION_NAME_ICON_ROTATION, function(v)
        return v == true
    end, false)
end

return GridSandboxOptions
