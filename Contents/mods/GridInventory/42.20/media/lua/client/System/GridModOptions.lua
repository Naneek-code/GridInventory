--- GridModOptions.lua
--- Mod Options nativas do B42 (PZAPI.ModOptions) + cache de leitura do mod.
---
--- As options aparecem em Opções → MODS e são persistidas em ModOptions.ini
--- pelo PZAPI. O cache (GridInventory_ModOptions.cache) é a fonte de verdade
--- usada pelos hijacks do mod; ele é sincronizado em 3 momentos:
---   1) no boot, lendo o ModOptions.ini DIRETAMENTE — o PZAPI só lê o ini
---      quando a aba MODS das Opções é aberta; sem essa leitura o mod usaria
---      os defaults até o usuário abrir as opções, ignorando valores salvos
---      na primeira sessão após o boot;
---   2) no apply do usuário (botão OK da aba MODS) — o jogo chama
---      section.apply e aí o PZAPI já tem os valores da UI como fonte;
---   3) ao entrar/sair de um mundo (releitura defensiva do ini).
---
--- Idempotência: o arquivo vive em media/lua/client/System e PODE ser
--- carregado duas vezes (auto-loader do jogo + require dos Hooks). O módulo é
--- um global (GridInventory_ModOptions) com flag "registered", então o
--- registro no PZAPI acontece só uma vez e o cache é compartilhado.

GridInventory_ModOptions = GridInventory_ModOptions or {}
local GridModOptions = GridInventory_ModOptions

GridModOptions.cache = GridModOptions.cache or {
    fullscreenPanel = true,
    multiContainerInv = true,
    multiContainerLoot = true,
    closeOnEsc = true,
    uiScale = 100,
}

local cache = GridModOptions.cache

local DEFAULTS = {
    fullscreenPanel = true,
    multiContainerInv = true,
    multiContainerLoot = true,
    closeOnEsc = true,
    uiScale = 100,
}

local function toBool(value, default)
    if value == nil then return default end
    if type(value) == "boolean" then return value end
    return value == true or value == "true" or value == "1" or value == 1
end

local function toNumber(value, default)
    if value == nil then return default end
    local n = tonumber(value)
    if n == nil then return default end
    return n
end

local function split(line, sep)
    local parts = {}
    for m in (line .. sep):gmatch("(.-)" .. sep) do
        table.insert(parts, m)
    end
    return parts
end

-- Lê o ModOptions.ini e aplica no cache. Formato de cada linha (save do
-- PZAPI, ver PZAPI.ModOptions:save): "tickbox|GridInventory|fullscreenPanel|true".
local function applyIni()
    local ok, file = pcall(function()
        return getFileReader("ModOptions.ini", true)
    end)
    if not ok or not file then return end
    local ok2, err = pcall(function()
        while true do
            local line = file:readLine()
            if line == nil then break end
            local parts = split(line, "|")
            if parts[2] == "GridInventory" and parts[3] and parts[4] ~= nil then
                -- O PZAPI grava o ini com \r\n; o readLine pode manter o \r.
                local value = parts[4]:gsub("\r$", ""):gsub("%s+$", "")
                if parts[3] == "uiScale" then
                    cache[parts[3]] = toNumber(value, DEFAULTS[parts[3]])
                else
                    cache[parts[3]] = toBool(value, cache[parts[3]])
                end
            end
        end
    end)
    if not ok2 then
        print("[GridInventory] ERRO ao ler ModOptions.ini: " .. tostring(err))
    end
end

-- Sincroniza o cache a partir das options registradas no PZAPI (fonte de
-- verdade DEPOIS que o usuário mexe na aba MODS e clica em OK — nesse ponto
-- o gameOption.apply do vanilla já gravou os novos valores em option.value).
local function syncFromPZAPI()
    local ok, section = pcall(function()
        if not (PZAPI and PZAPI.ModOptions and PZAPI.ModOptions.getOptions) then
            return nil
        end
        return PZAPI.ModOptions:getOptions("GridInventory")
    end)
    if not ok or not section then return end
    for id, default in pairs(DEFAULTS) do
        local option = section:getOption(id)
        if option then
            local okv, value = pcall(function() return option:getValue() end)
            if okv then
                if id == "uiScale" then
                    cache[id] = toNumber(value, default)
                else
                    cache[id] = toBool(value, default)
                end
            end
        end
    end
end

-- Reconstroi os grids de todos os painéis abertos (inv + loot) de todos os
-- jogadores, para as Mod Options valerem imediatamente.
local function refreshPanes()
    for p = 0, getNumActivePlayers() - 1 do
        local inv = getPlayerInventory(p)
        local loot = getPlayerLoot(p)
        for _, page in ipairs({ inv, loot }) do
            if page and page.inventoryPane and page.inventoryPane.refreshContainer then
                local pane = page.inventoryPane
                pane.gridRefreshDirty = nil
                pane.lastBackpackHash = nil
                pcall(function() pane:refreshContainer() end)
            end
        end
    end
end

-- Atualiza a largura do PaperDoll quando o UI Scale muda. O conteúdo interno
-- (avatar/slots/hotbar) é reposicionado pelo relayout() do próprio PaperDoll
-- (detectado no prerender ao comparar o scale global). Aqui só ajustamos a
-- largura da janela — sem destruir/recriar (que causava gap de altura).
local function refreshPaperDoll()
    local scale = GridInventory_uiScale or 100
    for p = 0, getNumActivePlayers() - 1 do
        local pdMap = GridInventory_PaperDollWindow
        local pd = pdMap and pdMap[p]
        if pd then
            local s = scale / 100
            local pdW = math.floor(350 * s)
            pcall(function()
                if pd.setWidth then pd:setWidth(pdW) end
                if pd.relayout then pd:relayout() end
            end)
        end
    end
end

local function registerOptions()
    local ok, pzapi = pcall(function() return PZAPI end)
    if not (ok and pzapi and pzapi.ModOptions and pzapi.ModOptions.create) then
        return
    end

    local ok2, section = pcall(function()
        return pzapi.ModOptions:create("GridInventory", getText("IGUI_GridInv_OptionsSection"))
    end)
    if not ok2 or not section then return end

    section:addTickBox("fullscreenPanel",
        getText("IGUI_GridInv_OptionsFullscreenPanel"), true,
        getText("IGUI_GridInv_OptionsFullscreenPanel_Tooltip"))
    section:addSeparator()
    section:addTickBox("multiContainerInv",
        getText("IGUI_GridInv_OptionsMultiContainerInv"), true,
        getText("IGUI_GridInv_OptionsMultiContainerInv_Tooltip"))
    section:addTickBox("multiContainerLoot",
        getText("IGUI_GridInv_OptionsMultiContainerLoot"), true,
        getText("IGUI_GridInv_OptionsMultiContainerLoot_Tooltip"))
    section:addSeparator()
    section:addTickBox("closeOnEsc",
        getText("IGUI_GridInv_OptionsCloseOnEsc"), true,
        getText("IGUI_GridInv_OptionsCloseOnEsc_Tooltip"))
    section:addSeparator()
    section:addSlider("uiScale",
        getText("IGUI_GridInv_OptionsUiScale"), 50, 150, 5, 100,
        getText("IGUI_GridInv_OptionsUiScale_Tooltip"))

    -- Chamado pelo jogo (MainOptions:apply) quando o usuário clica em OK na
    -- aba MODS: a UI já gravou os valores; só re-sincronizamos o cache.
    section.apply = function()
        syncFromPZAPI()
        -- Mantém o global de scale em sincronia pro render usar na hora.
        GridInventory_uiScale = GridModOptions.getUiScale()
        -- Recria o PaperDoll se o scale mudou (dimensões são fixas no init).
        refreshPaperDoll()
        -- Força rebuild imediato dos grids para as options valerem na hora
        -- (sem esperar o próximo evento de container).
        refreshPanes()
    end
    return true
end

-- Tenta registrar as options no PZAPI. Se o PZAPI ainda não carregou (ordem
-- de load de mods varia), NÃO marca como registrado: os eventos abaixo re-tentam
-- quando o PZAPI com certeza já existe. Com o PZAPI já presente, a flag evita
-- re-registrar no segundo load (auto-loader + require do mesmo arquivo).
GridModOptions.registered = GridModOptions.registered or false

local function tryRegister()
    if not GridModOptions.registered then
        GridModOptions.registered = registerOptions() == true
    end
end

tryRegister()
applyIni()
-- Releitura defensiva: ao entrar/sair de mundo o contexto do save muda e
-- o PZAPI pode reescrever o ini (ModOptions:save durante o jogo).
Events.OnMainMenuEnter.Add(function()
    tryRegister()
    applyIni()
    GridInventory_uiScale = GridModOptions.getUiScale()
end)
Events.OnGameStart.Add(function()
    tryRegister()
    applyIni()
    GridInventory_uiScale = GridModOptions.getUiScale()
end)

function GridModOptions.isFullscreenPanel()
    return cache.fullscreenPanel
end

function GridModOptions.isMultiContainerInv()
    return cache.multiContainerInv
end

function GridModOptions.isMultiContainerLoot()
    return cache.multiContainerLoot
end

function GridModOptions.isCloseOnEsc()
    return cache.closeOnEsc
end

-- Fator de escala da UI dos grids (%). 100 = tamanho original.
function GridModOptions.getUiScale()
    local s = toNumber(cache.uiScale, 100)
    if s < 50 then s = 50 end
    if s > 150 then s = 150 end
    return s
end

-- Global leve usado pelos renders (GridRender/OverflowGridRender/GlobalDragRender)
-- pra calcular o cellSize sem require circular. Mantido em sincronia com o cache.
GridInventory_uiScale = GridModOptions.getUiScale()

return GridModOptions
