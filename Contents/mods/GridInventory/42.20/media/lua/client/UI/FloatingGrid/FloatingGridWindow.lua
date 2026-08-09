--- FloatingGridWindow.lua
--- Janela flutuante para gerenciar o conteúdo de uma BOLSA sem equipá-la.
--- Abre no duplo clique do item-bolsa (footprint) dentro de um grid (inventário
--- ou loot). Suporta drag&drop total com as grids principais (GridRender é um
--- child genérico). Comportamento:
---   - "P" (pin) → a janela NÃO fecha junto com o inventário;
---   - "X" → fecha e destrói;
---   - fechar o inventário fecha janelas não-pinadas.
--- NOTA: não dá require em GridRender como dependência obrigatória do módulo —
--- GridRender chama o global GridInventory_openFloatingBag (sem ciclo de require).

require "ISUI/ISPanel"
require "ISUI/ISButton"
local GridContainer = require("DataModel/GridContainer")
local GridRender = require("UI/GridRender/GridRender")

FloatingGridWindow = ISPanel:derive("FloatingGridWindow")

local TITLE_H = 26
local PAD = 10
local BTN_H = 22
local BTN_W = 24
local BTN_Y = (TITLE_H - BTN_H) / 2

-- Registry:
--   GridInventory_FloatingGrid[playerNum] = LISTA de janelas de bolsa (várias)
--   GridInventory_StackPicker[playerNum]  = UMA janela de stack picker
GridInventory_FloatingGrid = GridInventory_FloatingGrid or {}
GridInventory_StackPicker = GridInventory_StackPicker or {}

local function getBagWindowList(playerNum)
    local list = GridInventory_FloatingGrid[playerNum]
    if not list then
        list = {}
        GridInventory_FloatingGrid[playerNum] = list
    end
    return list
end

--- Acha uma janela de bolsa já aberta para o MESMO container (pra não duplicar).
local function findBagWindowByInventory(playerNum, inventory)
    if not inventory then return nil end
    local list = GridInventory_FloatingGrid[playerNum]
    if list then
        for _, w in ipairs(list) do
            if w.bagInventory == inventory then return w end
        end
    end
    return nil
end

--- Abre (ou traz pra frente) o floating grid de uma bolsa. PERMITE VÁRIAS
--- janelas simultâneas (uma por container): abre um float do chão e outro de
--- uma bolsa do inventário e arrasta direto entre eles.
GridInventory_openFloatingBag = function(playerNum, bagItem)
    if not bagItem or not bagItem.getInventory then return end
    local inv = bagItem:getInventory()
    if not inv then return end

    local existing = findBagWindowByInventory(playerNum, inv)
    if existing then
        existing:bringToTop()
        return
    end

    local win = FloatingGridWindow:new(0, 0, 100, 100, playerNum)
    win:initialise()
    win:addToUIManager()
    win:setVisible(false)
    table.insert(getBagWindowList(playerNum), win)
    win:openBag(bagItem)
end

--- Abre o STACK PICKER (modo lista) na janela DEDICADA e única do player.
--- Ela SEMPRE se reposiciona no ponto onde foi aberto (ver openStack).
GridInventory_openStackPicker = function(playerNum, sourceGrid, stackLeaderId)
    local win = GridInventory_StackPicker[playerNum]
    if not win then
        win = FloatingGridWindow:new(0, 0, 240, 120, playerNum)
        win:initialise()
        win:addToUIManager()
        win:setVisible(false)
        GridInventory_StackPicker[playerNum] = win
    end
    win:openStack(sourceGrid, stackLeaderId)
end

--- Fecha janelas flutuantes NÃO pinadas (chamado quando o inventário fecha).
--- Fecha TODAS as de bolsa e também o stack picker (se não pinados).
GridInventory_closeFloatingBags = function(playerNum)
    local list = GridInventory_FloatingGrid[playerNum]
    if list then
        for i = #list, 1, -1 do
            local w = list[i]
            if not w.pinned then
                w:close()
            end
        end
    end
    local sp = GridInventory_StackPicker[playerNum]
    if sp and not sp.pinned then
        sp:close()
    end
end

--- Traz TODAS as janelas flutuantes (bolsas + stack picker) do player pra frente.
--- Chamado pelos hooks de ISInventoryPage/PaperDoll quando um painel sobe
--- (método do InvTetris — sem bringToTop por frame, sem flicker).
GridInventory_raiseFloating = function(playerNum)
    local list = GridInventory_FloatingGrid[playerNum]
    if list then
        for _, w in ipairs(list) do
            if w:getIsVisible() then
                w:bringToTop()
            end
        end
    end
    local sp = GridInventory_StackPicker[playerNum]
    if sp and sp:getIsVisible() then
        sp:bringToTop()
    end
end

function FloatingGridWindow:new(x, y, width, height, playerNum)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.playerNum = playerNum or 0
    o.pinned = false
    o.isStackPicker = false
    o.bagInventory = nil
    return o
end

function FloatingGridWindow:initialise()
    ISPanel.initialise(self)

    self.title = "Bag"
    self.titleH = TITLE_H
    self.bagItem = nil
    self.gridUi = nil
    self.stackMode = nil
    self.stackRows = nil
    self.selected = {}
    self.scrollY = 0
    self.scrollDrag = nil
    self.hoverRow = nil
    self.toolRender = nil
    self.lastClickId = nil
    self.lastClickTime = nil
    self.lastSelectedIndex = nil
    self.listH = 120
    self.lastBagHash = ""
    self.lastBagHashCheck = 0

    self.closeBtn = ISButton:new(self.width - BTN_W - 2, BTN_Y, BTN_W, BTN_H, "X", self,
        function(target) target:close() end)
    self.closeBtn:initialise()
    self.closeBtn.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    self.closeBtn.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.closeBtn.backgroundColorMouseOver = { r = 1, g = 1, b = 1, a = 0.25 }
    self.closeBtn:setTooltip(getText("IGUI_FloatingGrid_Close") or "Close")
    self:addChild(self.closeBtn)

    self.pinBtn = ISButton:new(self.width - BTN_W * 2 - 4, BTN_Y, BTN_W, BTN_H, "P", self,
        function(target)
            target.pinned = not target.pinned
            target.pinBtn:setTooltip(getText(target.pinned and "IGUI_FloatingGrid_Unpin" or "IGUI_FloatingGrid_Pin"))
        end)
    self.pinBtn:initialise()
    self.pinBtn.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    self.pinBtn.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    self.pinBtn.backgroundColorMouseOver = { r = 1, g = 1, b = 1, a = 0.25 }
    self.pinBtn:setTooltip(getText("IGUI_FloatingGrid_Pin") or "Pin")
    self:addChild(self.pinBtn)

    -- Botão "Pegar (N)" (só no modo stack picker, abaixo da lista)
    self.takeBtn = ISButton:new(PAD, TITLE_H + 4, self.width - PAD * 2, 24, "", self,
        function(target) target:takeSelected() end)
    self.takeBtn:initialise()
    self.takeBtn:setVisible(false)
    self.takeBtn.backgroundColor = { r = 0.15, g = 0.4, b = 0.15, a = 0.8 }
    self.takeBtn.backgroundColorMouseOver = { r = 0.25, g = 0.6, b = 0.25, a = 0.9 }
    self.takeBtn.borderColor = { r = 0.3, g = 0.8, b = 0.3, a = 1 }
    self:addChild(self.takeBtn)
end

--- Alvo: abre/redireciona a janela para o conteúdo de uma bolsa.
function FloatingGridWindow:openBag(bagItem)
    if not bagItem or not bagItem.getInventory then return end
    local inv = bagItem:getInventory()
    if not inv then return end

    self.isStackPicker = false
    self.bagItem = bagItem
    self.bagInventory = inv
    self.stackMode = nil
    self.stackRows = nil
    self.selected = {}
    if self.takeBtn then self.takeBtn:setVisible(false) end
    self.title = bagItem.getName and bagItem:getName() or "Bag"

    if self.gridUi then
        self:removeChild(self.gridUi)
        self.gridUi:destroy()
        self.gridUi = nil
    end

    local gc = GridContainer.getOrCreate(inv, self.playerNum)
    gc:refresh()
    local gridCore = gc.grids[1]

    -- noHeader=true: a janela tem título próprio; o GridRender fica só com a malha.
    self.gridUi = GridRender:new(PAD, TITLE_H + PAD, gridCore, self.playerNum, inv, 1,
        bagItem, bagItem.getTexture and bagItem:getTexture(), true)
    self.gridUi:initialise()
    self:addChild(self.gridUi)

    -- Dimensiona a janela ao conteúdo da bolsa
    local w = self.gridUi.width + PAD * 2
    local h = TITLE_H + self.gridUi.height + PAD * 2
    self:setWidth(w)
    self:setHeight(h)
    self.closeBtn:setX(self.width - BTN_W - 2)
    self.pinBtn:setX(self.width - BTN_W * 2 - 4)

    -- Primeira abertura: posiciona ONDE O MOUSE ESTÁ (com um pequeno offset pra
    -- não esconder o cursor), limitado às bordas da tela. A posição seguinte
    -- (re-abrir outra bolsa) mantém onde o jogador deixou a janela.
    if not self._positionedOnce then
        self._positionedOnce = true
        local core = getCore()
        local mx = getMouseX()
        local my = getMouseY()
        local maxX = math.max(10, core:getScreenWidth() - self.width - 10)
        local maxY = math.max(10, core:getScreenHeight() - self.height - 10)
        self:setX(math.min(math.max(10, mx + 20), maxX))
        self:setY(math.min(math.max(10, my + 20), maxY))
    end

    self:setVisible(true)
    self:bringToTop()
    self.lastBagHash = ""
end

function FloatingGridWindow:close()
    self:destroyStackTooltip()
    if self.gridUi then
        self:removeChild(self.gridUi)
        self.gridUi:destroy()
        self.gridUi = nil
    end
    self.bagItem = nil
    self.bagInventory = nil
    self.stackMode = nil
    self.stackRows = nil
    self.selected = {}
    self.scrollDrag = nil
    self:setVisible(false)
    if self.removeFromUIManager then self:removeFromUIManager() end

    -- Remove do registry correto (picker único OU lista de bolsas)
    if self.isStackPicker then
        GridInventory_StackPicker[self.playerNum] = nil
    else
        local list = GridInventory_FloatingGrid[self.playerNum]
        if list then
            for i = #list, 1, -1 do
                if list[i] == self then
                    table.remove(list, i)
                    break
                end
            end
            if #list == 0 then
                GridInventory_FloatingGrid[self.playerNum] = nil
            end
        end
    end
end

--- Altura de cada linha no modo stack picker.
local ROW_H = 30

--- Formata peso com até 2 casas (mesmo estilo do header dos grids).
local function formatWeight(value)
    local rounded = math.floor(value * 100 + 0.5) / 100
    if rounded == math.floor(rounded) then
        return string.format("%d", rounded)
    end
    local str = string.format("%.2f", rounded)
    str = str:gsub("0+$", ""):gsub("%.$", "")
    return str
end

--- Info de exibição de um item na lista do picker: (count, condition% or nil).
local function stackRowInfo(item)
    local count = item.getCount and item:getCount() or 1
    local cond = nil
    if item.getCondition and item.getConditionMax then
        local maxC = item:getConditionMax()
        if maxC and maxC > 0 then
            cond = math.floor((item:getCondition() or 0) / maxC * 100)
        end
    end
    return count, cond
end

--- Atualiza o grid da bolsa quando o conteúdo muda (throttle 300ms) e fecha
--- automaticamente se a bolsa saiu de cena (não tem mais container).
--- Z-INDEX: NÃO fazemos bringToTop por frame (causa flicker). O z-order é
--- mantido pelos hooks de ISInventoryPage/PaperDoll (método do InvTetris):
--- quando um painel é trazido pra frente, o floating é re-sobido junto.
function FloatingGridWindow:update()
    ISPanel.update(self)

    -- Tooltip do item sob o mouse no stack picker (todo frame, antes do throttle)
    self:updateStackTooltip()

    local now = getTimestampMs()
    if now - self.lastBagHashCheck < 300 then return end
    self.lastBagHashCheck = now

    -- Modo stack picker: fecha quando a pilha sumir/sobrar 1 item; mantém a
    -- lista sincronizada (o takeStackMember move um membro pra fora).
    if self.stackMode then
        local src = self.stackMode.sourceGrid
        local leader = self.stackMode.leaderId
        if not src or not src.gridCore or not src.gridCore.items[leader] then
            self:close()
            return
        end
        if src.gridCore:getStackSize(leader) <= 1 then
            self:close()
            return
        end
        self:refreshStackList()
        return
    end

    if not self.bagItem then return end
    local parent = self.bagItem.getContainer and self.bagItem:getContainer()
    if not parent then
        self:close()
        return
    end

    local inv = self.bagItem:getInventory()
    if not inv then return end

    local items = inv:getItems()
    local hash = ""
    for i = 0, items:size() - 1 do
        hash = hash .. tostring(items:get(i):getID()) .. "_"
    end
    if hash ~= self.lastBagHash then
        self.lastBagHash = hash
        local gc = GridContainer.getOrCreate(inv, self.playerNum)
        gc:refresh()
    end
end

--- Tooltip do item sob o mouse no stack picker (mesmo padrão do GridRender:
--- ISToolTipInv com o item, seguindo o cursor, limitado às bordas da tela).
function FloatingGridWindow:updateStackTooltip()
    if not self.isStackPicker or not self.stackRows then
        self:destroyStackTooltip()
        return
    end

    local hoveredItem = nil
    if self:isMouseOver() and not ISMouseDrag.dragging and not GridInventory_GlobalDrag then
        local my = self:getMouseY()
        if my >= self.titleH and my <= self.titleH + self.listH then
            local idx = math.floor((my - self.titleH - 2 + (self.scrollY or 0)) / ROW_H) + 1
            if idx >= 1 and idx <= #self.stackRows then
                hoveredItem = self.stackRows[idx].item
            end
        end
    end

    if hoveredItem then
        if not self.toolRender then
            self.toolRender = ISToolTipInv:new(hoveredItem)
            self.toolRender:initialise()
            self.toolRender:addToUIManager()
            self.toolRender:setOwner(self)
            self.toolRender:setCharacter(getSpecificPlayer(self.playerNum))
        end
        self.toolRender:setItem(hoveredItem)
        self.toolRender:setVisible(true)
        self.toolRender:bringToTop()

        local gmx = getMouseX()
        local gmy = getMouseY()
        local tx = gmx + 15
        local ty = gmy + 15

        if self.toolRender.width and (tx + self.toolRender.width > getCore():getScreenWidth()) then
            tx = gmx - self.toolRender.width - 15
        end
        if self.toolRender.height and (ty + self.toolRender.height > getCore():getScreenHeight()) then
            ty = gmy - self.toolRender.height - 15
        end

        self.toolRender:setX(tx)
        self.toolRender:setY(ty)
    else
        self:destroyStackTooltip()
    end
end

function FloatingGridWindow:destroyStackTooltip()
    if self.toolRender then
        self.toolRender:removeFromUIManager()
        self.toolRender:setVisible(false)
        self.toolRender = nil
    end
end

--- Altura máxima da lista do stack picker (evita estourar a tela com pilhas
--- gigantes) + margem mínima em relação à altura da tela.
local MAX_LIST_H = 420
local SCREEN_MARGIN = 200
--- Altura da barra do botão "Pegar (N)" abaixo da lista.
local BTN_BAR_H = 30

--- Reconstrói a lista de linhas do stack picker (melhor condição primeiro).
--- A altura da janela é limitada e o resto vira scroll (listH + scrollY).
function FloatingGridWindow:refreshStackList()
    local src = self.stackMode.sourceGrid
    local leader = self.stackMode.leaderId
    local members = src.gridCore:getStackMembers(leader)
    local rows = {}
    for _, mId in ipairs(members) do
        local d = src.gridCore.items[mId]
        if d and d.itemObj then
            local count, cond = stackRowInfo(d.itemObj)
            table.insert(rows, { id = mId, item = d.itemObj, count = count, cond = cond })
        end
    end
    table.sort(rows, function(a, b)
        local ac = a.cond or -1
        local bc = b.cond or -1
        if ac ~= bc then return ac > bc end
        return a.count > b.count
    end)
    self.stackRows = rows

    -- Altura da janela limitada (total das linhas OU o teto, o que for menor)
    local totalH = #rows * ROW_H
    local core = getCore()
    local screenH = core and core:getScreenHeight() or 1080
    local maxH = math.min(MAX_LIST_H, math.max(100, screenH - SCREEN_MARGIN))
    self.listH = math.min(totalH, maxH)
    if self.listH < 1 then self.listH = 1 end

    local h = TITLE_H + self.listH + BTN_BAR_H + PAD
    if self:getHeight() ~= h then
        self:setHeight(h)
    end

    -- Botão "Pegar (N)" abaixo da lista
    if self.takeBtn then
        self.takeBtn:setX(PAD)
        self.takeBtn:setY(TITLE_H + self.listH + 4)
        self.takeBtn:setWidth(self.width - PAD * 2)
    end

    -- Clamp do scroll à faixa válida
    local maxScroll = math.max(0, totalH - self.listH)
    if self.scrollY > maxScroll then self.scrollY = maxScroll end
    if self.scrollY < 0 then self.scrollY = 0 end

    self:updateTakeButton()
end

--- Atualiza o rótulo do botão "Pegar (N)" conforme a seleção.
function FloatingGridWindow:updateTakeButton()
    if not self.takeBtn then return end
    local n = 0
    if self.selected then
        for _ in pairs(self.selected) do n = n + 1 end
    end
    local label = (getText("IGUI_StackPicker_Take") or "Take") .. " (" .. tostring(n) .. ")"
    if self.takeBtn.title ~= label then
        self.takeBtn:setTitle(label)
    end
    self.takeBtn:setVisible(n > 0)
end

--- Info geométrica da scrollbar (track/thumb/maxScroll) para hit-test e arraste.
function FloatingGridWindow:scrollbarInfo()
    local totalH = (self.stackRows and #self.stackRows or 0) * ROW_H
    local maxScroll = math.max(0, totalH - self.listH)
    local trackTop = self.titleH + 4
    local trackH = math.max(1, self.listH - 8)
    local thumbH = math.max(14, trackH * (self.listH / math.max(1, totalH)))
    local thumbY = trackTop + (trackH - thumbH) * (maxScroll > 0 and (self.scrollY / maxScroll) or 0)
    return { trackTop = trackTop, trackH = trackH, thumbH = thumbH, thumbY = thumbY, maxScroll = maxScroll }
end

--- True se o ponto (x, y) local está sobre a área da scrollbar.
function FloatingGridWindow:isOnScrollbar(x, y)
    if not self.stackMode then return false end
    local info = self:scrollbarInfo()
    local sx = self.width - PAD - 8
    return x >= sx and x <= sx + 6 and y >= info.trackTop and y <= info.trackTop + info.trackH
end

--- Inicia o arraste da scrollbar (no thumb ou pulo no track).
function FloatingGridWindow:startScrollDrag(y)
    local info = self:scrollbarInfo()
    if y >= info.thumbY and y <= info.thumbY + info.thumbH then
        self.scrollDrag = { grab = y - info.thumbY }
    else
        -- clique no track: centraliza o thumb no cursor
        self.scrollDrag = { grab = info.thumbH / 2 }
        self:updateScrollFromMouse(y)
    end
end

--- Atualiza scrollY a partir da posição do mouse durante o arraste.
function FloatingGridWindow:updateScrollFromMouse(y)
    local info = self:scrollbarInfo()
    if info.maxScroll <= 0 then return end
    local avail = info.trackH - info.thumbH
    if avail <= 0 then return end
    local t = (y - info.trackTop - self.scrollDrag.grab) / avail
    self.scrollY = math.max(0, math.min(info.maxScroll, t * info.maxScroll))
end

--- Scroll da lista (roda do mouse sobre a janela, só no modo stack picker).
--- PZ: del > 0 = rolar pra BAIXO (convenção do ISScrollBar: seta para baixo
--- chama onMouseWheel(1)). scrollY cresce ao descer → conteúdo sobe.
function FloatingGridWindow:onMouseWheel(del)
    if not self.stackMode then return false end
    local totalH = (self.stackRows and #self.stackRows or 0) * ROW_H
    local maxScroll = math.max(0, totalH - self.listH)
    if maxScroll <= 0 then return false end
    self.scrollY = math.max(0, math.min(maxScroll, self.scrollY + del * 30))
    return true
end

--- Modo STACK PICKER: mostra cada item da pilha pra escolher o melhor.
--- Este modo vive numa janela DEDICADA e única por player (GridInventory_StackPicker),
--- que SEMPRE se move para onde foi aberto (o mouse), sem travar na posição.
function FloatingGridWindow:openStack(sourceGrid, stackLeaderId)
    if not sourceGrid or not sourceGrid.gridCore then return end
    if not sourceGrid.gridCore.items[stackLeaderId] then return end

    -- Sai do modo bolsa
    self.isStackPicker = true
    self.bagItem = nil
    self.bagInventory = nil
    self.stackMode = { sourceGrid = sourceGrid, leaderId = stackLeaderId }
    self.stackRows = nil
    self.selected = {}
    self.scrollY = 0
    self.scrollDrag = nil
    self.lastClickId = nil
    self.lastClickTime = nil
    self.lastSelectedIndex = nil
    if self.gridUi then
        self:removeChild(self.gridUi)
        self.gridUi:destroy()
        self.gridUi = nil
    end

    local itemData = sourceGrid.gridCore.items[stackLeaderId]
    local item = itemData and itemData.itemObj
    local name = item and (item:getName() or item:getDisplayName() or "Stack") or "Stack"
    local n = sourceGrid.gridCore:getStackSize(stackLeaderId)
    self.title = name .. " (" .. tostring(n) .. ")"

    self:setWidth(240)
    self:refreshStackList()

    -- SEMPRE reposiciona ONDE O MOUSE ESTÁ (offset +20 pra não cobrir o cursor),
    -- limitado às bordas da tela. O picker é "descartável": reabre no ponto do clique.
    local core = getCore()
    local mx = getMouseX()
    local my = getMouseY()
    local maxX = math.max(10, core:getScreenWidth() - self.width - 10)
    local maxY = math.max(10, core:getScreenHeight() - self.height - 10)
    self:setX(math.min(math.max(10, mx + 20), maxX))
    self:setY(math.min(math.max(10, my + 20), maxY))
    self.closeBtn:setX(self.width - BTN_W - 2)
    self.pinBtn:setX(self.width - BTN_W * 2 - 4)

    self:setVisible(true)
    self:bringToTop()
    self.lastBagHash = ""
end

--- Desenha a lista de itens do stack picker, recortada (stencil) na área
--- visível, com hover/selection e scrollbar quando a pilha é maior que a janela.
function FloatingGridWindow:renderStackList()
    local rows = self.stackRows
    if not rows then return end
    local scrollY = self.scrollY or 0
    local totalH = #rows * ROW_H
    local maxScroll = math.max(0, totalH - self.listH)

    -- Linha sob o mouse (hover) — calculada por frame, some quando o mouse sai
    local hoverIndex = nil
    if self:isMouseOver() then
        local my = self:getMouseY()
        if my >= self.titleH and my <= self.titleH + self.listH then
            hoverIndex = math.floor((my - self.titleH - 2 + scrollY) / ROW_H) + 1
            if hoverIndex > #rows then hoverIndex = nil end
        end
    end

    -- Recorta a lista à área visível (abaixo da barra de título)
    self:setStencilRect(PAD, self.titleH, self.width - PAD * 2, self.listH)

    local topY = self.titleH + 2 - scrollY
    local pad = 4
    local rowW = self.width - pad * 2 - (maxScroll > 0 and 10 or 0)
    for i, row in ipairs(rows) do
        local ry = topY + (i - 1) * ROW_H
        -- Pula linhas fora da área visível (otimização)
        if ry + ROW_H > self.titleH and ry < self.titleH + self.listH then
            -- Fundo: seleção > hover > zebra
            local isSel = self.selected and self.selected[row.id]
            if isSel then
                self:drawRect(pad, ry, rowW, ROW_H - 2, 0.35, 0.2, 0.6, 0.3)
                self:drawRectBorder(pad, ry, rowW, ROW_H - 2, 0.9, 0.5, 0.9, 0.6)
            elseif i == hoverIndex then
                self:drawRect(pad, ry, rowW, ROW_H - 2, 0.25, 0.45, 0.45, 0.45)
            elseif i % 2 == 0 then
                self:drawRect(pad, ry, rowW, ROW_H - 2, 0.15, 0.2, 0.2, 0.2)
            end
            -- Ícone — usa o MESMO renderer do grid principal (color mask, fluid
            -- mask e tint são aplicados). drawTextureScaledAspect só desenharia
            -- a textura base, sem líquido/cor.
            GridRender.drawItemIconRotated(self, row.item, pad + 2, ry + 3, 24, 24, false, 1, 1, 1, 1)
            -- Nome
            local name = row.item:getName() or row.item:getDisplayName() or ""
            local tx = pad + 30
            local nameW = self.width - tx - 74 - (maxScroll > 0 and 10 or 0)
            if nameW > 20 then
                local tm = getTextManager()
                if tm:MeasureStringX(UIFont.Small, name) > nameW then
                    name = name:sub(1, math.max(1, math.floor(nameW / 6))) .. "..."
                end
                self:drawText(name, tx, ry + (ROW_H - 14) / 2, 0.9, 0.9, 0.9, 1, UIFont.Small)
            end
            -- Condição / contagem (direita)
            local info = ""
            if row.cond then
                info = tostring(row.cond) .. "%"
            elseif row.count and row.count > 1 then
                info = "x" .. tostring(row.count)
            end
            if info ~= "" then
                local color = { 0.9, 0.9, 0.9 }
                if row.cond then
                    if row.cond >= 70 then color = { 0.4, 0.9, 0.4 }
                    elseif row.cond >= 40 then color = { 0.95, 0.8, 0.3 }
                    else color = { 0.95, 0.4, 0.35 } end
                end
                self:drawTextRight(info, self.width - pad - 4 - (maxScroll > 0 and 10 or 0), ry + (ROW_H - 14) / 2, color[1], color[2], color[3], 1, UIFont.Small)
            end
        end
    end

    self:clearStencilRect()

    -- Scrollbar fina quando há overflow
    if maxScroll > 0 and self.listH > 12 then
        local info = self:scrollbarInfo()
        local trackX = self.width - PAD - 6
        self:drawRect(trackX, info.trackTop, 4, info.trackH, 0.3, 0, 0, 0)
        self:drawRect(trackX, info.thumbY, 4, info.thumbH, 0.8, 0.8, 0.8, 0.8)
    end
end

function FloatingGridWindow:prerender()
    ISPanel.prerender(self)

    -- Título: fundo + borda (espelho do header dos grids)
    self:drawRect(0, 0, self.width, self.titleH, 0.85, 0.1, 0.1, 0.1)
    self:drawRectBorder(0, 0, self.width, self.titleH, 0.6, 0.5, 0.5, 0.5)

    local tm = getTextManager()
    local textX = 6

    -- Ícone (bolsa no modo bag; item do stack picker no modo pilha)
    local tex = nil
    if self.bagItem then
        tex = self.bagItem.getTex and self.bagItem:getTex()
            or (self.bagItem.getTexture and self.bagItem:getTexture())
    elseif self.stackRows and self.stackRows[1] then
        local it = self.stackRows[1].item
        tex = it.getTex and it:getTex() or (it.getTexture and it:getTexture())
    end
    if tex then
        self:drawTextureScaledAspect(tex, 4, 3, 20, 20, 1, 1, 1, 1)
        textX = 27
    end

    -- Peso (só no modo bolsa: container tem capacidade/peso)
    local weightStr = nil
    local weightR, weightG, weightB = 0.9, 0.9, 0.9
    if self.bagInventory and self.bagInventory.getCapacityWeight and self.bagInventory.getMaxWeight then
        local w = self.bagInventory:getCapacityWeight()
        local mw = self.bagInventory:getMaxWeight()
        if mw and mw > 0 then
            weightStr = formatWeight(w) .. " / " .. string.format("%d", mw)
            local ratio = w / mw
            if ratio > 1 then ratio = 1 end
            if ratio < 0 then ratio = 0 end
            local THRESHOLD = 0.7
            local colorRatio = 0
            if ratio > THRESHOLD then
                colorRatio = (ratio - THRESHOLD) / (1 - THRESHOLD)
            end
            weightR = 0.9 + (1.0 - 0.9) * colorRatio
            weightG = 0.9 + (0.15 - 0.9) * colorRatio
            weightB = 0.9 + (0.15 - 0.9) * colorRatio
        end
    end

    -- Espaço reservado pros botões (pin + fechar) e pro peso
    local reserved = (BTN_W * 2 + 4) + 6
    if weightStr then
        reserved = reserved + tm:MeasureStringX(UIFont.Small, weightStr) + 6
    end

    -- Título (nome), truncado pra caber
    if self.title then
        local title = self.title
        local available = self.width - textX - reserved
        if available > 20 then
            if tm:MeasureStringX(UIFont.Small, title) > available then
                local truncated = title
                local ellipsis = "..."
                local ew = tm:MeasureStringX(UIFont.Small, ellipsis)
                while #truncated > 0 and tm:MeasureStringX(UIFont.Small, truncated) + ew > available do
                    truncated = truncated:sub(1, #truncated - 1)
                end
                title = truncated .. ellipsis
            end
            self:drawText(title, textX, (self.titleH - 14) / 2, 0.9, 0.9, 0.9, 1, UIFont.Small)
        end
    end

    -- Peso à direita (antes dos botões)
    if weightStr then
        local wx = self.width - (BTN_W * 2 + 4) - 6 - tm:MeasureStringX(UIFont.Small, weightStr)
        self:drawText(weightStr, wx, (self.titleH - 14) / 2, weightR, weightG, weightB, 1, UIFont.Small)
    end

    -- Fundo da área de grid
    self:drawRect(0, self.titleH, self.width, self.height - self.titleH, 0.75, 0.08, 0.08, 0.08)
    self:drawRectBorder(0, 0, self.width, self.height, 0.5, 0.5, 0.5, 0.5)

    -- Destaque quando pinada
    if self.pinned then
        self:drawRectBorder(self.pinBtn:getX(), 1, BTN_W, self.titleH - 2, 0.8, 1.0, 0.9, 0.3)
    end
end

--- Render do modo stack picker (a janela desenha a lista de itens da pilha).
function FloatingGridWindow:render()
    ISPanel.render(self)
    if self.stackMode then
        self:renderStackList()
    end
end

--- Seleciona (ou desseleciona) uma linha. Shift = seleção em faixa;
--- duplo clique = pegar AGORA aquele item (tira 1 da pilha).
function FloatingGridWindow:selectRow(rowIndex, rowId)
    local now = getTimeInMillis()
    if self.lastClickId == rowId and self.lastClickTime and (now - self.lastClickTime) < 400 then
        -- Duplo clique → pega imediatamente
        self.lastClickId = nil
        self.lastClickTime = nil
        local src = self.stackMode.sourceGrid
        if src:takeStackMember(rowId) then
            self.selected = {}
            self:afterTake()
        end
        return
    end
    self.lastClickTime = now
    self.lastClickId = rowId

    if isShiftKeyDown() and self.lastSelectedIndex then
        local lo = math.min(rowIndex, self.lastSelectedIndex)
        local hi = math.max(rowIndex, self.lastSelectedIndex)
        for i = lo, hi do
            local r = self.stackRows and self.stackRows[i]
            if r and r.id then
                self.selected[r.id] = true
            end
        end
    else
        if self.selected[rowId] then
            self.selected[rowId] = nil
        else
            self.selected[rowId] = true
        end
    end
    self.lastSelectedIndex = rowIndex
    self:updateTakeButton()
end

--- Pega (tira da pilha) TODOS os itens selecionados.
function FloatingGridWindow:takeSelected()
    if not self.stackMode then return end
    local src = self.stackMode.sourceGrid
    local ids = {}
    for id in pairs(self.selected or {}) do
        table.insert(ids, id)
    end
    if #ids == 0 then return end
    table.sort(ids)
    for _, id in ipairs(ids) do
        if src.gridCore.items[id] then
            src:takeStackMember(id)
        end
    end
    self.selected = {}
    self:afterTake()
end

--- Atualiza a janela depois de tirar item(s) da pilha (lista, título, fechar).
function FloatingGridWindow:afterTake()
    local src = self.stackMode.sourceGrid
    local leader = self.stackMode.leaderId
    if not src.gridCore.items[leader] or src.gridCore:getStackSize(leader) <= 1 then
        self:close()
    else
        self:refreshStackList()
        local ld = src.gridCore.items[leader]
        local item = ld and ld.itemObj
        local n = src.gridCore:getStackSize(leader)
        self.title = (item and (item:getName() or item:getDisplayName() or "Stack") or "Stack") .. " (" .. tostring(n) .. ")"
        self:updateTakeButton()
    end
end

--- Arrastar a janela pela barra de título. Consome cliques na janela inteira.
--- No modo stack picker: scrollbar (arrastar thumb / pulo no track) e linhas
--- (seleção; duplo clique pega o item).
function FloatingGridWindow:onMouseDown(x, y)
    if self.stackMode and y >= self.titleH then
        if self:isOnScrollbar(x, y) then
            self:startScrollDrag(y)
            return true
        end
        local rowIndex = math.floor((y - self.titleH - 2 + (self.scrollY or 0)) / ROW_H) + 1
        local row = self.stackRows and self.stackRows[rowIndex]
        if row and row.id then
            self:selectRow(rowIndex, row.id)
            return true
        end
    elseif y < self.titleH then
        self.moving = true
        self:bringToTop()
    end
    return true
end

function FloatingGridWindow:onMouseMove(dx, dy)
    if self.scrollDrag then
        self:updateScrollFromMouse(self:getMouseY())
        return
    end
    if self.moving then
        self:setX(self.x + dx)
        self:setY(self.y + dy)
        self:bringToTop()
    end
end

function FloatingGridWindow:onMouseMoveOutside(dx, dy)
    if self.moving then
        self:setX(self.x + dx)
        self:setY(self.y + dy)
        self:bringToTop()
    end
end

function FloatingGridWindow:onMouseUp(x, y)
    self.moving = false
    self.scrollDrag = nil
end

function FloatingGridWindow:onMouseUpOutside(x, y)
    self.moving = false
    self.scrollDrag = nil
end

return FloatingGridWindow
