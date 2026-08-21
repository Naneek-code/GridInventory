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
    panelOpacity = 90,
    gradientFast = false,
    solidFootprint = false,
    autoSearch = false,
    modifierCtrl = 1,
    modifierShift = 5,
    modifierAlt = 6,
    modifierRightCtrl = 6,
    modifierRightShift = 6,
    modifierRightAlt = 6,
}

local cache = GridModOptions.cache

local DEFAULTS = {
    fullscreenPanel = true,
    multiContainerInv = true,
    multiContainerLoot = true,
    closeOnEsc = true,
    uiScale = 100,
    panelOpacity = 90,
    gradientFast = false,
    solidFootprint = false,
    autoSearch = false,
    paperDollLeft = false,
    modifierCtrl = 1,
    modifierShift = 5,
    modifierAlt = 6,
    modifierRightCtrl = 6,
    modifierRightShift = 6,
    modifierRightAlt = 6,
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
                if parts[3] == "uiScale" or parts[3] == "panelOpacity" then
                    cache[parts[3]] = toNumber(value, DEFAULTS[parts[3]])
                else
                    if parts[3] == "modifierCtrl" or parts[3] == "modifierShift" or parts[3] == "modifierAlt" or parts[3] == "modifierRightCtrl" or parts[3] == "modifierRightShift" or parts[3] == "modifierRightAlt" then
                cache[parts[3]] = tonumber(value) or cache[parts[3]]
            else
                cache[parts[3]] = toBool(value, cache[parts[3]])
            end
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
                if id == "uiScale" or id == "panelOpacity" or id:sub(1, 8) == "modifier" then
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
                local okRef, errRef = pcall(function() pane:refreshContainer() end)
                if not okRef then
                    print("[GridInventory] ERRO ao aplicar opção (refreshContainer): " .. tostring(errRef))
                end
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
            local okPD, errPD = pcall(function()
                if pd.setWidth then pd:setWidth(pdW) end
                if pd.relayout then pd:relayout() end
            end)
            if not okPD then
                print("[GridInventory] ERRO ao aplicar opção (PaperDoll relayout): " .. tostring(errPD))
            end
        end
    end
end

local function registerOptions()
    local pzapi = PZAPI
    if not (pzapi and pzapi.ModOptions and pzapi.ModOptions.create) then
        return
    end

    local ok2, section = pcall(function()
        return pzapi.ModOptions:create("GridInventory", getText("IGUI_GridInv_OptionsSection"))
    end)
    if not ok2 or not section then return end

    section:addTitle(getText("IGUI_GridInv_Section_Window") or "Window Behavior")
    section:addTickBox("fullscreenPanel",
        getText("IGUI_GridInv_OptionsFullscreenPanel"), true,
        getText("IGUI_GridInv_OptionsFullscreenPanel_Tooltip"))
    section:addTickBox("closeOnEsc",
        getText("IGUI_GridInv_OptionsCloseOnEsc"), true,
        getText("IGUI_GridInv_OptionsCloseOnEsc_Tooltip"))
    section:addSeparator()
    section:addTitle(getText("IGUI_GridInv_Section_Mechanics") or "Grid Mechanics")
    section:addTickBox("multiContainerInv",
        getText("IGUI_GridInv_OptionsMultiContainerInv"), true,
        getText("IGUI_GridInv_OptionsMultiContainerInv_Tooltip"))
    section:addTickBox("multiContainerLoot",
        getText("IGUI_GridInv_OptionsMultiContainerLoot"), true,
        getText("IGUI_GridInv_OptionsMultiContainerLoot_Tooltip"))
    section:addTickBox("autoSearch",
        getText("IGUI_GridInv_OptionsAutoSearch") or "Auto-Search Active Container", false,
        getText("IGUI_GridInv_OptionsAutoSearch_Tooltip") or "Automatically initiates search when you select an unsearched container.")
    section:addSeparator()
    section:addTitle(getText("IGUI_GridInv_Section_Appearance") or "Appearance / UI")
    section:addSlider("uiScale",
        getText("IGUI_GridInv_OptionsUiScale"), 50, 150, 5, 100,
        getText("IGUI_GridInv_OptionsUiScale_Tooltip"))
    section:addSlider("panelOpacity",
        getText("IGUI_GridInv_OptionsPanelOpacity") or "Background Opacity", 50, 100, 5, 90,
        getText("IGUI_GridInv_OptionsPanelOpacity_Tooltip") or "Adjust the opacity of the inventory backgrounds.")
    section:addSeparator()
    section:addTitle(getText("IGUI_GridInv_Section_Layout") or "Layout")
    section:addTickBox("paperDollLeft", 
        getText("IGUI_GridInv_OptionsPaperDollLeft"), false,
        getText("IGUI_GridInv_OptionsPaperDollLeft_Tooltip"))
    section:addSeparator()
    section:addTitle(getText("IGUI_GridInv_Section_Performance") or "Graphical Performance")
    section:addTickBox("gradientFast",
        getText("IGUI_GridInv_OptionsGradientFast"), false,
        getText("IGUI_GridInv_OptionsGradientFast_Tooltip"))
    section:addTickBox("solidFootprint",
        getText("IGUI_GridInv_OptionsSolidFootprint") or "Solid Footprints (Performance)", false,
        getText("IGUI_GridInv_OptionsSolidFootprint_Tooltip") or "Renders a solid color instead of a gradient, massively improving FPS.")

    section:addSeparator()
    section:addTitle(getText("IGUI_GridInv_Section_Shortcuts") or "Mouse Modifiers / Shortcuts")
    local modifierChoices = {
        getText("IGUI_GridInv_ModAction_StackPicker") or "Open Stack Picker",
        getText("IGUI_GridInv_ModAction_TakeOne") or "Take One (Split 1x)",
        getText("IGUI_GridInv_ModAction_QuickTransfer") or "Quick Transfer",
        getText("IGUI_GridInv_ModAction_DropFloor") or "Drop to Floor",
        getText("IGUI_GridInv_ModAction_MultiSelect") or "Multi-Select",
        getText("IGUI_GridInv_ModAction_Disabled") or "Disabled"
    }

    local ctrlAction = cache.modifierCtrl or 1
    local shiftAction = cache.modifierShift or 5
    local altAction = cache.modifierAlt or 6

    local ctrlCombo = section:addComboBox("modifierCtrl",
        getText("IGUI_GridInv_OptionsModifierCtrl") or "Ctrl + Click Action",
        getText("IGUI_GridInv_OptionsModifierCtrl_Tooltip") or "Action performed when clicking an item while holding Ctrl.")
    for i, choice in ipairs(modifierChoices) do ctrlCombo:addItem(choice, i == ctrlAction) end

    local shiftCombo = section:addComboBox("modifierShift",
        getText("IGUI_GridInv_OptionsModifierShift") or "Shift + Click Action",
        getText("IGUI_GridInv_OptionsModifierShift_Tooltip") or "Action performed when clicking an item while holding Shift.")
    for i, choice in ipairs(modifierChoices) do shiftCombo:addItem(choice, i == shiftAction) end

    local altCombo = section:addComboBox("modifierAlt",
        getText("IGUI_GridInv_OptionsModifierAlt") or "Alt + Click Action",
        getText("IGUI_GridInv_OptionsModifierAlt_Tooltip") or "Action performed when clicking an item while holding Alt.")
    for i, choice in ipairs(modifierChoices) do altCombo:addItem(choice, i == altAction) end

    local rightCtrlAction = cache.modifierRightCtrl or 6
    local rightShiftAction = cache.modifierRightShift or 6
    local rightAltAction = cache.modifierRightAlt or 6

    local rightCtrlCombo = section:addComboBox("modifierRightCtrl",
        getText("IGUI_GridInv_OptionsModifierRightCtrl") or "Ctrl + Right Click",
        getText("IGUI_GridInv_OptionsModifierRightCtrl_Tooltip") or "Action performed when right clicking an item while holding Ctrl.")
    for i, choice in ipairs(modifierChoices) do rightCtrlCombo:addItem(choice, i == rightCtrlAction) end

    local rightShiftCombo = section:addComboBox("modifierRightShift",
        getText("IGUI_GridInv_OptionsModifierRightShift") or "Shift + Right Click",
        getText("IGUI_GridInv_OptionsModifierRightShift_Tooltip") or "Action performed when right clicking an item while holding Shift.")
    for i, choice in ipairs(modifierChoices) do rightShiftCombo:addItem(choice, i == rightShiftAction) end

    local rightAltCombo = section:addComboBox("modifierRightAlt",
        getText("IGUI_GridInv_OptionsModifierRightAlt") or "Alt + Right Click",
        getText("IGUI_GridInv_OptionsModifierRightAlt_Tooltip") or "Action performed when right clicking an item while holding Alt.")
    for i, choice in ipairs(modifierChoices) do rightAltCombo:addItem(choice, i == rightAltAction) end

    -- Chamado pelo jogo (MainOptions:apply) quando o usuário clica em OK na
    -- aba MODS: a UI já gravou os valores; só re-sincronizamos o cache.
    section.apply = function()
        syncFromPZAPI()
        -- Mantém o global de scale em sincronia pro render usar na hora.
        GridInventory_uiScale = GridModOptions.getUiScale()
    GridInventory_PanelOpacity = GridModOptions.getPanelOpacity()
        GridInventory_PanelOpacity = GridModOptions.getPanelOpacity()
        -- Mantém o global de faixas do degrade em sincronia pro ItemCategory
        -- (shared, sem require circular) usar na hora.
        GridInventory_gradientSteps = GridModOptions.getGradientSteps()
        -- Globais de joypad (lidos pelo GridJoypad a cada movimento/polling).
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
    GridInventory_PanelOpacity = GridModOptions.getPanelOpacity()
    GridInventory_gradientSteps = GridModOptions.getGradientSteps()
end)
Events.OnGameStart.Add(function()
    tryRegister()
    applyIni()
    GridInventory_uiScale = GridModOptions.getUiScale()
    GridInventory_PanelOpacity = GridModOptions.getPanelOpacity()
    GridInventory_gradientSteps = GridModOptions.getGradientSteps()
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

-- Opacidade dos painéis (0-100%). 80 = padrão do Zomboid.
function GridModOptions.getPanelOpacity()
    local o = toNumber(cache.panelOpacity, 90)
    if o < 50 then o = 50 end
    if o > 100 then o = 100 end
    return o / 100
end

function GridModOptions.isPaperDollLeft()
    return cache.paperDollLeft == true
end

-- Se o degrade do footprint usa poucas faixas (6 = rápido) em vez de 12
-- (suave, padrão). Cada jogador escolhe o da PRÓPRIA máquina — é preferência
-- visual/perf do cliente, por isso é Mod Option e não Sandbox Option.
function GridModOptions.isGradientFast()
    return cache.gradientFast == true
end

-- Nº de faixas do degrade (12 ou 6) pro ItemCategory (shared) usar no render.
function GridModOptions.getGradientSteps()
    if cache.solidFootprint == true then return 1 end
    function GridModOptions.getModifierAction(modifier)
    if modifier == "Ctrl" then return cache.modifierCtrl or 1 end
    if modifier == "Shift" then return cache.modifierShift or 5 end
    if modifier == "Alt" then return cache.modifierAlt or 6 end
    if modifier == "RightCtrl" then return cache.modifierRightCtrl or 6 end
    if modifier == "RightShift" then return cache.modifierRightShift or 6 end
    if modifier == "RightAlt" then return cache.modifierRightAlt or 6 end
    return 6
end

return GridModOptions.isGradientFast() and 6 or 12
end

-- Global leve usado pelo ItemCategory.getGradient/getSubtleGradient (módulo
-- shared, sem require circular do GridModOptions que é client-only). Mantido
-- em sincronia com o cache nos mesmos pontos do GridInventory_uiScale.
GridInventory_gradientSteps = GridModOptions.getGradientSteps()

-- Global leve usado pelos renders (GridRender/OverflowGridRender/GlobalDragRender)
-- pra calcular o cellSize sem require circular. Mantido em sincronia com o cache.
GridInventory_uiScale = GridModOptions.getUiScale()
GridInventory_PanelOpacity = GridModOptions.getPanelOpacity()

function GridModOptions.getModifierAction(modifier)
    if modifier == "Ctrl" then return cache.modifierCtrl or 1 end
    if modifier == "Shift" then return cache.modifierShift or 5 end
    if modifier == "Alt" then return cache.modifierAlt or 6 end
    if modifier == "RightCtrl" then return cache.modifierRightCtrl or 6 end
    if modifier == "RightShift" then return cache.modifierRightShift or 6 end
    if modifier == "RightAlt" then return cache.modifierRightAlt or 6 end
    return 6
end

return GridModOptions
