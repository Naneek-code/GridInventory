--- GridDevBrowser.lua (CLIENT)
--- Browser de itens do jogo (debug): navega por categoria com busca e
--- paginação, mostrando o footprint atual (WxH) e o marcador de override, e
--- abre o GridDevTool num item com 1 clique. A lógica de catálogo (enumeração,
--- filtro, paginação) vive no módulo SHARED Algorithm/GridItemCatalog (testável);
--- aqui fica só a UI + o build incremental do catálogo (instancia itens de
--- verdade em chunks pra não congelar o jogo).

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISLabel"
require "ISUI/ISComboBox"
require "ISUI/ISTextEntryBox"
require "DevTool/GridOverrides"

local GridItemCatalog = require("Algorithm/GridItemCatalog")
local ItemCategory = require("Algorithm/ItemCategory")
local ItemFootprint = require("Algorithm/ItemFootprint")

--- Gate de acesso (fail-closed): só admin (MP) / debug ou sandbox option (SP)
--- — mesma regra do GridDevTool. O browser não tem side effects, mas evita que
--- não-admin abra uma janela que existe pra tunar o jogo.
local function canUseDevTools()
    local GridSandboxOptions = require("GridSandboxOptions")
    local enabled = GridSandboxOptions.isDevToolsEnabled()
    if isClient() then
        if not enabled then return false end
        local playerObj = getPlayer()
        if not playerObj then return false end
        local GridAdmin = require("System/GridAdmin")
        return GridAdmin.isAdmin(playerObj)
    end
    return isDebugEnabled() or enabled
end

--- Build incremental do catálogo. getAllItems() retorna a lista Java de
--- ScriptItem; a gente converte pra array Lua (barato) e processa N itens por
--- frame no update() — instanciar TODOS de uma vez congelaria o jogo. O
--- resultado é cacheado no módulo: reabrir o browser é instantâneo.
--- O classificador usa instanceItem (instância real) → ItemCategory + footprint
--- reais, os MESMOS que o render usa (a categoria do browser bate com a cor do
--- footprint no jogo).
GridDevBrowser = {
    cache = nil,          -- table de entries (GridItemCatalog) pronta
    working = {},         -- entries acumuladas durante o build
    source = nil,         -- array Lua de ScriptItem (referência pro build)
    sourceCount = 0,      -- total de ScriptItems
    buildIndex = 0,       -- progresso do build
    buildQueue = {},      -- fullTypes pendentes (já filtrados obsoleto/hidden)
    building = false,     -- true enquanto o build roda em chunks
    CHUNK_SIZE = 60,      -- itens processados por frame
    derivedIndex = nil,   -- índice base -> { fullType derivados } (evolved recipes)
}

--- (Re)inicia o build do catálogo a partir do getAllItems().
--- @return table|nil entries se o build já estava pronto (cache), senão nil
function GridDevBrowser.startBuild()
    if GridDevBrowser.cache then return GridDevBrowser.cache end
    -- Já está construindo (outra janela aberta): não reinicia, retoma.
    if GridDevBrowser.building then return nil end

    local all = getAllItems()
    GridDevBrowser.source = {}
    local n = all:size()
    for i = 0, n - 1 do
        GridDevBrowser.source[i + 1] = all:get(i)
    end
    GridDevBrowser.sourceCount = n
    GridDevBrowser.buildIndex = 0
    GridDevBrowser.buildQueue = {}
    GridDevBrowser.working = {}
    GridDevBrowser.building = true
    return nil
end

--- Classifica um fullType (instancia + categoria + footprint). pcall-guardado.
--- @param fullType string
--- @param displayName string|nil
--- @param variantCount number|nil quantas IconsForTexture o item tem
--- @return table|nil entry
local function classifyFullType(fullType, displayName, variantCount)
    local ok, item = pcall(instanceItem, fullType)
    if not ok or not item or not instanceof(item, "InventoryItem") then
        return nil
    end
    local cok, cat = pcall(ItemCategory.getCategory, item)
    if not cok then cat = nil end
    local wok, w, h = pcall(ItemFootprint.getSize, item)
    if not wok then w, h = 1, 1 end
    return {
        fullType = fullType,
        displayName = displayName or fullType,
        category = cat or "MISC",
        w = w or 1,
        h = h or 1,
        variants = (variantCount and variantCount > 1) and variantCount or nil,
    }
end

--- Processa um chunk do build. Retorna progresso (0..1) e se terminou.
--- @return number progress, boolean done
function GridDevBrowser.advanceBuild()
    if not GridDevBrowser.building then return 1, true end

    -- Primeira chamada: enche a fila (fullType, displayName), pulando obsoleto/hidden.
    if GridDevBrowser.buildIndex == 0 then
        for _, s in ipairs(GridDevBrowser.source) do
            local fullName = s.getFullName and s:getFullName()
            if fullName then
                local obsolete = s.getObsolete and s:getObsolete()
                local hidden = s.isHidden and s:isHidden()
                if not obsolete and not hidden then
                    local displayName = (s.getDisplayName and s:getDisplayName()) or fullName
                    -- Conta variantes de sprite (IconsForTexture) pra informar
                    -- no browser quais itens têm múltiplas sprites.
                    local variantCount = 0
                    local ift = s.getIconsForTexture and s:getIconsForTexture()
                    if ift and ift.size then variantCount = ift:size() end
                    GridDevBrowser.buildQueue[#GridDevBrowser.buildQueue + 1] = { fullName, displayName, variantCount }
                end
            end
        end
    end

    local queue = GridDevBrowser.buildQueue
    local chunkEnd = math.min(#queue, GridDevBrowser.buildIndex + GridDevBrowser.CHUNK_SIZE)
    for i = GridDevBrowser.buildIndex + 1, chunkEnd do
        local q = queue[i]
        local entry = classifyFullType(q[1], q[2], q[3])
        if entry then
            GridDevBrowser.working[#GridDevBrowser.working + 1] = entry
        end
    end
    GridDevBrowser.buildIndex = chunkEnd

    if GridDevBrowser.buildIndex >= #queue then
        GridDevBrowser.cache = GridItemCatalog.sortEntries(GridDevBrowser.working)
        GridDevBrowser.working = {}
        GridDevBrowser.building = false
        GridDevBrowser.source = nil
        GridDevBrowser.buildQueue = {}
        return 1, true
    end

    local progress = (#queue > 0) and (GridDevBrowser.buildIndex / #queue) or 1
    return progress, false
end

--- Índice de DERIVADOS: mapa fullType base -> lista de fullTypes que nascem
--- dele via evolved recipes (ex: Base.Bowl vira Base.Salad, Base.FruitSalad...).
--- O jogo expõe o global getEvolvedRecipes() (ArrayList Java de EvolvedRecipe,
--- com getBaseItem()/getResultItem() retornando STRING fullType). Converte uma
--- vez (lazy) pra pares { base, result } e delega a lógica pura ao
--- GridItemCatalog.buildDerivedIndex (testável). Cacheado: build = 1 vez.
--- @return table índice base -> { fullType, ... }
function GridDevBrowser.getDerivedIndex()
    if GridDevBrowser.derivedIndex then return GridDevBrowser.derivedIndex end

    local pairs = {}
    local evos = getEvolvedRecipes and getEvolvedRecipes()
    if evos then
        local n = evos:size()
        for i = 0, n - 1 do
            local evo = evos:get(i)
            local base = evo.getBaseItem and evo:getBaseItem()
            local result = evo.getResultItem and evo:getResultItem()
            if base and result then
                pairs[#pairs + 1] = { base = base, result = result }
            end
        end
    end

    GridDevBrowser.derivedIndex = GridItemCatalog.buildDerivedIndex(pairs)
    return GridDevBrowser.derivedIndex
end

--- Abre o browser.
--- @param x number
--- @param y number
--- @param player number|IsoPlayer|nil
--- @param derivedOf string|nil fullType base: abre já filtrado pros DERIVADOS
---        (itens que nascem desse base via evolved recipes, ex: cumbuca -> saladas)
function GridDevBrowser.open(x, y, player, derivedOf)
    if not canUseDevTools() then return end
    local ui = GridDevBrowserUI:new(x, y, player, derivedOf)
    ui:initialise()
    ui:addToUIManager()
    -- Z-order: o browser abre por cima do DevTool que o chamou (o clique no
    -- botão re-ergue a janela do DevTool depois do addToUIManager).
    ui:bringToTop()
end

--- GridDevBrowserUI: painel do browser (ISPanel:derive, mesmo padrão do DevTool).
GridDevBrowserUI = ISPanel:derive("GridDevBrowserUI")

function GridDevBrowserUI:new(x, y, player, derivedOf)
    local o = ISPanel:new(x, y, 520, 640)
    setmetatable(o, self)
    self.__index = self

    o.player = player
    o.backgroundColor = { r = 0, g = 0, b = 0, a = 0.92 }
    o.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }

    o.allEntries = GridDevBrowser.startBuild() or GridDevBrowser.working
    o.synced = not GridDevBrowser.building   -- já tem o catálogo pronto?
    o.query = ""
    o.category = nil        -- categoria selecionada (nil = todas)
    o.filtered = {}
    o.pageItems = {}
    o.page = 1
    o.pageCount = 1
    o.pageSize = 20
    o.progress = GridDevBrowser.building and 0 or 1
    -- Modo DERIVADOS: derivedOf = fullType base; filtro inicial = lista de
    -- fullTypes que nascem dele (evolved recipes). nil = modo normal.
    o.derivedOf = derivedOf or nil
    o.derivedFilter = nil   -- lista de fullTypes derivados (cresce no build)
    if o.derivedOf then
        o.derivedFilter = GridDevBrowser.getDerivedIndex()[o.derivedOf] or {}
    end

    -- Clamp: janela dentro da tela.
    local sw = getCore() and getCore():getScreenWidth() or 1280
    local sh = getCore() and getCore():getScreenHeight() or 720
    if x + o.width > sw then x = math.max(0, sw - o.width) end
    if x < 0 then x = 0 end
    if y + o.height > sh then y = math.max(0, sh - o.height) end
    if y < 0 then y = 0 end
    o:setX(x)
    o:setY(y)

    return o
end

local BROWSER_TITLE_BAR = 25
local BROWSER_ROW_H = 22
local BROWSER_LIST_TOP = 92          -- começo da lista (abaixo do combo)
local BROWSER_LIST_BOTTOM_OFFSET = 52 -- altura reservada pra paginação/footer

function GridDevBrowserUI:listBottom()
    return self:getHeight() - BROWSER_LIST_BOTTOM_OFFSET
end

function GridDevBrowserUI:initialise()
    ISPanel.initialise(self)

    -- Close Button
    self.btnClose = ISButton:new(self.width - 25, 5, 20, 20, "X", self, self.close)
    self.btnClose:initialise()
    self:addChild(self.btnClose)

    -- Busca
    self:addChild(ISLabel:new(10, 30, 20, "Buscar:", 1, 1, 1, 1, UIFont.Small, true))
    self.entrySearch = ISTextEntryBox:new("", 70, 28, self.width - 80, 22)
    self.entrySearch.font = UIFont.Small
    self.entrySearch:initialise()
    self.entrySearch:instantiate()
    self.entrySearch.target = self
    self.entrySearch.onTextChange = function(box)
        box.target:onSearchChanged()
    end
    self:addChild(self.entrySearch)

    -- Categoria (escondida no modo DERIVADOS — o filtro de fullTypes manda)
    self:addChild(ISLabel:new(10, 58, 20, "Categoria:", 1, 1, 1, 1, UIFont.Small, true))
    self.comboCategory = ISComboBox:new(70, 56, self.width - 80, 22, self, function(target, combo)
        target:onCategoryChanged()
    end)
    self.comboCategory:initialise()
    self.comboCategory:instantiate()
    self.comboCategory:addOption("Todas")
    for _, cat in ipairs(GridItemCatalog.categoryOrder) do
        if ItemCategory.colors[cat] then
            self.comboCategory:addOptionWithData(cat, cat)
        end
    end
    self:addChild(self.comboCategory)

    -- Modo DERIVADOS: botão que volta ao catálogo completo (limpa o derivedOf).
    if self.derivedOf then
        self.comboCategory:setVisible(false)
        self.btnAll = ISButton:new(self.width - 150, 56, 140, 22, "Ver todos", self, function(self)
            self.derivedOf = nil
            self.derivedFilter = nil
            self.comboCategory:setVisible(true)
            self:applyFilter()
        end)
        self.btnAll:initialise()
        self:addChild(self.btnAll)
    end

    -- Paginação
    self.btnPrev = ISButton:new(10, self:listBottom() + 12, 60, 22, "< Prev", self, function(self)
        self.page = math.max(1, self.page - 1)
        self:refreshPage()
    end)
    self.btnPrev:initialise()
    self:addChild(self.btnPrev)

    self.btnNext = ISButton:new(self.width - 70, self:listBottom() + 12, 60, 22, "Next >", self, function(self)
        self.page = math.min(self.pageCount, self.page + 1)
        self:refreshPage()
    end)
    self.btnNext:initialise()
    self:addChild(self.btnNext)

    if GridDevBrowser.building then
        self:refreshPage()
    else
        self:applyFilter()
    end
end

--- Re-aplica o filtro (busca + categoria) e volta pra página 1.
function GridDevBrowserUI:applyFilter()
    local source = self.allEntries
    -- Modo DERIVADOS: mostra só os fullTypes que nascem do base (o query/categoria
    -- continuam valendo DENTRO desse subconjunto, pra refinar).
    if self.derivedOf then
        local want = {}
        local wantSet = {}
        for _, t in ipairs(self.derivedFilter or {}) do
            wantSet[t] = true
        end
        for _, e in ipairs(self.allEntries) do
            if wantSet[e.fullType] then
                want[#want + 1] = e
            end
        end
        source = want
    end
    self.filtered = GridItemCatalog.filter(source, self.query, self.category)
    self.page = 1
    self:refreshPage()
end

--- Recalcula a página atual (depois do filtro ou navegação).
function GridDevBrowserUI:refreshPage()
    self.pageItems, self.pageCount = GridItemCatalog.paginate(self.filtered, self.page, self.pageSize)
end

function GridDevBrowserUI:onSearchChanged()
    local text = self.entrySearch:getInternalText() or ""
    if text == self.query then return end
    self.query = text
    self:applyFilter()
end

function GridDevBrowserUI:onCategoryChanged()
    local data = self.comboCategory:getOptionData(self.comboCategory.selected)
    self.category = data or nil
    self:applyFilter()
end

function GridDevBrowserUI:update()
    if GridDevBrowser.building then
        local done
        self.progress, done = GridDevBrowser.advanceBuild()
        if done then
            self.allEntries = GridDevBrowser.cache
            self:applyFilter()
            self.synced = true
        end
    elseif not self.synced and GridDevBrowser.cache then
        -- Janela aberta no meio do build: working é o mesmo objeto do cache
        -- (sort in-place), mas filtered/página ainda não foram calculados.
        self.allEntries = GridDevBrowser.cache
        self:applyFilter()
        self.synced = true
    end
    ISPanel.update(self)
end

function GridDevBrowserUI:prerender()
    ISPanel.prerender(self)
    self:drawTextCentre("Grid Item Browser", self.width / 2, 10, 1, 1, 1, 1, UIFont.Small)

    -- Progresso do build
    if GridDevBrowser.building then
        local pct = math.floor(self.progress * 100)
        self:drawText("Building catalog... " .. tostring(pct) .. "%", 10, BROWSER_LIST_TOP, 0.8, 0.8, 0.5, 1, UIFont.Small)
    end

    -- Modo DERIVADOS: mostra de quem esses itens nascem (cumbuca -> saladas, etc)
    -- na linha da categoria (que fica escondida nesse modo), à esquerda do botão
    -- "Ver todos".
    if self.derivedOf then
        local n = self.derivedFilter and #self.derivedFilter or 0
        self:drawText("Derivados de " .. self.derivedOf .. " (" .. tostring(n) .. ")", 10, 62, 0.7, 0.9, 1, 1, UIFont.Small)
    end

    -- Linhas da página atual
    local y = BROWSER_LIST_TOP + (GridDevBrowser.building and 18 or 0)
    local tm = getTextManager()
    for _, e in ipairs(self.pageItems) do
        local catColor = ItemCategory.colors[e.category] or ItemCategory.colors[ItemCategory.MISC]

        -- swatch da categoria
        self:drawRect(10, y + 4, 14, 14, 0.9, catColor.r, catColor.g, catColor.b)

        -- fullType (truncado pra caber; termina antes da coluna displayName)
        local name = e.fullType
        local maxW = 165
        local nameWx = tm:MeasureStringX(UIFont.Small, name)
        if nameWx > maxW then
            local ratio = maxW / math.max(1, nameWx)
            name = name:sub(1, math.max(6, math.floor(#name * ratio))) .. "..."
            nameWx = tm:MeasureStringX(UIFont.Small, name)
        end
        self:drawText(name, 30, y + 3, 1, 1, 1, 1, UIFont.Small)

        -- Indicador de variantes de sprite (+N) quando IconsForTexture > 1
        if e.variants then
            local varStr = "+" .. tostring(e.variants - 1)
            self:drawText(varStr, 30 + nameWx + 4, y + 3, 0.5, 0.7, 0.5, 0.8, UIFont.Small)
        end

        -- displayName (cinza) ao lado, truncado
        local disp = e.displayName and e.displayName ~= e.fullType and e.displayName or nil
        if disp then
            local dmaxW = 210
            if tm:MeasureStringX(UIFont.Small, disp) > dmaxW then
                disp = disp:sub(1, 20) .. "..."
            end
            self:drawText(disp, 200, y + 3, 0.6, 0.6, 0.6, 1, UIFont.Small)
        end

        -- WxH atual + marcador de override
        local override = GridDevTool.Overrides and GridDevTool.Overrides[e.fullType]
        local marker = (override and override.w and override.h) and "*" or ""
        local sizeStr = marker .. tostring(e.w) .. "x" .. tostring(e.h)
        local szW = tm:MeasureStringX(UIFont.Small, sizeStr)
        self:drawText(sizeStr, self.width - 20 - szW, y + 3, 0.8, 0.95, 0.7, 1, UIFont.Small)

        y = y + BROWSER_ROW_H
    end

    -- Rodapé: total (filtrado no modo derivados) + página
    local total = self.derivedOf and #self.filtered or #self.allEntries
    self:drawText("Itens: " .. tostring(total) .. " | Pagina " .. tostring(self.page)
        .. "/" .. tostring(self.pageCount), 10, self:listBottom() + 16, 0.8, 0.8, 0.8, 1, UIFont.Small)
end

function GridDevBrowserUI:onMouseDown(x, y)
    if y <= BROWSER_TITLE_BAR and x <= self:getWidth() - 24 then
        self.dragging = true
        self.dragStartX = x
        self.dragStartY = y
        self:setCapture(true)
        return true
    end

    -- Clique numa linha da lista → abre o GridDevTool pra esse item.
    if not GridDevBrowser.building then
        local listTop = BROWSER_LIST_TOP
        local listBottom = self:listBottom()
        if y >= listTop and y < listBottom then
            local idx = math.floor((y - listTop) / BROWSER_ROW_H) + 1
            local entry = self.pageItems[idx]
            if entry then
                self:openItem(entry)
                return true
            end
        end
    end

    return ISPanel.onMouseDown(self, x, y)
end

function GridDevBrowserUI:onMouseMove(dx, dy)
    if self.dragging then
        local mx = self:getMouseX()
        local my = self:getMouseY()
        local nx = self:getX() + (mx - self.dragStartX)
        local ny = self:getY() + (my - self.dragStartY)
        self:clampAndSet(nx, ny)
        return true
    end
    return ISPanel.onMouseMove(self, dx, dy)
end

function GridDevBrowserUI:onMouseMoveOutside(dx, dy)
    if self.dragging then
        local mx = getMouseX()
        local my = getMouseY()
        local nx = self:getX() + (mx - (self:getX() + self.dragStartX))
        local ny = self:getY() + (my - (self:getY() + self.dragStartY))
        self:clampAndSet(nx, ny)
        return true
    end
    return ISPanel.onMouseMoveOutside and ISPanel.onMouseMoveOutside(self, dx, dy)
end

function GridDevBrowserUI:onMouseUp(x, y)
    if self.dragging then
        self.dragging = false
        self:setCapture(false)
        return true
    end
    return ISPanel.onMouseUp(self, x, y)
end

--- Posiciona a janela garantindo que fique dentro da tela.
function GridDevBrowserUI:clampAndSet(nx, ny)
    local sw = getCore() and getCore():getScreenWidth() or 1280
    local sh = getCore() and getCore():getScreenHeight() or 720
    if nx + self:getWidth() > sw then nx = sw - self:getWidth() end
    if nx < 0 then nx = 0 end
    if ny + self:getHeight() > sh then ny = sh - self:getHeight() end
    if ny < 0 then ny = 0 end
    self:setX(nx)
    self:setY(ny)
end

--- Abre o GridDevTool pra um item do catálogo (instancia o item de verdade).
function GridDevBrowserUI:openItem(entry)
    local ok, item = pcall(instanceItem, entry.fullType)
    if not ok or not item or not instanceof(item, "InventoryItem") then return end
    local ui = GridDevToolUI:new(getMouseX() + 20, getMouseY(), item)
    ui.player = self.player
    ui:initialise()
    ui:addToUIManager()
    -- Z-order: abre por cima do browser que o chamou (mesmo fix do browser).
    ui:bringToTop()
end

return GridDevBrowser
