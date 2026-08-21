--- GridRender.lua
--- O coração visual do GridInventory. 
--- Responsável por desenhar a malha de fundo (os quadrados) e sobrepor os itens nela.

require "ISUI/ISPanel"
require "TimedActions/ISUnequipAction"
local ItemFootprint = require("Algorithm/ItemFootprint")
local ItemCategory = require("Algorithm/ItemCategory")
local GridIconRotation = require("Algorithm/GridIconRotation")
local GridContainer = require("DataModel/GridContainer")
local GridClientNetwork = require("Network/GridClientNetwork")
local GridReorder = require("Algorithm/GridReorder")
local GridSandboxOptions = require("GridSandboxOptions")
local GridInventory_BagDrop = require("System/GridInventory_BagDrop")
local GridInventory_Search = require("System/GridInventory_Search")
local GridJoypad = require("System/GridJoypad")
local GridModOptions = require("System/GridModOptions")

-- Ícone de item não identificado (busca Tarkov): interrogação nativa do PZ.
local GridInventory_QuestionTex = getTexture("media/ui/foraging/questionMark.png")

-- Configurações visuais do nosso estilo "Tarkov"

-- Itens atualmente EM TRANSFERÊNCIA (drag&drop pra outro container): ficam
-- "presos" — não podem ser arrastados de novo até o timer da ação completar.
-- Set global keyed por itemId (o ghost mora no grid ALVO; o item na origem).
GridInventory_InTransit = GridInventory_InTransit or {}

-- Auto-search: tabela persistente por container (playerNum:containerKey).
-- Evita re-trigger quando o hash muda durante o search e os grids são recriados.
_autoSearchDone = _autoSearchDone or {}

local GridRender = ISPanel:derive("GridRender")

local ITEM_BG_COLOR = {r=0.4, g=0.4, b=0.4, a=0.5}
local ITEM_BG_FROZEN = {r=0.2, g=0.6, b=0.9, a=0.5}
local ITEM_BG_HOT = {r=0.9, g=0.2, b=0.2, a=0.5}
-- Clareamento de itens SELECIONADOS (multi-select): sutil, não estoura o
-- contraste com o fundo escuro (antes era 0.3 e ficava claro demais).
local SEL_BRIGHTEN = 0.15

-- Buffer REUTILIZÁVEL dos ícones de status (drawItemStatusIcons): evita alocar
-- uma tabela nova por item por frame. Reset com #active = 0 no início da função.
local statusIconBuffer = {}

-- A opção de "água tinta" é fixa por sessão: cacheia o valor para não buscar
-- no SandboxOptions a cada item renderizado (getOptionByName é uma chamada Java).
local taintEnabledCache = nil
local function isTaintedWaterTextEnabled()
    if taintEnabledCache == nil then
        local opt = getSandboxOptions():getOptionByName("EnableTaintedWaterText")
        taintEnabledCache = opt and opt:getValue() or false
    end
    return taintEnabledCache
end

--- True se o item está DENTRO da árvore do container (ele próprio ou aninhado
--- numa bolsa que está nele). Usado pra não somar o peso 2x: durante o drag o
--- item ainda está no container de origem; se esse container está dentro do
--- ALVO, o getCapacityWeight() já conta o peso do item.
local function isInContainerTree(item, rootContainer)
    if not item or not rootContainer then return false end
    local c = item.getContainer and item:getContainer()
    local guard = 0
    while c and guard < 10 do
        guard = guard + 1
        if c == rootContainer then return true end
        local ci = c.getContainingItem and c:getContainingItem()
        if not ci then break end
        c = ci.getContainer and ci:getContainer()
    end
    return false
end

--- Desenha a borda do footprint com DEGRADE vertical (mesma ideia do fundo):
--- cada faixa do ItemCategory.getGradient pinta um retângulo de 1px na borda
--- esquerda/direita na altura da faixa, e o topo/base usam a 1ª/última cor.
--- Isso dá um contorno colorido em degrade em vez da borda sólida.
---@param self ISUIElement
---@param x number
---@param y number
---@param w number
---@param h number
---@param bands table lista de faixas do ItemCategory.getGradient
---@param alpha number
---@param brighten number 0..1 adicionado a cada componente (seleção)
local function drawGradientBorder(self, x, y, w, h, bands, alpha, brighten)
    local n = #bands
    if n == 0 then return end
    -- Laterais: 1px por faixa
    for _, band in ipairs(bands) do
        local r = math.min(1, band.r + brighten)
        local g = math.min(1, band.g + brighten)
        local b = math.min(1, band.b + brighten)
        self:drawRect(x, y + band.y, 1, band.h, alpha, r, g, b)
        self:drawRect(x + w - 1, y + band.y, 1, band.h, alpha, r, g, b)
    end
    -- Topo e base: cor da 1ª/última faixa
    local t = bands[1]
    local bt = bands[n]
    local tr, tg, tb = math.min(1, t.r + brighten), math.min(1, t.g + brighten), math.min(1, t.b + brighten)
    local br, bg, bb = math.min(1, bt.r + brighten), math.min(1, bt.g + brighten), math.min(1, bt.b + brighten)
    self:drawRect(x, y, w, 1, alpha, tr, tg, tb)
    self:drawRect(x, y + h - 1, w, 1, alpha, br, bg, bb)
end

--- Capacidade de PESO real de um container: o teto que o jogo realmente aplica
--- (getEffectiveCapacity — o MESMO usado pelo hasRoomFor pra bloquear). Ex.: o
--- inventário do jogador mostra getMaxWeight() = 12 ("confortável", força), mas
--- o jogador consegue carregar até getEffectiveCapacity = 50. Usar o teto real
--- evita "Overloaded" prematuro (o jogador ainda cabe). Fallback pra getMaxWeight
--- / getCapacity se getEffectiveCapacity não existir.
---
--- CHÃO: o vanilla exibe getMaxWeight() = 50 (capacidade POR PILHA/quadrado), mas
--- o grid de chão do mod agrega as pilhas de VÁRIOS quadrados vizinhos num
--- container só. O teto que o jogo deixa acumular no chão é maior — hardcoded em
--- 100 no engine (B42; mesmo cap do inventário do jogador). Se usássemos o
--- getEffectiveCapacity do chão (50, por pilha), o feedback de Overloaded
--- dispararia cedo quando o jogo ainda aceita o drop.
local FLOOR_EFFECTIVE_CAPACITY = 100

local function gridCapacity(container, playerObj)
    if container and container.getType and container:getType() == "floor" then
        return FLOOR_EFFECTIVE_CAPACITY
    end
    if container and container.getEffectiveCapacity and playerObj then
        local ec = container:getEffectiveCapacity(playerObj)
        if ec and tonumber(ec) and ec > 0 then return ec end
    end
    if container and container.getMaxWeight then
        local mw = container:getMaxWeight()
        if mw and tonumber(mw) and mw > 0 then return mw end
    end
    if container and container.getCapacity then
        return container:getCapacity()
    end
    return 0
end

function GridRender:new(x, y, gridCore, playerNum, inventoryContainer, gridIndex, containerItem, fallbackIcon, noHeader)
    -- UI Scale (Mod Options): fator em % aplicado ao tamanho da célula, padding
    -- e header. Default 1.0. O global é sincronizado pelo GridModOptions.
    local uiScale = GridInventory_uiScale or 100
    local scale = uiScale / 100
    local headerH = math.floor(28 * scale)
    if noHeader then headerH = 0 end
    local cellSize = math.floor(40 * scale)
    local gridPadding = math.floor(10 * scale)
    local width = (gridCore.width * cellSize) + (gridPadding * 2)
    local height = (gridCore.height * cellSize) + (gridPadding * 2) + headerH
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.gridCore = gridCore
    o.inventoryContainer = inventoryContainer
    o.containerItem = containerItem
    o.gridIndex = gridIndex or 1
    o.fallbackIcon = fallbackIcon
    o.headerH = headerH
    o.cellSize = cellSize
    o.gridPadding = gridPadding
    o.uiScale = scale
    o.playerNum = playerNum or 0
    o.draggedItem = nil
    o.selectedItems = {}
    
    -- o.onMouseDoubleClick = self.onMouseDoubleClick  -- redundante (já herdado via metatable, __index=self); mantido comentado só por clareza
    return o
end

function GridRender:initialise()
    ISPanel.initialise(self)
    -- Texturas de status (espelho do inventário vanilla)
    self.icons = {
        poison   = getTexture("media/ui/SkullPoison.png"),
        broken   = getTexture("media/ui/icon_broken.png"),
        frozen   = getTexture("media/ui/icon_frozen.png"),
        equipped = getTexture("media/ui/icon.png"),
        hotbar   = getTexture("media/ui/iconInHotbar.png"),
        favorite = getTexture("media/ui/FavoriteStar.png"),
        nocraft  = getTexture("media/ui/inventoryPanes/nocraft.png"),
        read     = getTexture("media/ui/Tick_Mark-10.png"),
    }
end

--- Resolve o FluidContainer de um item, incluindo o fallback do worldItem:
--- itens no chão/loot guardam o fluido no worldItem (espelha o vanilla
--- ISInventoryItem.renderItemIcon / ISInventoryPane tooltip). Sem isso, um copo
--- com água no chão renderiza a máscara de fluido como branca/sem líquido.
--- Prefere um container NÃO-vazio (próprio ou do worldItem).
local function getItemFluidContainer(item)
    local fc = item.getFluidContainer and item:getFluidContainer()
    if (not fc or (fc.isEmpty and fc:isEmpty())) and item.getWorldItem then
        local wi = item:getWorldItem()
        if wi and wi.getFluidContainer then
            fc = wi:getFluidContainer()
        end
    end
    return fc
end

--- Coleta e desenha ícones de status de um item em modo flex (máx 2 por linha).
--- Cada ícone tem 12x12 px. Coluna 1 fica no canto superior-esquerdo, Coluna 2 ao lado.
--- Se tiver mais de 2, empilha na linha de baixo.
--- playerObj e hotbar sao passados de fora (hoisted do loop de itens) para evitar
--- getSpecificPlayer/getPlayerHotbar por item a cada frame.
function GridRender:drawItemStatusIcons(item, drawX, drawY, playerObj, hotbar)
    if not item then return end

    -- ── Coleta de condições ──────────────────────────────────────────────────
    -- Buffer reutilizado (módulo) em vez de alocar {} por item por frame.
    -- Lua 5.1 não permite #t = 0: limpa os elementos do array a cada chamada.
    local active = statusIconBuffer
    for i = #active, 1, -1 do active[i] = nil end

    -- Favorito
    if item.isFavorite and item:isFavorite() then
        table.insert(active, self.icons.favorite)
    end

    -- Inutilizável em receitas (b42): ícone do martelinho com X (mesmo da
    -- opção do menu de contexto). Estado POR JOGADOR (isNoRecipes(playerObj)).
    if item.isNoRecipes and playerObj and item:isNoRecipes(playerObj) then
        table.insert(active, self.icons.nocraft)
    end

    -- Equipado
    if playerObj and playerObj.isEquipped and playerObj:isEquipped(item) then
        table.insert(active, self.icons.equipped)
    end

    -- No hotbar
    if playerObj and not (playerObj.isEquipped and playerObj:isEquipped(item)) then
        if hotbar and hotbar:isInHotbar(item) then
            table.insert(active, self.icons.hotbar)
        end
    end

    -- Envenenado / água suja
    local isPoison = false
    if instanceof(item, "Food") then
        local taintEnabled = isTaintedWaterTextEnabled()
        if (item.isTainted and item:isTainted() and taintEnabled) or (playerObj and playerObj:isKnownPoison(item)) then
            isPoison = true
        end
    end
    local fluid = getItemFluidContainer(item)
    if fluid and not fluid:isEmpty() then
        local taintEnabled = isTaintedWaterTextEnabled()
        if fluid:contains(Fluid.Bleach) or (fluid:contains(Fluid.TaintedWater) and fluid:getPoisonRatio() > 0.1 and taintEnabled) then
            isPoison = true
        end
    end
    if isPoison then table.insert(active, self.icons.poison) end

    -- Quebrado (condição 0 ou isBroken)
    local isBroken = (item.isBroken and item:isBroken())
        or (item.getCondition and item.getConditionMax and item:getConditionMax() > 0 and item:getCondition() <= 0)
    if isBroken then table.insert(active, self.icons.broken) end

    -- Congelado (alimento)
    if instanceof(item, "Food") and item.isFrozen and item:isFrozen() then
        table.insert(active, self.icons.frozen)
    end

    -- Lido / visto
    local isRead = false
    if playerObj then
        if item.IsLiterature and item:IsLiterature() then
            -- verifica literatura (livros, revistas, mapas)
            local md = item:hasModData() and item:getModData() or nil
            if md then
                if md.literatureTitle and playerObj:isLiteratureRead(md.literatureTitle) then isRead = true end
                if md.printMedia and playerObj:isPrintMediaRead(md.printMedia.title) then isRead = true end
                if md.learnedRecipe and playerObj:getKnownRecipes():contains(md.learnedRecipe) then isRead = true end
            end
            local skillBook = SkillBook and SkillBook[item:getSkillTrained()]
            if skillBook and item:getMaxLevelTrained() < playerObj:getPerkLevel(skillBook.perk) + 1 then isRead = true end
            if item:getNumberOfPages() > 0 and playerObj:getAlreadyReadPages(item:getFullType()) == item:getNumberOfPages() then isRead = true end
            if item:getLearnedRecipes() and playerObj:getKnownRecipes():containsAll(item:getLearnedRecipes()) then isRead = true end
        end
        if not isRead then
            local hasSeen  = item.hasBeenSeen  and item:hasBeenSeen(playerObj)
            local hasHeard = item.hasBeenHeard and item:hasBeenHeard(playerObj)
            local hasMap   = playerObj.hasReadMap and playerObj:hasReadMap(item)
            if hasSeen or hasHeard or hasMap then isRead = true end
        end
    end
    if isRead then table.insert(active, self.icons.read) end

    -- ── Renderização flex (12x12, 2 colunas, canto superior-esquerdo) ─────────
    if #active == 0 then return end
    local S   = 12   -- tamanho de cada ícone
    local PAD = 2    -- padding entre ícones
    for i, tex in ipairs(active) do
        if tex then
            local col = (i - 1) % 2
            local row = math.floor((i - 1) / 2)
            local ix = drawX + col * (S + PAD)
            local iy = drawY + row * (S + PAD)
            self:drawTextureScaled(tex, ix, iy, S, S, 1, 1, 1, 1)
        end
    end
end

function GridRender:drawItemIconRotated(item, x, y, w, h, isRotated, r, g, b, a, deg)
    if not item then return end
    local texture = item:getTex() or item:getTexture()
    if not texture then return end

    -- OVERFLOW: os itens do overflow são forçados 1x1 — desliga rotação (angle)
    -- e escala (scale) pra sprite não estourar as bordas da célula única.
    -- Antes da rotação livre os overrides de angle/scale eram ignorados no
    -- overflow (não existiam); com eles ativos o sprite crescia pra fora.
    if self.isOverflow then
        deg = nil
    end

    -- Rotação LIVRE (ângulo que não é múltiplo de 90°): caminho separado pra
    -- sprites que nascem tortos no arquivo. O caminho de 90° (isRotated) fica
    -- intacto e é o hot path — deg nil/0 nem passa por aqui.
    if deg and deg ~= 0 then
        return GridRender.drawItemIconRotatedFree(self, item, x, y, w, h, isRotated, deg, r, g, b, a)
    end

    r = r or 1
    g = g or 1
    b = b or 1
    a = a or 1
    
    local texW = texture:getWidth()
    local texH = texture:getHeight()
    
    local isCustomTint = (r ~= 1 or g ~= 1 or b ~= 1)
    
    -- Padding do ícone DENTRO do footprint (1px cada lado): a borda do footprint
    -- é 1px e alguns sprites nasciam tocando/cortando as bordas. Reduzimos a
    -- ESCALA (área desenhável) em PAD e centralizamos no w/h original — assim o
    -- sprite nunca encosta na borda, em qualquer tamanho/orientação.
    local PAD = 2
    local scaleW = math.max(1, w - PAD)
    local scaleH = math.max(1, h - PAD)
    
    -- Itens com máscara de fluido NÃO passam pelo DrawItemIcon nativo nem na
    -- posição normal: o Java desenha a máscara com geometria própria que, em
    -- alguns itens, nasce 1px menor que o conteúdo do item. O caminho manual
    -- abaixo (SpriteRenderer com UVs) renderiza a máscara alinhada e no tamanho
    -- exato da textura base — o mesmo já usado nos itens rotacionados.
    local hasFluidMask = item.getTextureFluidMask and item:getTextureFluidMask() ~= nil
    
    -- Caminho MANUAL (sempre): desenha com DrawTexture a textura VISÍVEL
    -- centralizada, ignorando as margens/offsets nativos do DrawItemIcon
    -- (getWidthOrig/getOffsetX) — que, em itens compridos EM PÉ, arrastavam o
    -- sprite pra fora do footprint e o cortavam. Rotacionado/tint/máscara já
    -- usavam este caminho e sempre ficaram certos; agora unifica tudo num só.
    local visualTexW = isRotated and texH or texW
    local visualTexH = isRotated and texW or texH
    -- Multiplicador de escala do "Icon Scale" (GridDevTool/tabela fixa), MESMO
    -- padrão do caminho livre (drawItemIconRotatedFree). Sem isso, o override
    -- de escala era IGNORADO em ângulo 0 (só valia na rotação livre).
    -- OVERFLOW: ignora o multiplicador (scale=1) — célula única 1x1 não pode
    -- estourar a sprite pra fora.
    local scale = math.min(scaleW / visualTexW, scaleH / visualTexH) * (self.isOverflow and 1 or GridIconRotation.getRenderScale(item))
    
    local drawW = (isRotated and texH or texW) * scale
    local drawH = (isRotated and texW or texH) * scale
    
    local offsetX = (w - drawW) / 2
    local offsetY = (h - drawH) / 2

    -- Anchor do sprite dentro do footprint (deslocamento em px, positivo =
    -- pra direita/baixo), no espaço da SPRITE. Compensa itens cuja massa
    -- visual (lâmina/cabo) nasce fora do centro do PNG. Quando a sprite gira
    -- (isRotated), o anchor gira JUNTO — senão a compensação "inverte" de lado
    -- (a direita do PNG passa a apontar pra outra direção, e o ajuste que
    -- empurrava pra direita vira esquerda).
    -- OVERFLOW: ignora o anchor também — célula única 1x1 não comporta sprite
    -- deslocada sem estourar a borda (mesmo critério do scale/deg acima).
    local anchorX, anchorY = 0, 0
    if not self.isOverflow then
        anchorX, anchorY = GridIconRotation.getRenderAnchor(item)
        if isRotated then
            anchorX, anchorY = anchorY, -anchorX
        end
    end
    
    local absX = self:getAbsoluteX() + x + offsetX + anchorX
    local absY = self:getAbsoluteY() + y + offsetY + anchorY
        
    local hasColorMask = item.getTextureColorMask and item:getTextureColorMask()
    
    local baseR, baseG, baseB = 1, 1, 1
    if not hasColorMask and item.getColor and item:getColor() then
        baseR = item:getColor():getR()
        baseG = item:getColor():getG()
        baseB = item:getColor():getB()
    end
    
    local finalR = isCustomTint and r or baseR
    local finalG = isCustomTint and g or baseG
    local finalB = isCustomTint and b or baseB
    
    -- Textura Base (já vem com a sprite de queimado/podre graças ao getTex()).
    -- Chamada DIRETA (não uma closure por item por frame): o renderTex antigo era
    -- alocado uma vez por item e usado UMA única vez abaixo.
    if not isRotated then
        self.javaObject:DrawTexture(texture, absX, absY, absX+drawW, absY, absX+drawW, absY+drawH, absX, absY+drawH, finalR, finalG, finalB, a)
    else
        self.javaObject:DrawTexture(texture, absX, absY+drawH, absX, absY, absX+drawW, absY, absX+drawW, absY+drawH, finalR, finalG, finalB, a)
    end
    
    -- Fluid Mask (Sangue/Água Suja)
    if item.getTextureFluidMask and item:getTextureFluidMask() then
        local fluidColor = {r=1, g=1, b=1}
        local fc = getItemFluidContainer(item)
        local fluidPercent = 1.0
        
        if fc then
            fluidColor.r = fc:getColor():getR()
            fluidColor.g = fc:getColor():getG()
            fluidColor.b = fc:getColor():getB()
            
            local cap = fc:getCapacity()
            if cap > 0 then
                fluidPercent = fc:getAmount() / cap
            end
        elseif instanceof(item, "DrainableComboItem") then
            local maxUses = item:getMaxUses()
            if maxUses > 0 then
                fluidPercent = item:getCurrentUses() / maxUses
            end
        end
        
        if fluidPercent < 0.15 then fluidPercent = 0.15 end
        if fluidPercent > 1.0 then fluidPercent = 1.0 end
        
        local fmR = isCustomTint and finalR or fluidColor.r
        local fmG = isCustomTint and finalG or fluidColor.g
        local fmB = isCustomTint and finalB or fluidColor.b
        
        local fTex = item:getTextureFluidMask()
        
        if fTex then
            local tx1 = fTex:getXStart()
            local ty1 = fTex:getYStart()
            local tx2 = fTex:getXEnd()
            local ty2 = fTex:getYEnd()
            
            local missing = 1.0 - fluidPercent
            local yD = ty2 - ty1
            
            local tlx, tly = tx1, ty1
            local trx, try = tx2, ty1
            local brx, bry = tx2, ty2
            local blx, bly = tx1, ty2
            
            local relOffsetX = (fTex:getOffsetX() - texture:getOffsetX()) * scale
            local relOffsetY = (fTex:getOffsetY() - texture:getOffsetY()) * scale
            
            if not isRotated then
                local maskDrawW = fTex:getWidth() * scale
                local maskDrawH = fTex:getHeight() * scale
                local maskAbsX = absX + relOffsetX
                local maskAbsY = absY + relOffsetY
                
                tly = tly + yD * missing
                try = try + yD * missing
                
                local screenMissing = maskDrawH * missing
                local rx = maskAbsX
                local ry = maskAbsY + screenMissing
                local rw = maskDrawW
                local rh = maskDrawH - screenMissing
                
                SpriteRenderer.instance:render(fTex, rx, ry, rw, rh, fmR, fmG, fmB, a, tlx, tly, trx, try, brx, bry, blx, bly)
            else
                local maskDrawW = fTex:getHeight() * scale
                local maskDrawH = fTex:getWidth() * scale
                local maskAbsX = absX + relOffsetY
                local maskAbsY = absY + drawH - relOffsetX - maskDrawH
                
                tly = tly + yD * missing
                try = try + yD * missing
                
                local screenMissing = maskDrawW * missing
                local rx = maskAbsX + screenMissing
                local ry = maskAbsY
                local rw = maskDrawW - screenMissing
                local rh = maskDrawH
                
                -- UV mapping for Counter-Clockwise: TL->TR, TR->BR, BR->BL, BL->TL
                local uv1X, uv1Y = trx, try
                local uv2X, uv2Y = brx, bry
                local uv3X, uv3Y = blx, bly
                local uv4X, uv4Y = tlx, tly
                
                SpriteRenderer.instance:render(fTex, rx, ry, rw, rh, fmR, fmG, fmB, a, uv1X, uv1Y, uv2X, uv2Y, uv3X, uv3Y, uv4X, uv4Y)
            end
        end
    end
    
    -- Color Mask (Tintas de Cabelo, etc.)
    if hasColorMask then
        local maskR, maskG, maskB = 1, 1, 1
        if item.getColor and item:getColor() then
            maskR = item:getColor():getR()
            maskG = item:getColor():getG()
            maskB = item:getColor():getB()
        end
        local mR = isCustomTint and finalR or maskR
        local mG = isCustomTint and finalG or maskG
        local mB = isCustomTint and finalB or maskB
        -- A máscara de cor NÃO é esticada pro retângulo da base: ela tem
        -- geometria própria (offset/tamanho) e é alinhada ao MESMO "full
        -- box" que a base e a máscara de fluido (mesma fórmula do fluido).
        -- Antes era desenhada no retângulo da base e, quando a geometria
        -- difere (ex.: WaterBottle_Mask2 do PopBottle, 14x16 vs 25x31 da
        -- base), ficava maior que o item cobrindo ele inteiro.
        local cmTex = hasColorMask
        local cmOffX = (cmTex:getOffsetX() - texture:getOffsetX()) * scale
        local cmOffY = (cmTex:getOffsetY() - texture:getOffsetY()) * scale
        if not isRotated then
            local rx = absX + cmOffX
            local ry = absY + cmOffY
            local rw = cmTex:getWidth() * scale
            local rh = cmTex:getHeight() * scale
            self.javaObject:DrawTexture(cmTex, rx, ry, rx+rw, ry, rx+rw, ry+rh, rx, ry+rh, mR, mG, mB, a)
        else
            local rw = cmTex:getHeight() * scale
            local rh = cmTex:getWidth() * scale
            local rx = absX + cmOffY
            local ry = absY + drawH - cmOffX - rh
            local tx1 = cmTex:getXStart(); local ty1 = cmTex:getYStart()
            local tx2 = cmTex:getXEnd(); local ty2 = cmTex:getYEnd()
            SpriteRenderer.instance:render(cmTex, rx, ry, rw, rh, mR, mG, mB, a,
                tx2, ty1, tx2, ty2, tx1, ty2, tx1, ty1)
        end
    end
end

--- Rotação LIVRE do sprite do item (qualquer ângulo, não só múltiplos de 90°).
--- Usado pra sprites que nascem TORTOS no arquivo vanilla: em vez de editar o
--- PNG, o GridRender gira o quad em runtime. É um paralelogramo (retângulo
--- rotacionado em volta do centro), desenhado via DrawTexture nos 4 cantos —
--- o mapeamento UV fica exato porque o quad continua sendo um retângulo girado.
--- A escala é MIN-FIT do RETÂNGULO GIRO (preserva o aspecto da textura, não
--- deforma): o bbox do quad rotacionado é acomodado no footprint, então a
--- sprite gira NO LUGAR (centro fixo) e nunca invade células vizinhas — o
--- resultado é igual ao do caminho isRotated e ao vanilla. O "Icon Scale" do
--- DevTool é um multiplicador sobre o min-fit pra crescer até tocar a borda
--- sem esticar (fill deformava quando o aspecto do footprint != do PNG).
--- isRotated (giro de 90° da tecla R) é composto no ângulo (soma −90°), então
--- girar o footprint também gira o sprite torto — antes, o caminho livre
--- ignorava o isRotated e a sprite ficava no ângulo fixo ao rotacionar.
--- O footprint (w/h da célula) NÃO muda: só o sprite dentro dela gira.
--- Fluid/color masks também giram (mesmo centro/ângulo) pra manter o item íntegro.
function GridRender:drawItemIconRotatedFree(item, x, y, w, h, isRotated, deg, r, g, b, a)
    if not item then return end
    local texture = item:getTex() or item:getTexture()
    if not texture then return end

    deg = deg or 0
    -- OVERFLOW: desliga a rotação (volta pro caminho normal, já com scale=1
    -- forçado lá). Célula 1x1 não comporta sprite girada sem estourar a borda.
    if self.isOverflow then
        deg = 0
    end
    if deg == 0 then
        GridRender.drawItemIconRotated(self, item, x, y, w, h, isRotated, r, g, b, a)
        return
    end

    r = r or 1
    g = g or 1
    b = b or 1
    a = a or 1

    local texW = texture:getWidth()
    local texH = texture:getHeight()

    local isCustomTint = (r ~= 1 or g ~= 1 or b ~= 1)

    -- Padding do ícone DENTRO do footprint (mesmo PAD do caminho normal).
    local PAD = 2
    local scaleW = math.max(1, w - PAD)
    local scaleH = math.max(1, h - PAD)

    -- Ângulo EFETIVO: o isRotated (tecla R) compõe −90° no ângulo fixo. O quad
    -- é SEMPRE girado fisicamente por esse ângulo — não há swap de texW/H aqui
    -- (diferente do caminho normal), porque a rotação real cuida da orientação.
    local effDeg = deg + (isRotated and -90 or 0)
    local rad = effDeg * math.pi / 180
    local cosT = math.cos(rad)
    local sinT = math.sin(rad)

    -- Min-fit do RETÂNGULO GIRO: o bbox do quad rotacionado é
    --   bboxW = |texW·cosθ| + |texH·sinθ|
    --   bboxH = |texW·sinθ| + |texH·cosθ|
    -- e esse bbox é acomodado no footprint. Assim a sprite gira NO LUGAR (o
    -- centro nunca se move) e fica sempre dentro da célula — girar nunca a faz
    -- "deslizar" para as células vizinhas. * multiplicador de escala.
    local bboxW = math.abs(texW * cosT) + math.abs(texH * sinT)
    local bboxH = math.abs(texW * sinT) + math.abs(texH * cosT)
    -- OVERFLOW: escala 1 (o guard acima já zera deg, mas por robustez).
    local iconScale = self.isOverflow and 1 or GridIconRotation.getRenderScale(item)
    local scale = math.min(scaleW / bboxW, scaleH / bboxH) * iconScale
    local drawW = texW * scale
    local drawH = texH * scale

    local offsetX = (w - drawW) / 2
    local offsetY = (h - drawH) / 2

    local absX = self:getAbsoluteX() + x + offsetX
    local absY = self:getAbsoluteY() + y + offsetY

    -- Centro do quad (o retângulo é girado em volta DELE, não do canto).
    local centerX = absX + drawW / 2
    local centerY = absY + drawH / 2

    -- Anchor (espaço da SPRITE): deslocamento do quad DENTRO da célula, girado
    -- junto com a sprite pelo mesmo ângulo efetivo. Somado ao CENTRO (não a
    -- absX/absY): girar a sprite 90° faz o anchor que compensava "direita do
    -- PNG" passar a compensar a direção nova da sprite — nunca "inverte" de
    -- lado como o deslocamento em espaço de tela faria.
    -- OVERFLOW: ignora o anchor (célula 1x1 não comporta deslocamento).
    local anchorX, anchorY = 0, 0
    if not self.isOverflow then
        anchorX, anchorY = GridIconRotation.getRenderAnchor(item)
        centerX = centerX + anchorX * cosT - anchorY * sinT
        centerY = centerY + anchorX * sinT + anchorY * cosT
    end

    -- 4 cantos do retângulo NÃO girado (semi-lados em px), depois gira.
    local hw = drawW / 2
    local hh = drawH / 2
    local corners = {
        {-hw, -hh},
        { hw, -hh},
        { hw,  hh},
        {-hw,  hh},
    }
    for i = 1, 4 do
        local px, py = corners[i][1], corners[i][2]
        local rx = px * cosT - py * sinT
        local ry = px * sinT + py * cosT
        corners[i][1] = centerX + rx
        corners[i][2] = centerY + ry
    end

    -- Rotação em volta do centro com canto: x' = x·cos − y·sin; y' = x·sin + y·cos.
    -- Como giramos ao redor do centro do próprio quad, esse é o caminho direto.

    local hasColorMask = item.getTextureColorMask and item:getTextureColorMask()

    local baseR, baseG, baseB = 1, 1, 1
    if not hasColorMask and item.getColor and item:getColor() then
        baseR = item:getColor():getR()
        baseG = item:getColor():getG()
        baseB = item:getColor():getB()
    end

    local finalR = isCustomTint and r or baseR
    local finalG = isCustomTint and g or baseG
    local finalB = isCustomTint and b or baseB

    -- Textura Base (mesma DrawTexture dos 4 cantos; quad rotacionado é exato).
    self.javaObject:DrawTexture(texture,
        corners[1][1], corners[1][2],
        corners[2][1], corners[2][2],
        corners[3][1], corners[3][2],
        corners[4][1], corners[4][2],
        finalR, finalG, finalB, a)

    -- Fluid Mask (Sangue/Água Suja): gira com o mesmo centro/ângulo.
    if item.getTextureFluidMask and item:getTextureFluidMask() then
        local fTex = item:getTextureFluidMask()
        local fluidColor = {r=1, g=1, b=1}
        local fc = getItemFluidContainer(item)
        local fluidPercent = 1.0
        if fc then
            fluidColor.r = fc:getColor():getR()
            fluidColor.g = fc:getColor():getG()
            fluidColor.b = fc:getColor():getB()
            local cap = fc:getCapacity()
            if cap > 0 then fluidPercent = fc:getAmount() / cap end
        elseif instanceof(item, "DrainableComboItem") then
            local maxUses = item:getMaxUses()
            if maxUses > 0 then fluidPercent = item:getCurrentUses() / maxUses end
        end
        if fluidPercent < 0.15 then fluidPercent = 0.15 end
        if fluidPercent > 1.0 then fluidPercent = 1.0 end

        local fmR = isCustomTint and finalR or fluidColor.r
        local fmG = isCustomTint and finalG or fluidColor.g
        local fmB = isCustomTint and finalB or fluidColor.b

        -- Geometria da máscara relativa à base (offsets próprios do fTex).
        local fW = fTex:getWidth()
        local fH = fTex:getHeight()
        local offX = (fTex:getOffsetX() - texture:getOffsetX())
        local offY = (fTex:getOffsetY() - texture:getOffsetY())

        -- Quad da máscara no MESMO espaço da base (pré-rotação), centrado no
        -- centro da base: canto TL da base = centerX − drawW/2.
        local maskCorners = {
            { centerX - drawW / 2 + offX * scale, centerY - drawH / 2 + offY * scale },
            { centerX - drawW / 2 + (offX + fW) * scale, centerY - drawH / 2 + offY * scale },
            { centerX - drawW / 2 + (offX + fW) * scale, centerY - drawH / 2 + (offY + fH) * scale },
            { centerX - drawW / 2 + offX * scale, centerY - drawH / 2 + (offY + fH) * scale },
        }
        for i = 1, 4 do
            local px, py = maskCorners[i][1] - centerX, maskCorners[i][2] - centerY
            maskCorners[i][1] = centerX + px * cosT - py * sinT
            maskCorners[i][2] = centerY + px * sinT + py * cosT
        end

        -- Corte de nível (porcentagem de fluido): mantém a máscara inteira como
        -- fallback simples — nível com rotação livre é raro e este caminho já
        -- preserva posição/tamanho da máscara girada em relação à base.
        self.javaObject:DrawTexture(fTex,
            maskCorners[1][1], maskCorners[1][2],
            maskCorners[2][1], maskCorners[2][2],
            maskCorners[3][1], maskCorners[3][2],
            maskCorners[4][1], maskCorners[4][2],
            fmR, fmG, fmB, a)
    end

    -- Color Mask (Tintas de Cabelo, etc.)
    if hasColorMask then
        local cmTex = hasColorMask
        local maskR, maskG, maskB = 1, 1, 1
        if item.getColor and item:getColor() then
            maskR = item:getColor():getR()
            maskG = item:getColor():getG()
            maskB = item:getColor():getB()
        end
        local mR = isCustomTint and finalR or maskR
        local mG = isCustomTint and finalG or maskG
        local mB = isCustomTint and finalB or maskB

        local cmW = cmTex:getWidth()
        local cmH = cmTex:getHeight()
        local cmOffX = (cmTex:getOffsetX() - texture:getOffsetX())
        local cmOffY = (cmTex:getOffsetY() - texture:getOffsetY())

        local cmCorners = {
            { centerX - drawW / 2 + cmOffX * scale, centerY - drawH / 2 + cmOffY * scale },
            { centerX - drawW / 2 + (cmOffX + cmW) * scale, centerY - drawH / 2 + cmOffY * scale },
            { centerX - drawW / 2 + (cmOffX + cmW) * scale, centerY - drawH / 2 + (cmOffY + cmH) * scale },
            { centerX - drawW / 2 + cmOffX * scale, centerY - drawH / 2 + (cmOffY + cmH) * scale },
        }
        for i = 1, 4 do
            local px, py = cmCorners[i][1] - centerX, cmCorners[i][2] - centerY
            cmCorners[i][1] = centerX + px * cosT - py * sinT
            cmCorners[i][2] = centerY + px * sinT + py * cosT
        end

        self.javaObject:DrawTexture(cmTex,
            cmCorners[1][1], cmCorners[1][2],
            cmCorners[2][1], cmCorners[2][2],
            cmCorners[3][1], cmCorners[3][2],
            cmCorners[4][1], cmCorners[4][2],
            mR, mG, mB, a)
    end
end

--- Badge de contagem no canto inferior-direito da célula: mostra o TOTAL DE
--- UNIDADES da pilha (getPileUnits — soma de getCount() de líder + membros).
--- É a "capa" real do item: 100 pregos, 50 munição 9mm, 12 twines.
function GridRender:drawStackCountBadge(itemId, drawX, drawY, drawW, drawH, total)
    local total = total or (self.gridCore and self.gridCore:getPileUnits(itemId) or 1)
    local text = tostring(total)
    local textW = getTextManager():MeasureStringX(UIFont.Small, text)
    local bx = drawX + drawW - textW - 5
    local by = drawY + drawH - 15
    self:drawRect(bx, by, textW + 5, 14, 0.85, 0, 0, 0)
    self:drawText(text, bx + 2, by + 1, 1, 1, 1, 1, UIFont.Small)
end

function GridRender:prerender()
    ISPanel.prerender(self)
    
    -- Efeito de "Piscar" o Grid quando selecionado/targuetado pelo auto-scroll
    if self.flashAlpha and self.flashAlpha > 0 then
        self:drawRect(0, 0, self.width, self.height, self.flashAlpha * 0.2, 1.0, 0.9, 0.3)
        self:drawRectBorder(0, 0, self.width, self.height, self.flashAlpha, 1.0, 0.9, 0.3)
        
        self.flashAlpha = self.flashAlpha - 0.03 * (UIManager.getMillisSinceLastRender() / 33.3)
        if self.flashAlpha < 0 then
            self.flashAlpha = 0
        end
    end
end

-- Cache da memoização do truncateText (ver função acima)
local truncateCache = {}
local truncateCacheCount = 0
local TRUNCATE_CACHE_MAX = 256

local function truncateText(text, maxWidth, font)
    if not text or text == "" then return text end
    -- Memoização: o resultado só depende de (texto, largura, fonte). Títulos e
    -- larguras mudam raramente, então evitamos o loop de MeasureStringX por
    -- frame. Cache limitado para não crescer sem controle numa sessão longa.
    local key = text .. "\0" .. tostring(maxWidth) .. "\0" .. tostring(font)
    local cached = truncateCache[key]
    if cached ~= nil then return cached end

    local textManager = getTextManager()
    local result = text
    if textManager:MeasureStringX(font, text) <= maxWidth then
        result = text
    else
        local ellipsis = "..."
        local ellipsisWidth = textManager:MeasureStringX(font, ellipsis)
        if ellipsisWidth < maxWidth then
            local truncated = text
            while #truncated > 0 and textManager:MeasureStringX(font, truncated) + ellipsisWidth > maxWidth do
                truncated = truncated:sub(1, #truncated - 1)
            end
            result = truncated .. ellipsis
        else
            result = ""
        end
    end

    truncateCache[key] = result
    truncateCacheCount = truncateCacheCount + 1
    if truncateCacheCount > TRUNCATE_CACHE_MAX then
        truncateCache = {}
        truncateCacheCount = 0
    end
    return result
end

-- Movido pra fora do render(): assim não precisa existir duas vezes (uma pra medir,
-- outra pra desenhar). Mesma lógica de antes, só que compartilhada.
local function formatWeight(value)
    local rounded = math.floor(value * 100 + 0.5) / 100
    if rounded == math.floor(rounded) then
        return string.format("%d", rounded)
    end
    local str = string.format("%.2f", rounded)
    str = str:gsub("0+$", ""):gsub("%.$", "")
    return str
end

--- Container deste grid é uma bolsa ANINHADA NO MUNDO (bolsa dentro de bolsa
--- em container de objeto)? O engine recusa mexer no conteúdo — o grid fica
--- "travado" (só leitura: sem drag in/out, sem reorder, sem autoSlot). Bolsa
--- aninhada dentro do inventário do jogador NÃO trava.
function GridRender:isLocked()
    if not self.inventoryContainer then return false end
    local playerObj = getSpecificPlayer(self.playerNum)
    return GridInventory_BagDrop.isNestedLocked(self.inventoryContainer, playerObj)
end

--- Chave estável de busca do container (nil = nunca oculta: chão/inventário
--- do jogador — mochilas vestidas/equipadas/nas mãos).
function GridRender:searchKey()
    if not self.inventoryContainer then return nil end
    local playerObj = getSpecificPlayer(self.playerNum)
    return GridInventory_Search.containerKey(self.inventoryContainer, playerObj)
end

--- Item está OCULTO (não vasculhado) pra este jogador?
---@param itemObj InventoryItem
---@return boolean
function GridRender:isItemHidden(itemObj)
    if not itemObj then return false end
    -- Equipado/vestido (roupa em corpse): já visível, nunca oculta.
    if GridInventory_Search.isAlwaysRevealed(itemObj) then return false end
    if not GridSandboxOptions.isSearchWorldContainers() then return false end
    local key = self:searchKey()
    if not key then return false end -- chão/inventário nunca ocultam
    return GridInventory_Search.isItemHidden(self.playerNum, key, itemObj:getID(), self.inventoryContainer)
end

--- Container precisa ser vasculhado AGORA (tem pelo menos um item oculto)?
---@return boolean
function GridRender:needsSearch()
    if not self.inventoryContainer then return false end
    if not GridSandboxOptions.isSearchWorldContainers() then return false end
    local key = self:searchKey()
    if not key then return false end
    return GridInventory_Search.hasHiddenItems(self.playerNum, key, self.inventoryContainer)
end

--- Inicia (ou retoma) a busca do container: cria uma GridSearchAction com as
--- pilhas ainda ocultas. Se o tempo por item é 0, revela tudo na hora. Também
--- torna este container o ALVO ativo (selectContainer) — vasculhar = interagir
--- com ele, então o painel de loot passa a apontar pra cá.
---@return boolean true se iniciou (ou já revelou tudo)
function GridRender:startSearch()
    if not self.inventoryContainer then return false end
    if not GridSandboxOptions.isSearchWorldContainers() then return false end
    local key = self:searchKey()
    if not key then return false end

    -- Guard: não enfileira múltiplas ações de busca pro mesmo container.
    -- Clique repetido enquanto a ação roda é ignorado (o que já foi revelado
    -- fica salvo; o clique seguinte DEPOIS que a ação termina retoma o que
    -- ainda está oculto).
    if self._searchActive then return true end

    -- Guard global: se a UI for recriada violentamente (ex: andando de carro com multi-container),
    -- impede que dezenas de ações sejam enfileiradas para o mesmo container.
    local playerObj = getSpecificPlayer(self.playerNum)
    if playerObj then
        local q = ISTimedActionQueue.getTimedActionQueue(playerObj)
        if q and q.queue then
            for i = 1, #q.queue do
                local act = q.queue[i]
                if act.Type == "GridSearchAction" and act.containerKey == key then
                    self._searchActive = true
                    return true
                end
            end
        end
    end

    -- Torna o container o alvo ativo do painel (mesma lógica do duplo clique
    -- no fundo / clique no header).
    local pLoot = getPlayerLoot(self.playerNum)
    local pInv = getPlayerInventory(self.playerNum)
    for _, page in ipairs({pLoot, pInv}) do
        if page and page.backpacks then
            for _, btn in ipairs(page.backpacks) do
                if btn.inventory == self.inventoryContainer then
                    if page.selectContainer then
                        page:selectContainer(btn)
                    end
                    break
                end
            end
        end
    end

    local playerObj = getSpecificPlayer(self.playerNum)
    if not playerObj then return false end

    local msPer = GridSandboxOptions.getSearchTimePerItem()
    if msPer <= 0 then
        -- Instantâneo: revela tudo agora, sem timed action.
        GridInventory_Search.revealAll(self.playerNum, key, self.inventoryContainer:getItems())
        self._searchActive = false
        return true
    end

    -- Retoma: a ação re-coleta só as pilhas ainda ocultas no construtor.
    local GridSearchAction = require("TimedActions/GridSearchAction")
    self._searchActive = true
    ISTimedActionQueue.add(GridSearchAction:new(playerObj, self, key))
    return true
end

function GridRender:render()
    if GridInventory_Profiler and GridInventory_Profiler.enabled and self.gridCore then
        GridInventory_Profiler.renderGrid(self.gridCore.width or 0, self.gridCore.height or 0)
    end

    local mouseX = self:getMouseX()
    local mouseY = self:getMouseY()
    
    if self.headerH and self.headerH > 0 then
        self:drawRect(self.gridPadding, self.gridPadding, self.width - (self.gridPadding*2), self.headerH - 4, 0.5, 0.1, 0.1, 0.1)
        
        local isActive = false
        local pInv = getPlayerInventory(self.playerNum)
        local pLoot = getPlayerLoot(self.playerNum)
        
        if self.inventoryContainer then
            if pInv and pInv.inventory == self.inventoryContainer then
                isActive = true
            elseif pLoot and pLoot.inventory == self.inventoryContainer then
                isActive = true
            end
        end
        
        if isActive then
            self:drawRectBorder(self.gridPadding, self.gridPadding, self.width - (self.gridPadding*2), self.headerH - 4, 0.9, 1.0, 0.9, 0.3)
        else
            self:drawRectBorder(self.gridPadding, self.gridPadding, self.width - (self.gridPadding*2), self.headerH - 4, 0.8, 0.3, 0.3, 0.3)
        end
        
        local text = ""
        local invItem = self.containerItem
        if not invItem and self.inventoryContainer then
            invItem = self.inventoryContainer:getContainingItem()
        end
        
        local tex = nil
        if invItem then
            text = invItem:getName()
            tex = invItem:getTexture()
        elseif self.inventoryContainer then
            local invType = self.inventoryContainer:getType()
            if invType == "floor" then
                text = getTextOrNull("IGUI_ContainerTitle_floor") or "Floor"
            elseif invType == "inventory" or invType == "none" then
                text = getTextOrNull("IGUI_InventoryTooltip") or "Inventory"
            else
                text = getTextOrNull("IGUI_ContainerTitle_" .. tostring(invType)) or invType
            end
            tex = self.fallbackIcon
        end
        
        -- No CHÃO as grids extras são janelas de chão REAIS (não overflow 1x1):
        -- o título continua "Floor" em todas, nunca "(Overflow)".
        local isFloorTitle = self.inventoryContainer
            and self.inventoryContainer:getType() == "floor"
        if self.gridIndex and self.gridIndex > 1 and not isFloorTitle then
            text = text .. " (Overflow)"
        end
        
        local textX = self.gridPadding + 5
        if tex then
            local texS = math.floor(20 * self.uiScale)
            local centerY = self.gridPadding + ((self.headerH - 4) / 2)
            local texYOffset = math.floor(centerY - (texS / 2))
            self:drawTextureScaledAspect(tex, textX, texYOffset, texS, texS, 1, 1, 1, 1)
            textX = textX + texS + 5
        end

        -- ── PESO: calcula o TEXTO e a COR antes de desenhar qualquer coisa,
        -- só pra saber a largura que ele vai ocupar (ainda não desenha na tela).
        -- O DISPLAY mantém o getMaxWeight() (a capacidade "confortável" do
        -- personagem, ex.: 12) — é o que o jogador enxerga no vanilla.
        local weightStr = nil
        local weightR, weightG, weightB = 0.9, 0.9, 0.9
        local hasWeightDisplay = self.inventoryContainer and self.inventoryContainer.getCapacityWeight and self.inventoryContainer.getMaxWeight

        if hasWeightDisplay then
            local w = self.inventoryContainer:getCapacityWeight()
            local mw = self.inventoryContainer:getMaxWeight()

            weightStr = formatWeight(w) .. " / " .. string.format("%d", mw)

            local ratio = 0
            if mw and mw > 0 then
                ratio = w / mw
                if ratio > 1 then ratio = 1 end
                if ratio < 0 then ratio = 0 end
            end

            -- Só começa a colorir a partir de 70%. Abaixo disso, fica 100% branco.
            local THRESHOLD = 0.7
            local colorRatio = 0
            if ratio > THRESHOLD then
                colorRatio = (ratio - THRESHOLD) / (1 - THRESHOLD)
            end

            local baseR, baseG, baseB = 0.9, 0.9, 0.9
            local hotR, hotG, hotB = 1.0, 0.15, 0.15
            weightR = baseR + (hotR - baseR) * colorRatio
            weightG = baseG + (hotG - baseG) * colorRatio
            weightB = baseB + (hotB - baseB) * colorRatio
        end

        -- Reserva o espaço que o texto de peso vai ocupar de verdade (medido, não estimado)
        local font = UIFont.Small
        if self.uiScale >= 1.5 then
            font = UIFont.Large
        elseif self.uiScale >= 1.25 then
            font = UIFont.Medium
        end
        
        local centerY = self.gridPadding + ((self.headerH - 4) / 2)
        local fontH = getTextManager():MeasureStringY(font, "A")
        local textYOffset = math.floor(centerY - (fontH / 2))

        local weightReservedWidth = 0
        if weightStr then
            weightReservedWidth = getTextManager():MeasureStringX(font, weightStr) + 10
        end

        -- ── NOME: agora que já sabemos quanto espaço sobra, trunca e desenha.
        local titleMaxWidth = (self.width - self.gridPadding - 5) - textX - weightReservedWidth
        local displayText = truncateText(text, titleMaxWidth, font)
        self:drawText(displayText, textX, textYOffset, 0.9, 0.9, 0.9, 1, font)

        -- ── PESO: desenha por último, já com texto e cor prontos de antes.
        if weightStr then
            local rightX = self.width - self.gridPadding - 5
            self:drawTextRight(weightStr, rightX, textYOffset, weightR, weightG, weightB, 1, font)
        end

        -- ── BUSCA (Tarkov): aviso "Vasculhar (X)" no header enquanto houver
        -- pilhas ocultas. Desenhado à esquerda do peso, em âmbar.
        if self:needsSearch() then
            local hidden = GridInventory_Search.countHiddenStacks(self.playerNum, self:searchKey(), self.inventoryContainer)
            local searchText = getText("IGUI_GridSearch") or "Search"
            if hidden and hidden > 0 then
                searchText = searchText .. " (" .. tostring(hidden) .. ")"
            end
            local sw = getTextManager():MeasureStringX(UIFont.Small, searchText)
            local rightX = self.width - self.gridPadding - 5
            if weightStr then
                rightX = rightX - (getTextManager():MeasureStringX(UIFont.Small, weightStr) + 10)
            end
            self:drawTextRight(searchText, rightX, self.gridPadding + 4, 1.0, 0.75, 0.3, 1, UIFont.Small)
        end
    end

    -- Desenha a malha do grid (os quadrados de cada slot)
    for col = 1, self.gridCore.width do
        for row = 1, self.gridCore.height do
            local cellX = self.gridPadding + ((col - 1) * self.cellSize)
            local cellY = self.gridPadding + (self.headerH or 0) + ((row - 1) * self.cellSize)
            
            -- Mantém a transparência natural preta, desenhando APENAS a borda
            self:drawRectBorder(cellX, cellY, self.cellSize, self.cellSize, 0.15, 0.5, 0.5, 0.5)
        end
    end

    local playerObj = getSpecificPlayer(self.playerNum)
    local hotbar = getPlayerHotbar(self.playerNum)
    local locked = self.inventoryContainer
        and GridInventory_BagDrop.isNestedLocked(self.inventoryContainer, playerObj)

    -- BUSCA de container do mundo (estilo Tarkov): se a opção está ligada e o
    -- container precisa ser vasculhado, itens não identificados ficam ocultos.
    -- self.searchKey = chave estável do container (nil = nunca oculta: chão/
    -- inventário). self.searchPending = tem item oculto agora.
    local searchKey = nil
    local searchPending = false
    if GridSandboxOptions.isSearchWorldContainers() and self.inventoryContainer then
        searchKey = GridInventory_Search.containerKey(self.inventoryContainer, playerObj)
        if searchKey then
            searchPending = GridInventory_Search.hasHiddenItems(self.playerNum, searchKey, self.inventoryContainer)
        end
    end

    -- Membros de pilha: mesmo sem render individual, precisam do tick de
    -- idade/umidade (o vanilla faz isso ao renderizar itens em containers
    -- visíveis). Só o LÍDER desenha o ícone.
    for itemId, data in pairs(self.gridCore.items) do
        -- Membros de pilha não são desenhados individualmente: só o LÍDER
        -- renderiza (ícone + badge de contagem). As células apontam pro líder.
        -- (Passo único: o tick de age/wetness do membro de pilha roda aqui,
        -- dentro do mesmo loop do líder — antes eram 2 passes de pairs().)
        if data.stackMemberOf then
            if data.itemObj then
                if data.itemObj.updateAge then data.itemObj:updateAge() end
                if data.itemObj.updateWetness then data.itemObj:updateWetness() end
            end
            -- skip render
        else
        if GridInventory_Profiler and GridInventory_Profiler.enabled then
            GridInventory_Profiler.count("items")
        end

        -- Se estivermos arrastando, não renderizamos o item localmente se for um dos arrastados.
        local isDragged = GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid == self and GridInventory_GlobalDrag.itemsMap[itemId]
        
        if not isDragged then
            local drawX = self.gridPadding + ((data.x - 1) * self.cellSize)
            local drawY = self.gridPadding + (self.headerH or 0) + ((data.y - 1) * self.cellSize)
            
            local drawW = data.w * self.cellSize
            local drawH = data.h * self.cellSize

            local isSelected = self.selectedItems[itemId]

            if data.itemObj then
                -- B42/B41 Fix: O motor do Zomboid delega o tick de idade e umidade das roupas e comidas à renderização da UI (se estiver num container visível).
                -- Como pulamos o renderdetails do Vanilla, temos que disparar o update nós mesmos!
                if data.itemObj.updateAge then data.itemObj:updateAge() end
                if data.itemObj.updateWetness then data.itemObj:updateWetness() end
                
                local bgR, bgG, bgB, bgA = ITEM_BG_COLOR.r, ITEM_BG_COLOR.g, ITEM_BG_COLOR.b, ITEM_BG_COLOR.a
                
                -- Cor de base vem da CATEGORIA do item (estilo Tetris): armas
                -- roxo, comida vermelho, munição laranja, etc. MISC mantém o cinza.
                local category = ItemCategory.getCategory(data.itemObj)
                local catColor = ItemCategory.getColorByCategory(category)
                bgR, bgG, bgB = catColor.r, catColor.g, catColor.b
                
                -- Checa se está congelado ou quente
                local heat = 1
                if data.itemObj.getHeat then heat = data.itemObj:getHeat()
                elseif data.itemObj.getItemHeat then heat = data.itemObj:getItemHeat() end
                
                local invHeat = 0
                if data.itemObj.getInvHeat then invHeat = math.abs(data.itemObj:getInvHeat()) end
                if invHeat > 1 then invHeat = 1 end
                
                local freezeTime = 0
                if data.itemObj.getFreezingTime then freezeTime = data.itemObj:getFreezingTime() / 100 end
                if freezeTime > 1 then freezeTime = 1 end
                
                -- Estado de temperatura SOBREPÕE a categoria: item frio/quente usa
                -- a cor interpolada sólida (sem degrade) pra destacar o estado.
                local tempState = false
                if (data.itemObj.isFrozen and data.itemObj:isFrozen()) or freezeTime > 0 or heat < 0.99 then
                    -- Frio / Congelando
                    local t = math.max(freezeTime, invHeat)
                    if data.itemObj.isFrozen and data.itemObj:isFrozen() then t = 1.0 end
                    
                    bgR = ITEM_BG_COLOR.r + (ITEM_BG_FROZEN.r - ITEM_BG_COLOR.r) * t
                    bgG = ITEM_BG_COLOR.g + (ITEM_BG_FROZEN.g - ITEM_BG_COLOR.g) * t
                    bgB = ITEM_BG_COLOR.b + (ITEM_BG_FROZEN.b - ITEM_BG_COLOR.b) * t
                    tempState = true
                elseif heat > 1.01 then
                    -- Quente
                    local t = invHeat
                    bgR = ITEM_BG_COLOR.r + (ITEM_BG_HOT.r - ITEM_BG_COLOR.r) * t
                    bgG = ITEM_BG_COLOR.g + (ITEM_BG_HOT.g - ITEM_BG_COLOR.g) * t
                    bgB = ITEM_BG_COLOR.b + (ITEM_BG_HOT.b - ITEM_BG_COLOR.b) * t
                    tempState = true
                end
                
                -- Fundo: DEGRADE vertical neutro (topo) → categoria (base), ou
                -- cor sólida quando em estado de temperatura. Selecionado ganha
                -- um leve clareamento pra não sumir sob o destaque.
                if isSelected then
                    local sR, sG, sB = math.min(1, bgR + SEL_BRIGHTEN), math.min(1, bgG + SEL_BRIGHTEN), math.min(1, bgB + SEL_BRIGHTEN)
                    if tempState then
                        self:drawRect(drawX, drawY, drawW, drawH, bgA + SEL_BRIGHTEN, sR, sG, sB)
                    else
                        for _, band in ipairs(ItemCategory.getGradient(data.itemObj, drawH)) do
                            self:drawRect(drawX, drawY + band.y, drawW, band.h, bgA + SEL_BRIGHTEN, math.min(1, band.r + SEL_BRIGHTEN), math.min(1, band.g + SEL_BRIGHTEN), math.min(1, band.b + SEL_BRIGHTEN))
                        end
                    end
                else
                    if tempState then
                        self:drawRect(drawX, drawY, drawW, drawH, bgA, bgR, bgG, bgB)
                    else
                        for _, band in ipairs(ItemCategory.getGradient(data.itemObj, drawH)) do
                            self:drawRect(drawX, drawY + band.y, drawW, band.h, bgA, band.r, band.g, band.b)
                        end
                    end
                end

                -- BUSCA: item oculto → slot do footprint bem escuro (quase se
                -- funde com a silhueta, mas alpha alto cobre o degrade por baixo).
                if searchPending and self:isItemHidden(data.itemObj) then
                    self:drawRect(drawX, drawY, drawW, drawH, 0.85, 0.12, 0.12, 0.12)
                end
                
                -- Borda: DEGRADE por faixa (mesma cor do fundo) quando a
                -- categoria tem cor; MISC usa um degrade SUTIL (neutro → slot
                -- vazio, quase imperceptível). Estado de temperatura: borda
                -- SÓLIDA na cor do ESTADO (bgR/G/B = azul frio / vermelho
                -- quente) — acompanha o fundo em vez de brigar com ele.
                if tempState then
                    self:drawRectBorder(drawX, drawY, drawW, drawH, 1, bgR, bgG, bgB)
                elseif category ~= ItemCategory.MISC then
                    local bands = ItemCategory.getGradient(data.itemObj, drawH)
                    drawGradientBorder(self, drawX, drawY, drawW, drawH, bands, 1, isSelected and SEL_BRIGHTEN or 0)
                else
                    local bands = ItemCategory.getSubtleGradient(drawH)
                    drawGradientBorder(self, drawX, drawY, drawW, drawH, bands, 1, isSelected and SEL_BRIGHTEN or 0)
                end
                -- BUSCA (Tarkov): item não identificado → SPRITE VIRA SILHUETA
                -- PRETA (tint 0,0,0 no próprio sprite, não retângulo por cima):
                -- esconde o conteúdo mas mantém a forma — e o slot fica claro
                -- pra dar contraste. Ícones de status também suprimidos (não
                -- revelam info de item oculto).
                local itemHidden = searchPending and self:isItemHidden(data.itemObj)
                -- Unwanted (b42, por jogador): o vanilla escurece o nome da linha
                -- do item; no grid o mesmo feedback vira o ÍCONE escurecido.
                -- Busca oculta ganha (sprite 100% preto, não revela info).
                local iconR, iconG, iconB, iconA = 1, 1, 1, 1
                if itemHidden then
                    iconR, iconG, iconB = 0, 0, 0
                elseif playerObj and data.itemObj.isUnwanted and data.itemObj:isUnwanted(playerObj) then
                    iconR, iconG, iconB, iconA = 0.55, 0.55, 0.55, 0.85
                end
                self:drawItemIconRotated(data.itemObj, drawX, drawY, drawW, drawH, data.rotated, iconR, iconG, iconB, iconA, GridIconRotation.getRenderAngle(data.itemObj))
                
                -- ── Ícones de status (sistema flex) ─────────────────────────────────
                if not itemHidden then
                    self:drawItemStatusIcons(data.itemObj, drawX + 2, drawY + 2, playerObj, hotbar)
                end

                -- BUSCA: interrogação nativa do PZ no centro do footprint, POR
                -- CIMA da silhueta preta — reforça "não identificado".
                if itemHidden then
                    local qTex = GridInventory_QuestionTex
                    if qTex then
                        local qSize = math.min(drawW, drawH) * 0.5
                        local qx = drawX + (drawW - qSize) / 2
                        local qy = drawY + (drawH - qSize) / 2
                        self:drawTextureScaled(qTex, qx, qy, qSize, qSize, 1, 1, 1, 0.9)
                    end
                else
                    -- DESCOBERTA (Tarkov): item acabou de ser revelado pela busca.
                    -- Wipe BRANCO subindo de baixo pra cima no footprint, ~350ms.
                    -- O lookup é O(1) e só roda pra itens já visíveis (o hot path
                    -- dos ocultos continua intocado). A limpeza é lazy (expira
                    -- sozinha na consulta), sem custo por frame.
                    -- SÓ renderiza quando este grid é de um container do mundo
                    -- com busca habilitada (searchKey ~= nil = não é inv do
                    -- jogador nem chão; e a option ligada). Usar "searchPending"
                    -- aqui cortaria o wipe do ÚLTIMO item revelado (aí não há
                    -- mais ocultos). Sem a guarda, um revealAnim residual faria
                    -- o wipe aparecer no inventário do jogador mesmo com a
                    -- opção de busca DESLIGADA.
                    local revealP = searchKey and GridInventory_Search.getRevealProgress(data.itemObj:getID())
                    if revealP then
                        -- revealP 0→1: a borda do wipe sobe; abaixo dela, um
                        -- preenchimento branco translúcido "revela" o item.
                        local wipeH = drawH * (1 - revealP)
                        local wipeY = drawY + drawH - wipeH
                        -- Base do wipe (abaixo da borda): cobertura branca
                        -- esmaecida que desce conforme o wipe sobe.
                        self:drawRect(drawX, wipeY, drawW, wipeH, 0.35 * (1 - revealP), 1, 1, 1)
                        -- Borda frontal do wipe: linha branca brilhante.
                        self:drawRect(drawX, wipeY, drawW, 2, 0.9, 1, 1, 1)
                    end
                end
                
                -- Feedback visual de falta de espaço
                if data.outOfSpaceTimer then
                    if getTimeInMillis() < data.outOfSpaceTimer then
                        self:drawRect(drawX, drawY, drawW, drawH, 0.7, 0.2, 0.05, 0.05)
                        self:drawTextCentre(getText("IGUI_InventoryFull") or "Out of space", drawX + drawW/2, drawY + drawH/2 - 10, 1, 1, 1, 1, UIFont.Small)
                    else
                        data.outOfSpaceTimer = nil
                    end
                end
                
                -- Barra de progresso da ação (preenchendo de baixo pra cima)
                if data.itemObj.getJobDelta then
                    local jobDelta = data.itemObj:getJobDelta()
                    if jobDelta > 0 then
                        local fillH = drawH * jobDelta
                        local fillY = drawY + drawH - fillH
                        -- Verde translúcido: a=0.4, r=0.2, g=0.8, b=0.2
                        self:drawRect(drawX, fillY, drawW, fillH, 0.4, 0.2, 0.8, 0.2)
                    end
                end

                -- Badge de contagem da pilha (total de unidades = nº de OBJETOS
                -- empilhados: 100 pregos, 50 9mm, 12 twines). Cada objeto = 1
                -- unidade (o B42 conta o objeto — o count do script é vestigial).
                -- Mostra a partir de 2 unidades pra não poluir item solto.
                local pileUnits = self.gridCore:getPileUnits(itemId)
                -- Durante um drag SAINDO deste grid (peel do joypad/mouse), o
                -- cache do gridCore ainda conta os membros em trânsito. Subtrai
                -- eles pra o badge refletir o que AINDA está na pilha
                -- (10 canecas, levantou 2 → badge mostra 8).
                if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid == self
                    and GridInventory_GlobalDrag.itemsMap then
                    local transit = 0
                    for mId in pairs(GridInventory_GlobalDrag.itemsMap) do
                        local mData = self.gridCore.items[mId]
                        if mData and mData.stackMemberOf == itemId then
                            transit = transit + 1
                        end
                    end
                    if transit > 0 then
                        pileUnits = pileUnits - transit
                    end
                end
                if pileUnits > 1 then
                    self:drawStackCountBadge(itemId, drawX, drawY, drawW, drawH, pileUnits)
                end

                -- FLASH de autoSlot: item recém-entrado SEM posição (autoSort/
                -- auto-fit) pisca amarelo no footprint — feedback "olha, caiu
                -- aqui". Mesma cor do flash de container selecionado. Decai e
                -- some sozinho (~1s). Só o LÍDER desenha (membros não renderizam).
                if not data.stackMemberOf and GridInventory_AutoSlotFlash
                    and GridInventory_AutoSlotFlash[itemId] then
                    local FLASH_MS = 1000
                    local elapsed = getTimeInMillis() - GridInventory_AutoSlotFlash[itemId]
                    if elapsed >= FLASH_MS then
                        GridInventory_AutoSlotFlash[itemId] = nil
                    else
                        local a = 1 - (elapsed / FLASH_MS)
                        self:drawRect(drawX, drawY, drawW, drawH, a * 0.25, 1.0, 0.9, 0.3)
                        self:drawRectBorder(drawX, drawY, drawW, drawH, a, 1.0, 0.9, 0.3)
                    end
                end
            end
        end
    end
    end

    if self.gridCore.ghostItems then
        for gId, gData in pairs(self.gridCore.ghostItems) do
            local drawX = self.gridPadding + ((gData.x - 1) * self.cellSize)
            local drawY = self.gridPadding + (self.headerH or 0) + ((gData.y - 1) * self.cellSize)
            local drawW = gData.w * self.cellSize
            local drawH = gData.h * self.cellSize
            
            -- Fundo translúcido cinza para indicar fantasma
            self:drawRect(drawX, drawY, drawW, drawH, 0.3, 0.5, 0.5, 0.5)
            self:drawRectBorder(drawX, drawY, drawW, drawH, 0.5, 0.7, 0.7, 0.7)
            
            if gData.itemObj then
                -- Desenha o item com 50% de opacidade
                self:drawItemIconRotated(gData.itemObj, drawX, drawY, drawW, drawH, gData.rotated, 1, 1, 1, 0.5, GridIconRotation.getRenderAngle(gData.itemObj))
            end
        end
    end

    if self.draggingMarquis then
        local mX = self:getMouseX()
        local mY = self:getMouseY()
        
        local rx = math.min(self.marquisStartX, mX)
        local ry = math.min(self.marquisStartY, mY)
        local rw = math.abs(mX - self.marquisStartX)
        local rh = math.abs(mY - self.marquisStartY)
        
        self:drawRectBorder(rx, ry, rw, rh, 1, 1.0, 1.0, 1.0)
        self:drawRect(rx, ry, rw, rh, 0.2, 1.0, 1.0, 1.0)
    end

    -- Preview do drop sob o cursor (verde/vermelho) durante o arrasto
    -- (Grid travado: nada de preview/put-in — o overlay de lock cobre tudo).
    if not locked then
        self:drawDropPreview()

        -- Feedback de put-in: destaque verde + "Put in" sobre o footprint de bolsa
        -- que aceita o drag (desenha no espaço local do grid, scroll incluso).
        GridInventory_BagDrop.drawPutInFeedback(self)
    end

    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.itemsData and #GridInventory_GlobalDrag.itemsData > 0 and not locked then
        local firstItem = GridInventory_GlobalDrag.itemsData[1].itemObj
        if firstItem and self.inventoryContainer then
            local playerObj = getSpecificPlayer(self.playerNum)

            -- Capacidade de peso com matemática PRÓPRIA e precisa:
            --  - limite = getEffectiveCapacity (o MESMO do hasRoomFor / teto real,
            --    ex.: 50 no inventário do jogador), NÃO getMaxWeight (que é o
            --    "confortável" baseado em força, ex.: 12 — dispara Overloaded cedo);
            --  - itens arrastados que JÁ estão na árvore do container alvo (ex.:
            --    tirar de dentro de uma bolsa pra raiz) já estão somados no
            --    getCapacityWeight() → não podem ser somados de novo, senão o
            --    "Sobrepeso" aparece ANTES de bater o peso máximo.
            local capacity = gridCapacity(self.inventoryContainer, playerObj)
            local currentWeight = self.inventoryContainer.getCapacityWeight and self.inventoryContainer:getCapacityWeight() or self.inventoryContainer:getContentsWeight()
            local addWeight = 0
            for _, d in ipairs(GridInventory_GlobalDrag.itemsData) do
                local obj = d and d.itemObj
                if obj and obj.getUnequippedWeight and not isInContainerTree(obj, self.inventoryContainer) then
                    addWeight = addWeight + (tonumber(obj:getUnequippedWeight()) or 0)
                end
            end
            local afterWeight = (currentWeight or 0) + addWeight
            local weightOver = capacity and afterWeight > capacity

            -- Quantos itens arrastados cabem por PESO (pra mensagem "parcial":
            -- algum entra, mas não todos). Só conta os que NÃO já estão na árvore
            -- (itens já dentro do inventário não mudam o peso total ao mover).
            -- Também detecta se QUALQUER item arrastado já está na árvore: nesse
            -- caso o hasRoomFor vanilla CONTA O PESO 2x (item + inventário) e
            -- retorna false indevidamente → não dá pra usar ele como sinal de
            -- "Selective Container".
            local totalToAdd = 0
            local fitsToAdd = 0
            local anyInTree = false
            if capacity and (currentWeight or 0) <= capacity then
                local room = capacity - (currentWeight or 0)
                for _, d in ipairs(GridInventory_GlobalDrag.itemsData) do
                    local obj = d and d.itemObj
                    if obj and obj.getUnequippedWeight then
                        if isInContainerTree(obj, self.inventoryContainer) then
                            anyInTree = true
                        else
                            totalToAdd = totalToAdd + 1
                            local w = tonumber(obj:getUnequippedWeight()) or 0
                            if room >= w then
                                fitsToAdd = fitsToAdd + 1
                                room = room - w
                            end
                        end
                    end
                end
            end

            -- Favorito: protege item de sair do inventário do jogador
            local isInPlayerInv = self.inventoryContainer:isInCharacterInventory(playerObj)
            -- BUSCA (Tarkov): container com itens ocultos → NÃO dá pra soltar
            -- nada dentro (o drop seria bloqueado no mouseUp). Mostra "Search
            -- First" em vez dos feedbacks normais, que seriam enganosos.
            if self:needsSearch() then
                self:drawRect(0, 0, self.width, self.height, 0.7, 0.2, 0.05, 0.05)
                self:drawTextCentre(getText("IGUI_SearchFirst") or "Search First", self.width/2, self.height/2 - 10, 1, 1, 0.8, 0.3, UIFont.Large)
            elseif firstItem.isFavorite and firstItem:isFavorite() and not isInPlayerInv then
                self:drawRect(0, 0, self.width, self.height, 0.7, 0.2, 0.05, 0.05)
                self:drawTextCentre(getText("IGUI_FavoriteProtected") or "Item is Favorited", self.width/2, self.height/2 - 10, 1, 1, 0.8, 0.2, UIFont.Large)
            
            -- Verifica se tentou colocar o container dentro dele mesmo
            elseif firstItem == self.containerItem then
                self:drawRect(0, 0, self.width, self.height, 0.7, 0.2, 0.05, 0.05)
                self:drawTextCentre(getText("IGUI_CannotStoreItself") or "Cannot store itself", self.width/2, self.height/2 - 10, 1, 0.2, 0.2, 1, UIFont.Large)
            
                -- Verifica se o container rejeita o item categoricamente
            elseif not self.inventoryContainer:isItemAllowed(firstItem) then
                self:drawRect(0, 0, self.width, self.height, 0.7, 0.2, 0.05, 0.05)
                self:drawTextCentre(getText("IGUI_CantStore") or "Cannot Store", self.width/2, self.height/2 - 10, 1, 0.2, 0.2, 1, UIFont.Large)

            -- "Sobrepeso" SÓ quando o peso vai estourar de verdade. Se for
            -- PARCIAL (algum item/pilha entra, mas não todos), mostra isso no
            -- texto em vez de "Sobrecarregado" (que soa como se NADA fosse
            -- entrar). Vale até pra pilha única — o número informa quantos
            -- entram mesmo quando o drop é tudo-ou-nada.
            elseif weightOver then
                self:drawRect(0, 0, self.width, self.height, 0.7, 0.2, 0.05, 0.05)
                local msg = getText("IGUI_Overloaded") or "Overloaded"
                if fitsToAdd > 0 and fitsToAdd < totalToAdd then
                    -- O getText do jogo stringifica os args antes do format →
                    -- %d explodiria (IllegalFormatConversionException); passar
                    -- tostring explícito + %s nas traduções é à prova de bala.
                    msg = getText("IGUI_OverloadedPartial", tostring(fitsToAdd), tostring(totalToAdd))
                        or ("Only " .. tostring(fitsToAdd) .. " of " .. tostring(totalToAdd) .. " fit")
                end
                self:drawTextCentre(msg, self.width/2, self.height/2 - 10, 1, 0.2, 0.2, 1, UIFont.Large)

            -- Cabe no peso, mas o hasRoomFor vanilla ainda recusa. Só confiamos
            -- nele quando NENHUM item arrastado já está na árvore do container
            -- alvo (senão ele conta o peso 2x e recusa por engano).
            -- CHÃO: o hasRoomFor vanilla é por QUADRADO (getEffectiveCapacity=50),
            -- mas nosso grid agrega vários quadrados (teto real 100) → pular o
            -- check aqui: o weightOver acima (gridCapacity=100) já cobre o peso.
            elseif not anyInTree and self.inventoryContainer:getType() ~= "floor" and not self.inventoryContainer:hasRoomFor(playerObj, firstItem) then
                self:drawRect(0, 0, self.width, self.height, 0.7, 0.2, 0.05, 0.05)
                self:drawTextCentre(getText("IGUI_ContainerRestricted") or "Selective Container", self.width/2, self.height/2 - 10, 1, 0.2, 0.2, 1, UIFont.Large)

            -- Verifica se há espaço matemático no Grid
            else
                local hasGridSpace = false
                local gridContainer = GridContainer.instances[self.inventoryContainer]
                if gridContainer then
                    local w, h = ItemFootprint.getSize(firstItem)
                    -- Empilháveis: passa compatKey/stackInfo pro findFreeSpace
                    -- enxergar TAMBÉM pilha compatível existente (mesmo com o
                    -- grid sem célula livre) — evita "Sem Espaço" falso em drop.
                    local compatKey, stackInfo = GridContainer.getStackInfo(firstItem)
                    for _, grid in ipairs(gridContainer.grids) do
                        local fx, fy = grid:findFreeSpace(firstItem:getID(), w, h, compatKey, stackInfo, false)
                        if not fx then fx, fy = grid:findFreeSpace(firstItem:getID(), h, w, compatKey, stackInfo, true) end
                        if fx and fy then
                            hasGridSpace = true
                            break
                        end
                    end
                else
                    hasGridSpace = true -- Fallback se a malha não tiver inicializado (raro)
                end
                if not hasGridSpace then
                    self:drawRect(0, 0, self.width, self.height, 0.7, 0.2, 0.05, 0.05)
                    self:drawTextCentre(getText("IGUI_NoGridSpace") or "No Space", self.width/2, self.height/2 - 10, 1, 0.2, 0.2, 1, UIFont.Large)
                else
                    local isFromPaperDoll = GridInventory_GlobalDrag.sourceGrid and GridInventory_GlobalDrag.sourceGrid.slotName
                    if isFromPaperDoll then
                        if isInPlayerInv then
                            self:drawRect(0, 0, self.width, self.height, 0.7, 0.1, 0.1, 0.1)
                            self:drawTextCentre(getText("IGUI_Unequip") or "Unequip", self.width/2, self.height/2 - 10, 1, 0.3, 0.3, 1, UIFont.Large)
                        end
                    end
                end
            end
        end
    end

    -- Grid travado (bolsa aninhada NO MUNDO): escurece o grid inteiro + cadeado.
    -- "Meio apagada" = o conteúdo continua visível (só leitura), mas fica claro
    -- que o engine não deixa mexer (sem drag in/out, sem put-in, sem autoSlot).
    if locked then
        self:drawRect(0, 0, self.width, self.height, 0.55, 0.15, 0.15, 0.15)
        self:drawRectBorder(0, 0, self.width, self.height, 0.9, 1.0, 0.85, 0.3)
        self:drawTextCentre(getText("IGUI_LockedNestedBag") or "Locked", self.width/2, self.height/2 - 10, 1.0, 0.9, 0.6, 1, UIFont.Large)
    end

    -- Cursor de joypad + prompts de botão (só quando este grid é o dono do
    -- cursor e o painel tem foco do controle). Desenhado por ÚLTIMO: por cima
    -- dos itens, do overlay de peso e do cadeado, pra nunca ficar escondido.
    self:renderJoypadCursor()
end

-- Cursor virtual do joypad: destaca o footprint do item sob o cursor e
-- desenha uma moldura na célula do cursor (HUD contextual de controle).
function GridRender:renderJoypadCursor()
    if not GridJoypad.isCursorOn(self) then return end
    local cursor = GridJoypad.cursors[self.playerNum]
    if not cursor or not cursor.col or not cursor.row then return end

    local col, row = cursor.col, cursor.row
    local x = self.gridPadding + ((col - 1) * self.cellSize)
    local y = self.gridPadding + (self.headerH or 0) + ((row - 1) * self.cellSize)

    -- Footprint inteiro do item sob o cursor (se houver) — destaque verde.
    -- Durante um DRAG de joypad NÃO destaca o item sob o cursor (não é seleção;
    -- só o preview verde/vermelho + o ghost mostram onde o item segurado cai).
    local onFootprint = false
    local fp = nil
    local id = nil
    if not GridJoypad.isDragging(self.playerNum) then
        id = self.gridCore.cells[col] and self.gridCore.cells[col][row]
        if id then
            local d = self.gridCore.items[id]
            if d and d.itemObj and not d.stackMemberOf then
                onFootprint = true
                fp = d
                local w = d.w * self.cellSize
                local h = d.h * self.cellSize
                local ix = self.gridPadding + ((d.x - 1) * self.cellSize)
                local iy = self.gridPadding + (self.headerH or 0) + ((d.y - 1) * self.cellSize)
                self:drawRect(ix, iy, w, h, 0.25, 1.0, 0.95, 0.35)
                self:drawRectBorder(ix, iy, w, h, 1.0, 1.0, 0.95, 0.35)
            end
        end
    end

    -- Moldura da célula do cursor: SÓ quando não está sobre um footprint — o
    -- item já mostra o destaque verde com borda; a moldura branca de 1 célula
    -- ficava "cortando" os slots do footprint. Durante um DRAG de joypad a
    -- moldura 1x1 também some — o preview verde/vermelho + o ghost mostram o
    -- tamanho REAL do footprint segurado no cursor.
    if not onFootprint and not GridJoypad.isDragging(self.playerNum) then
        self:drawRectBorder(x, y, self.cellSize, self.cellSize, 0.9, 1.0, 1.0, 1.0)
    end
end

-- Ícones de botão (A/B/X) logo abaixo da célula do cursor: o "o que cada
-- botão faz" do grid. Y não é renderizado (só fecha o inventário). Usa as
-- texturas nativas do jogo (Joypad.Texture.*).
function GridRender:drawJoypadPrompts(cellX, cellY)
    if not Joypad or not Joypad.Texture then return end
    local buttons = {
        Joypad.Texture.AButton,
        Joypad.Texture.BButton,
        Joypad.Texture.XButton,
    }
    local size = math.max(14, math.floor(self.cellSize * 0.5))
    local gap = 3
    local pad = 3
    local n = #buttons
    local totalW = n * size + (n - 1) * gap + pad * 2
    local bx = cellX - pad
    local by = cellY + self.cellSize + 3
    -- Fundo escuro da "pill" (A/B/X/Y juntos, como o HUD do vanilla).
    self:drawRect(bx, by, totalW, size + pad * 2, 0.7, 0, 0, 0)
    self:drawRectBorder(bx, by, totalW, size + pad * 2, 0.8, 1, 1, 1)
    for i, getter in ipairs(buttons) do
        local tex = getter and getter.getTexture and getter:getTexture()
        if tex then
            local tx = bx + pad + (i - 1) * (size + gap)
            self:drawTextureScaled(tex, tx, by + pad, size, size, 1, 1, 1, 1)
        end
    end
end
-- SISTEMA DE DRAG AND DROP E CONTEXT MENU
-- ============================================================================

function GridRender:getGridCellAtMouse(x, y)
    local col = math.floor((x - self.gridPadding) / self.cellSize) + 1
    local row = math.floor((y - self.gridPadding - (self.headerH or 0)) / self.cellSize) + 1
    if col >= 1 and col <= self.gridCore.width and row >= 1 and row <= self.gridCore.height then
        return col, row
    end
    return nil, nil
end

-- Preview de drop: enquanto um drag global está ativo, pinta o footprint que o
-- item arrastado ocuparia se soltar na célula sob o cursor. Verde sutil = drop
-- válido EXATAMENTE ali; vermelho = inválido no cursor (o drop real auto-encaixa
-- no primeiro espaço livre — indica onde com um contorno verde). Só para item
-- ÚNICO ou pilha (uma unidade lógica, um footprint). Multi-drag de células
-- diferentes não desenha preview (o drop é auto-sort) — o ghost mantém o fundo.
-- Quando o preview é desenhado, publica GridInventory_DropPreview pra
-- GlobalDragRender renderizar o ghost "cru" (sem fundo/borda). O preview é
-- zerado no prerender da GlobalDragRender e reposto a cada frame por quem
-- estiver sob o cursor — nunca é "stale" de um frame anterior.
function GridRender:drawDropPreview()
    if not GridInventory_GlobalDrag or not GridInventory_GlobalDrag.itemsData then return end
    local itemsData = GridInventory_GlobalDrag.itemsData
    if #itemsData == 0 then return end

    -- PUT-IN: mouse sobre o footprint de uma bolsa que ACEITA o drag → o preview
    -- de posicionamento (verde/vermelho do item) cede lugar ao destaque verde da
    -- bolsa (drawPutInFeedback) — dois verdes competindo confundiriam. Se a bolsa
    -- NÃO aceita, o preview normal continua (o drop é de grid, não de put-in).
    -- Só no drag de MOUSE (o joypad usa o cursor virtual).
    if not (GridInventory_GlobalDrag and GridInventory_GlobalDrag.joypad) then
        local bagAtPoint = GridInventory_BagDrop.bagAtPoint(self)
        if bagAtPoint and GridInventory_BagDrop.canTransfer(bagAtPoint) then
            return
        end
    end

    local dropCol, dropRow
    if GridInventory_GlobalDrag.joypad then
        -- Drag de joypad: o preview segue o CURSOR virtual (só no grid dele).
        local cursor = GridJoypad.cursors[self.playerNum]
        if not cursor or cursor.grid ~= self or not cursor.col or not cursor.row then return end
        dropCol, dropRow = cursor.col, cursor.row
    else
        dropCol, dropRow = self:getGridCellAtMouse(self:getMouseX(), self:getMouseY())
        if not dropCol or not dropRow then return end
    end

    -- Multi-drag real (itens em células de origem diferentes): sem footprint
    -- único e sem preview por célula — o drop limpa posições e o auto-sort do
    -- container alvo empacota (o layout da origem não se preserva, então pintar
    -- o layout relativo enganaria). O overlay de peso/espaço do render() cobre
    -- o feedback de capacidade.
    if #itemsData > 1 then
        local first = itemsData[1]
        for i = 2, #itemsData do
            local d = itemsData[i]
            if d.originalX ~= first.originalX or d.originalY ~= first.originalY then
                return
            end
        end
    end

    local anchorId = GridInventory_GlobalDrag.anchorId
    local anchorData = nil
    for _, d in ipairs(itemsData) do
        if d.id == anchorId then
            anchorData = d
            break
        end
    end
    if not anchorData or not anchorData.itemObj then return end

    local fw, fh = ItemFootprint.getSize(anchorData.itemObj)
    -- Rotação = anchorData.rotated (rotação do grid, data.rotated). NÃO usar
    -- itemObj:isRotated() — a grid rotaciona visualmente via data.rotated.
    local rotated = anchorData.rotated or false
    local effectiveW = rotated and (anchorData.originalH or fh) or (anchorData.originalW or fw)
    local effectiveH = rotated and (anchorData.originalW or fw) or (anchorData.originalH or fh)

    local targetX = dropCol - (anchorData.grabOffsetX or 0)
    local targetY = dropRow - (anchorData.grabOffsetY or 0)
    if targetX < 1 then targetX = 1 end
    if targetY < 1 then targetY = 1 end

    local compatKey, stackInfo = GridContainer.getStackInfo(anchorData.itemObj)
    local ignoreSet = GridInventory_GlobalDrag.itemsMap

    -- Mesma checagem do drop real: se a célula sob o cursor não serve, o drop
    -- auto-encaixa no primeiro espaço livre (findFreeSpace) — SÓ em outro grid.
    -- No MESMO grid o drop é estrito (tudo-ou-nada, sem autoSlot): inválido =
    -- não acontece nada, então não mostra contorno de snap (evita "vai cair ali"
    -- que não é verdade).
    local valid = self.gridCore:canPlaceItem(anchorData.id, targetX, targetY,
        effectiveW, effectiveH, nil, compatKey, rotated, stackInfo, ignoreSet)

    local snapX, snapY
    if not valid and GridInventory_GlobalDrag.sourceGrid ~= self then
        snapX, snapY = self.gridCore:findFreeSpace(anchorData.id, effectiveW,
            effectiveH, compatKey, stackInfo, rotated)
    end

    -- Ghost "cru": o preview (verde/vermelho) está sendo pintado sob o cursor,
    -- então a GlobalDragRender não desenha fundo/borda por cima dele.
    GridInventory_DropPreview = { grid = self, dragRef = GridInventory_GlobalDrag }

    local px = self.gridPadding + ((targetX - 1) * self.cellSize)
    local py = self.gridPadding + (self.headerH or 0) + ((targetY - 1) * self.cellSize)
    local pw = effectiveW * self.cellSize
    local ph = effectiveH * self.cellSize

    if valid then
        -- Verde sutil: cabe exatamente onde o mouse aponta.
        self:drawRect(px, py, pw, ph, 0.28, 0.2, 0.85, 0.3)
        self:drawRectBorder(px, py, pw, ph, 0.85, 0.3, 1.0, 0.45)
    else
        -- Vermelho: não pode cair aqui. Se houver espaço livre, o drop real
        -- encaixa lá — indica com um contorno verde (só a borda, sem fundo).
        self:drawRect(px, py, pw, ph, 0.3, 0.9, 0.2, 0.2)
        self:drawRectBorder(px, py, pw, ph, 0.85, 1.0, 0.3, 0.3)
        if snapX and snapY then
            local sx = self.gridPadding + ((snapX - 1) * self.cellSize)
            local sy = self.gridPadding + (self.headerH or 0) + ((snapY - 1) * self.cellSize)
            self:drawRectBorder(sx, sy, pw, ph, 0.9, 0.3, 1.0, 0.45)
        end
    end
end

--- True se este grid está sob um painel COLAPSADO na cadeia de parents (a
--- página de inventário/loot é um ISCollapsableWindow). Nesse estado o grid
--- não pode computar NENHUM evento de mouse: o corpo do painel colapsado
--- precisa deixar o jogador mirar/clicar através dele.
function GridRender:isUnderCollapsedPage()
    local parent = self.parent
    while parent do
        if parent.isCollapsed == true then
            return true
        end
        parent = parent.parent
    end
    return false
end

function GridRender:executeModifierAction(actionId, itemId)
    local itemData = self.gridCore and self.gridCore.items[itemId]
    if not itemData then return false end
    local itemObj = itemData.itemObj
    local playerObj = getSpecificPlayer(self.playerNum)
    if not itemObj or not playerObj then return false end

    -- 1: Stack Picker / 2: Take One
    -- Ambos preparam o "peel", o drag tira 1, o release abre o picker (se for ação 1)
    if (actionId == 1 or actionId == 2) and self.gridCore:getStackSize(itemId) > 1 then
        self.ctrlStackPeel = itemId
        self.selectedItems = {}
        return false -- false permite que o onMouseDown continue preparando o drag
    end

    -- 3: Quick Transfer
    if actionId == 3 then
        local isCharacter = self.inventoryContainer and self.inventoryContainer:isInCharacterInventory(playerObj)
        -- Transfere a pilha inteira!
        local itemsToTransfer = { itemObj }
        if self.gridCore:isStackLeader(itemId) then
            itemsToTransfer = {}
            table.insert(itemsToTransfer, itemObj)
            for _, mId in ipairs(self.gridCore:getStackMembers(itemId)) do
                local mData = self.gridCore.items[mId]
                if mData and mData.itemObj then table.insert(itemsToTransfer, mData.itemObj) end
            end
        end
        
        if isCharacter then
            ISInventoryPaneContextMenu.onPutItems(itemsToTransfer, self.playerNum)
        else
            ISInventoryPaneContextMenu.onGrabItems(itemsToTransfer, self.playerNum)
        end
        self.selectedItems = {}
        return true -- Consome o clique, aborta drag
    end

    -- 4: Drop to Floor
    if actionId == 4 then
        local itemsToDrop = { itemObj }
        if self.gridCore:isStackLeader(itemId) then
            itemsToDrop = {}
            table.insert(itemsToDrop, itemObj)
            for _, mId in ipairs(self.gridCore:getStackMembers(itemId)) do
                local mData = self.gridCore.items[mId]
                if mData and mData.itemObj then table.insert(itemsToDrop, mData.itemObj) end
            end
        end
        ISInventoryPaneContextMenu.onDropItems(itemsToDrop, self.playerNum)
        self.selectedItems = {}
        return true
    end

    -- 5: Multi-Select
    if actionId == 5 then
        self.selectedItems[itemId] = not self.selectedItems[itemId]
        return true
    end

    -- 6: Disabled
    return false
end

function GridRender:onMouseDown(x, y)
    -- Painel colapsado: nenhum clique é processado pelo grid
    if self:isUnderCollapsedPage() then
        return
    end

    -- Verifica se clicou no Header!
    if self.headerH and self.headerH > 0 then
        if y >= self.gridPadding and y <= self.gridPadding + self.headerH then
            local pLoot = getPlayerLoot(self.playerNum)
            local pInv = getPlayerInventory(self.playerNum)
            local found = false
            
            for _, page in ipairs({pLoot, pInv}) do
                if page and page.backpacks and not found then
                    for _, btn in ipairs(page.backpacks) do
                        if btn.inventory == self.inventoryContainer then
                            page:selectContainer(btn)
                            found = true
                            break
                        end
                    end
                end
            end
            
            return -- Aborta o resto do clique pois foi no header
        end
    end

    -- Grid travado (bolsa aninhada no mundo): só leitura — nada de arrastar,
    -- selecionar, marquis ou double-click. O contexto (botão direito) e o
    -- duplo clique (doDoubleClick/onRightMouseUp) também são bloqueados.
    if self:isLocked() then
        return
    end

    -- BUSCA (Tarkov): se o container tem itens ocultos, um clique na grid
    -- inicia/retoma a vasculhada — exceto se o clique foi num item JÁ revelado
    -- (interação normal).
    if self:needsSearch() then
        local col, row = self:getGridCellAtMouse(x, y)
        local clickedHidden = false
        if col and row then
            local cellId = self.gridCore.cells[col][row]
            if cellId then
                local cellData = self.gridCore.items[cellId]
                if cellData and cellData.itemObj and self:isItemHidden(cellData.itemObj) then
                    clickedHidden = true
                end
            end
        end
        -- Clique em item oculto OU em célula vazia → busca. Clique em item
        -- revelado → interação normal (pegar/arrastar).
        if clickedHidden or not (col and row and self.gridCore.cells[col][row]) then
            self:startSearch()
            return
        end
    end

    local col, row = self:getGridCellAtMouse(x, y)
    local itemId = nil
    
    -- Ctrl+drag/peel: flag do stack sob o clique (limpo a cada clique novo)
    self.ctrlStackPeel = nil
    
    if col and row then
        itemId = self.gridCore.cells[col][row]
    end

    if not itemId then
        local now = getTimeInMillis()
        if self.lastEmptyClickTime and (now - self.lastEmptyClickTime < 500) then
            self.lastEmptyClickTime = nil
            
            -- Lógica de selecionar container (similar ao click no Header)
            local pLoot = getPlayerLoot(self.playerNum)
            local pInv = getPlayerInventory(self.playerNum)
            local found = false
            for _, page in ipairs({pLoot, pInv}) do
                if page and page.backpacks and not found then
                    for _, btn in ipairs(page.backpacks) do
                        if btn.inventory == self.inventoryContainer then
                            page:selectContainer(btn)
                            found = true
                            break
                        end
                    end
                end
            end
            
            return -- Aborta a seleção em área pois foi um duplo clique no fundo
        end
        self.lastEmptyClickTime = now

        -- Inicia seleção em área!
        self.draggingMarquis = true
        self.marquisStartX = x
        self.marquisStartY = y
        if not isShiftKeyDown() then
            self.selectedItems = {}
        end
        return
    end

    if itemId then
        -- Item EM TRÂNSITO (transferência pendente pra outro container): fica
        -- PRESO até a ação completar — não dá pra re-arrastar/mexer.
        if GridInventory_InTransit and GridInventory_InTransit[itemId] then
            return
        end

        -- Ctrl num item EMPILHADO: marca o "peel". Sem arrasto (mouse-up) abre
        -- o STACK PICKER; com arrasto (Ctrl+drag) tira 1 item da pilha e inicia
        -- o drag com ele (maneira rápida de pegar 1 da pilha sem abrir painel).
        local modifierAction = nil
        if isAltKeyDown() then modifierAction = GridModOptions.getModifierAction("Alt")
        elseif isCtrlKeyDown() then modifierAction = GridModOptions.getModifierAction("Ctrl")
        elseif isShiftKeyDown() then modifierAction = GridModOptions.getModifierAction("Shift")
        end

        if modifierAction then
            local actionConsumed = self:executeModifierAction(modifierAction, itemId)
            if actionConsumed then
                self.lastManualClickTime = nil
                self.lastManualClickItemId = nil
                return
            end
        end

        -- Lógica customizada de Double Click (ignora restrição severa de pixels do Java)
        local now = getTimeInMillis()
        if self.lastManualClickTime and self.lastManualClickItemId and (now - self.lastManualClickTime < 500) and self.lastManualClickItemId == itemId then
            self.lastManualClickTime = nil
            self.lastManualClickItemId = nil
            self:doDoubleClick(x, y)
            return -- Aborta o onMouseDown normal pois foi um clique duplo
        end
        
        self.lastManualClickTime = now
        self.lastManualClickItemId = itemId
        
        -- Salva as informações de clique para preparar o drag no onMouseMove (NÃO seleciona instantaneamente para evitar piscar verde em clicks limpos)
        self.clickedItemId = itemId
        self.clickX = x
        self.clickY = y
        self.clickCol = col
        self.clickRow = row
    end
end

function GridRender:onMouseMove(dx, dy)
    -- Painel colapsado: ignora movimento/hover/drag no grid
    if self:isUnderCollapsedPage() then
        return
    end

    if self.draggingMarquis then
        local mX = self:getMouseX()
        local mY = self:getMouseY()
        
        local rx = math.min(self.marquisStartX, mX)
        local ry = math.min(self.marquisStartY, mY)
        local rw = math.abs(mX - self.marquisStartX)
        local rh = math.abs(mY - self.marquisStartY)
    elseif self.clickedItemId and not GridInventory_GlobalDrag then
        local mX = self:getMouseX()
        local mY = self:getMouseY()
        
        if math.abs(mX - self.clickX) > 8 or math.abs(mY - self.clickY) > 8 then    
            -- É um drag! Seleciona o item agarrado agora (se não estiver selecionado previamente com shift)
            if not self.selectedItems[self.clickedItemId] then
                self.selectedItems = {}
                self.selectedItems[self.clickedItemId] = true
            end

            local dragList = {}
            local dragMap = {}
            local nativeList = {}
            
            -- Expande PILHAS: se um líder de pilha está selecionado, todos os
            -- membros entram no drag (arrastar pilha = mover tudo junto).
            -- Ctrl+drag (peel): só UM item da pilha entra no drag.
            local selectedIds = {}
            if self.ctrlStackPeel then
                local members = self.gridCore:getStackMembers(self.ctrlStackPeel)
                local peelId = members[2] or members[1]
                selectedIds[peelId] = true
            else
                for selectedId, _ in pairs(self.selectedItems) do
                    selectedIds[selectedId] = true
                    if self.gridCore:isStackLeader(selectedId) then
                        for _, mId in ipairs(self.gridCore:getStackMembers(selectedId)) do
                            selectedIds[mId] = true
                        end
                    end
                end
            end
            self.ctrlStackPeel = nil -- o peel foi consumido pelo drag
            
            for selectedId, _ in pairs(selectedIds) do
                local itemData = self.gridCore.items[selectedId]
                if itemData then
                    local ItemFootprint = require("Algorithm/ItemFootprint")
                    local trueW, trueH = ItemFootprint.getSize(itemData.itemObj)
                    
                    -- Verifica se o grid em que o item estava forçou um tamanho falso (como 1x1 no Overflow/PaperDoll)
                    local isForcedSize = (itemData.w ~= trueW and itemData.w ~= trueH) or (itemData.h ~= trueW and itemData.h ~= trueH)
                    local rotated = itemData.rotated
                    
                    if isForcedSize then
                        rotated = false -- Ao restaurar o tamanho real, reseta a rotação pro padrão
                    end

                    local grabOffsetX = self.clickCol - itemData.x
                    local grabOffsetY = self.clickRow - itemData.y
                    
                    if isForcedSize then
                        grabOffsetX = 0
                        grabOffsetY = 0
                    end

                    local dData = {
                        id = selectedId,
                        originalX = itemData.x,
                        originalY = itemData.y,
                        originalW = trueW,
                        originalH = trueH,
                        grabOffsetX = grabOffsetX,
                        grabOffsetY = grabOffsetY,
                        rotated = rotated,
                        itemObj = itemData.itemObj,
                        compatKey = GridContainer.getStackableCompatKey(itemData.itemObj),
                        stackInfo = select(2, GridContainer.getStackInfo(itemData.itemObj)),
                    }
                    table.insert(dragList, dData)
                    dragMap[selectedId] = true
                    if itemData.itemObj then
                        table.insert(nativeList, itemData.itemObj)
                    end
                end
            end

            if #dragList > 0 then
                -- Anchor do ghost: normalmente é o item clicado. No Ctrl+drag
                -- (peel) o clicado é o LÍDER da pilha, mas o dragList só tem o
                -- MEMBRO destacado → usa o primeiro do dragList pra ghost renderizar.
                local anchorId = self.clickedItemId
                if not dragMap[anchorId] then
                    anchorId = dragList[1].id
                end
                GridInventory_GlobalDrag = {
                    itemsData = dragList,
                    itemsMap = dragMap,
                    anchorId = anchorId,
                    sourceGrid = self
                }
                
                ISMouseDrag.dragging = nativeList
                ISMouseDrag.draggingFocus = self
                
                -- Muito importante: Limpa o clique inicial para não criar um drag fantasma caso solte o item fora deste painel e volte o mouse depois
                self.clickedItemId = nil
            end
        end
    end
end

function GridRender:doDoubleClick(x, y)
    -- Grid travado (bolsa aninhada no mundo): duplo clique também é "tirar"
    -- (o vanilla transfere pro inventário do jogador) — bloquear igual.
    if self:isLocked() then
        return
    end

    -- BUSCA: duplo clique em item OCULTO inicia/retoma a vasculhada (não usa).
    if self:needsSearch() then
        local col, row = self:getGridCellAtMouse(x, y)
        if col and row then
            local cellId = self.gridCore.cells[col][row]
            if cellId then
                local cellData = self.gridCore.items[cellId]
                if cellData and cellData.itemObj and self:isItemHidden(cellData.itemObj) then
                    self:startSearch()
                    return
                end
            else
                self:startSearch()
                return
            end
        end
    end

    local col, row = self:getGridCellAtMouse(x, y)
    if not col or not row then return end
    
    local itemId = nil
    if self.gridCore and self.gridCore.cells and self.gridCore.cells[col] then
        itemId = self.gridCore.cells[col][row]
    end
    if not itemId then
        -- Duplo clique em célula VAZIA = torna este container o ATIVO (mesma
        -- lógica do duplo clique no fundo do onMouseDown). Cobre o caso em que
        -- o Java detecta o 2º clique no PANE e encaminha pra cá (fix do duplo
        -- clique). Limpa os estados custom pra um 3º clique não repetir.
        self.lastEmptyClickTime = nil
        self.lastManualClickTime = nil
        self.lastManualClickItemId = nil
        local pLoot = getPlayerLoot(self.playerNum)
        local pInv = getPlayerInventory(self.playerNum)
        local found = false
        for _, page in ipairs({pLoot, pInv}) do
            if page and page.backpacks and not found then
                for _, btn in ipairs(page.backpacks) do
                    if btn.inventory == self.inventoryContainer then
                        page:selectContainer(btn)
                        found = true
                        break
                    end
                end
            end
        end
        return
    end
    
    -- Evita spam de double click na mesma ação
    local now = getTimeInMillis()
    if self.lastActionTime and (now - self.lastActionTime < 700) then return end
    self.lastActionTime = now
    
    self.selectedItems = {} -- Limpa a seleção para não ofuscar o progresso verde
    
    local itemData = self.gridCore.items[itemId]
    if not itemData or not itemData.itemObj then return end
    
    local item = itemData.itemObj

    -- BOLSA (InventoryContainer): duplo clique abre o floating grid pra
    -- gerenciar o conteúdo SEM equipar/segurar na mão.
    if instanceof(item, "InventoryContainer") and item.getInventory and item:getInventory() then
        if GridInventory_openFloatingBag then
            GridInventory_openFloatingBag(self.playerNum, item)
            return
        end
    end

    local playerObj = getSpecificPlayer(self.playerNum)
    local playerInvUI = getPlayerInventory(self.playerNum)
    
    -- Se o inventário da esquerda (player) estiver aberto, pegamos EXATAMENTE a aba selecionada no momento.
    -- Se por acaso falhar, caímos para o inventário principal do personagem
    local targetInv = playerObj:getInventory()
    if playerInvUI and playerInvUI.inventoryPane and playerInvUI.inventoryPane.inventory then
        targetInv = playerInvUI.inventoryPane.inventory
    end
    
    if self.inventoryContainer ~= targetInv then
        -- Loot ou Mochila Diferente -> Mochila Selecionada no Painel do Jogador
        if isForceDropHeavyItem(item) then
            ISInventoryPaneContextMenu.equipHeavyItem(playerObj, item)
        else
             -- 1. Verifica se cabe no targetInv!
             local ItemFootprint = require("Algorithm/ItemFootprint")
             local GridContainer = require("DataModel/GridContainer")
             local w, h = ItemFootprint.getSize(item)
             -- Empilháveis: passamos compatKey/stackInfo pro findFreeSpace achar
             -- TANTO uma pilha compatível existente (empilhar) QUANTO uma célula
             -- livre, nas DUAS orientações (horizontal e rotacionada "em pé").
             local compatKey, stackInfo = GridContainer.getStackInfo(item)
             local targetGrid = GridContainer.instances[targetInv]
             
             local canFitInTarget = false
             -- Antes de olhar a geometria, checa a capacidade de peso!
             if targetInv:hasRoomFor(playerObj, item) and targetGrid and targetGrid.grids and targetGrid.grids[1] then
                 -- Checa se cabe na posição original
                 local fx, fy = targetGrid.grids[1]:findFreeSpace(item:getID(), w, h, compatKey, stackInfo, false)
                 -- Se não couber, tenta rotacionado
                 if not fx then
                     fx, fy = targetGrid.grids[1]:findFreeSpace(item:getID(), h, w, compatKey, stackInfo, true)
                 end
                 
                 if fx and fy then
                     canFitInTarget = true
                 end
             end
             
             local isFromEquippedBag = self.inventoryContainer:isInCharacterInventory(playerObj)
             
             local canFitAnywhere = canFitInTarget
             -- Se não couber no alvo principal, e for do Loot, verificamos se cabe em QUALQUER outra mochila ou bolsos
             if not canFitInTarget and not isFromEquippedBag then
                 for i = 0, playerObj:getWornItems():size() - 1 do
                     local wornItem = playerObj:getWornItems():get(i):getItem()
                     if wornItem and wornItem:IsInventoryContainer() then
                         local bagInv = wornItem:getInventory()
                         local bagGrid = GridContainer.instances[bagInv]
                         if bagInv:hasRoomFor(playerObj, item) and bagGrid and bagGrid.grids and bagGrid.grids[1] then
                             local bfx, bfy = bagGrid.grids[1]:findFreeSpace(item:getID(), w, h, compatKey, stackInfo, false)
                             if not bfx then bfx, bfy = bagGrid.grids[1]:findFreeSpace(item:getID(), h, w, compatKey, stackInfo, true) end
                             if bfx and bfy then
                                 canFitAnywhere = true
                                 break
                             end
                         end
                     end
                 end
                 
                 if not canFitAnywhere then
                     local pInv = playerObj:getInventory()
                     local pGrid = GridContainer.instances[pInv]
                     if pInv:hasRoomFor(playerObj, item) and pGrid and pGrid.grids and pGrid.grids[1] then
                         local pfx, pfy = pGrid.grids[1]:findFreeSpace(item:getID(), w, h, compatKey, stackInfo, false)
                         if not pfx then pfx, pfy = pGrid.grids[1]:findFreeSpace(item:getID(), h, w, compatKey, stackInfo, true) end
                         if pfx and pfy then
                             canFitAnywhere = true
                         end
                     end
                 end
             end
             
            -- Se couber no target (ou se for do Loot e couber em qualquer lugar), transfere normal
            if canFitInTarget or (not isFromEquippedBag and canFitAnywhere) then
                if luautils.walkToContainer(self.inventoryContainer, self.playerNum) then
                    ISTimedActionQueue.add(ISInventoryTransferUtil.newInventoryTransferAction(playerObj, item, self.inventoryContainer, targetInv))
                end
            else
                -- Veio de uma mochila equipada e a raiz ta cheia:
                -- Tenta equipar nas mãos pra não dar loop de unpack!
                local primary = playerObj:getPrimaryHandItem()
                local secondary = playerObj:getSecondaryHandItem()
                
                if isFromEquippedBag and primary == nil then
                    if luautils.walkToContainer(self.inventoryContainer, self.playerNum) then
                        ISInventoryPaneContextMenu.equipWeapon(item, true, false, self.playerNum)
                    end
                elseif isFromEquippedBag and secondary == nil then
                    if luautils.walkToContainer(self.inventoryContainer, self.playerNum) then
                        ISInventoryPaneContextMenu.equipWeapon(item, false, false, self.playerNum)
                    end
                else
                    -- Feedback visual "Sem Espaço"
                    itemData.outOfSpaceTimer = getTimeInMillis() + 1500
                end
            end
        end
    else
        -- Contextual double click (Equip / Wear / Eat, etc)
        local invUI = getPlayerInventory(self.playerNum)
        if invUI and invUI.inventoryPane then
            invUI.inventoryPane:doContextualDblClick(item)
        end
    end
end

function GridRender:onMouseDoubleClick(x, y)
    -- Painel colapsado: consome o clique pra nada cair no vanilla
    if self:isUnderCollapsedPage() then
        return true
    end
    -- O Zomboid chama isso se os pixels não mudarem mais de 5 e for dentro de 500ms.
    -- Como nós já interceptamos no onMouseDown de forma mais robusta, apenas chamamos nosso método.
    -- Grid travado: consome o clique pra nada cair no vanilla (que transferiria).
    if self:isLocked() then
        return true
    end
    self:doDoubleClick(x, y)
    return true
end

--- Aplica um reorder (revalida + remove tudo + insere) e sincroniza no MP.
--- Compartilhado entre o caminho IMEDIATO (opção off) e o perform() da
--- GridReorderAction (opção on): a revalidação no apply() torna a ação
--- atrasada segura mesmo se o grid mudar entre o drop e o perform.
function GridRender:performGridReorder(targets)
    if not self or not self.gridCore then return false end
    if not GridReorder.apply(self.gridCore, targets) then
        self.selectedItems = {}
        return false
    end
    for _, t in ipairs(targets) do
        if t.item.itemObj then
            local modData = t.item.itemObj:getModData()
            modData.gridX = t.tx
            modData.gridY = t.ty
            modData.gridRot = t.item.rotated
            modData.gridContainer = GridContainer.containerSignature(self.inventoryContainer)
            -- Posição MANUAL: consolidação de pilhas nunca move este item.
            modData.gridManual = true
        end
    end
    -- MP server-mandatory: um comando em LOTE com TODOS os alvos. O servidor
    -- valida o lote junto (movedSet) e aplica all-or-nothing — se enviássemos
    -- um REQUEST_MOVE por item, o servidor validaria cada um contra o modData
    -- atual (os outros itens ainda na origem) e o primeiro swap colidiria.
    GridClientNetwork.sendReorder(self.inventoryContainer, targets,
        GridContainer.containerSignature(self.inventoryContainer))
    -- Reorder no MESMO grid é só modData: nada mais dispara refresh (poll: hash
    -- de itens igual; OnContainerUpdate: item não saiu do container; SP: sem eco
    -- do servidor). Toca o pane na hora pra o OverflowGridRender (snapshot) ser
    -- reconstruído se o reorder abriu espaço pro overflow voltar pro grid.
    GridClientNetwork.markGridChanged(self.inventoryContainer, self.playerNum)
    self.selectedItems = {}
    return true
end

function GridRender:onMouseUp(x, y)
    if GridInventory_joypadDebug then
        print("[GridJoypad] GridRender:onMouseUp x=", tostring(x), " y=", tostring(y),
            " grid=", tostring(self.name or self.inventoryContainer))
    end
    -- Painel colapsado: cancela QUALQUER drag em curso (evita item preso na
    -- mão) e não processa o drop.
    if self:isUnderCollapsedPage() then
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
        return
    end

    -- Processa o Stack Picker se o cara soltou o clique sem ter arrastado (drag consome o peelId)
    if self.ctrlStackPeel and not GridInventory_GlobalDrag
        and not (ISMouseDrag.dragging and #ISMouseDrag.dragging > 0) then
        local peelId = self.ctrlStackPeel
        self.ctrlStackPeel = nil
        
        -- Verifica qual ação era pra não abrir o Picker se a pessoa queria só o Take One (2)
        local wasPicker = false
        if isAltKeyDown() and GridModOptions.getModifierAction("Alt") == 1 then wasPicker = true
        elseif isCtrlKeyDown() and GridModOptions.getModifierAction("Ctrl") == 1 then wasPicker = true
        elseif isShiftKeyDown() and GridModOptions.getModifierAction("Shift") == 1 then wasPicker = true
        end

        if wasPicker and GridInventory_openStackPicker then
            GridInventory_openStackPicker(self.playerNum, self, peelId)
        end
        return
    end
    self.ctrlStackPeel = nil
    self.clickedItemId = nil

    -- PUT-IN: se soltou sobre uma bolsa (footprint) ou sobre o header de um
    -- grid, transfere ANTES do posicionamento normal — idempotente com os
    -- caminhos de update()/prerender (o drag é zerado se transferir). Só no
    -- drag de MOUSE: o joypad usa a posição do cursor, não a do mouse.
    if GridInventory_GlobalDrag and not GridInventory_GlobalDrag.joypad then
        if GridInventory_BagDrop.tryHandleMouseUp(self.playerNum) then
            return
        end
    end

    -- Grid travado (bolsa aninhada no mundo): consome o drop SEM mover nada.
    -- O engine recusa a transferência — se o grid reposicionasse/autoSlotasse
    -- antes, o item ficaria com posição fantasma (gridX/gridY no container
    -- travado) sem nunca entrar nele.
    if self:isLocked() then
        if GridInventory_GlobalDrag then
            if GridInventory_GlobalDrag.sourceGrid then
                GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
            end
            GridInventory_GlobalDrag = nil
            ISMouseDrag.dragging = nil
            ISMouseDrag.draggingFocus = nil
        end
        self.selectedItems = {}
        self.draggingMarquis = false
        return
    end

    -- BUSCA: se o container ainda tem itens ocultos, um drop DENTRO dele só
    -- pode ser sobre itens JÁ revelados. Drop sobre item oculto/célula vazia é
    -- consumido (sem mover) — não dá pra interagir com o que você não viu.
    if self:needsSearch() then
        local dropCol, dropRow = self:getGridCellAtMouse(x, y)
        local dropOnHidden = false
        if dropCol and dropRow then
            local cellId = self.gridCore.cells[dropCol][dropRow]
            if cellId then
                local cellData = self.gridCore.items[cellId]
                if cellData and cellData.itemObj and self:isItemHidden(cellData.itemObj) then
                    dropOnHidden = true
                end
            else
                dropOnHidden = true -- célula vazia (não revelou onde cai)
            end
        end
        if dropOnHidden then
            if GridInventory_GlobalDrag then
                if GridInventory_GlobalDrag.sourceGrid then
                    GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
                end
                GridInventory_GlobalDrag = nil
                ISMouseDrag.dragging = nil
                ISMouseDrag.draggingFocus = nil
            end
            self.selectedItems = {}
            self.draggingMarquis = false
            return
        end
    end

    if self.draggingMarquis then
        self.draggingMarquis = false
        local mX = self:getMouseX()
        local mY = self:getMouseY()
        
        local rx = math.min(self.marquisStartX, mX)
        local ry = math.min(self.marquisStartY, mY)
        local rw = math.abs(mX - self.marquisStartX)
        local rh = math.abs(mY - self.marquisStartY)
        
        for itemId, data in pairs(self.gridCore.items) do
            local itemX = self.gridPadding + ((data.x - 1) * self.cellSize)
            local itemY = self.gridPadding + (self.headerH or 0) + ((data.y - 1) * self.cellSize)
            local itemW = data.w * self.cellSize
            local itemH = data.h * self.cellSize
            
            -- Checa interseção de retângulos simples
            if itemX < rx + rw and itemX + itemW > rx and itemY < ry + rh and itemY + itemH > ry then
                self.selectedItems[itemId] = true
            end
        end
        return
    end

    -- Se temos um drag global iniciado por nós mesmos, estamos soltando itens do próprio grid
    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid == self then
        -- CHÃO: reorder desativado. O chão não persiste posição salva e o layout
        -- é recalculado do zero a cada refresh (fix do flicker); reposicionar
        -- manualmente não teria efeito durável. Consome o drop sem reposicionar.
        if self.inventoryContainer and self.inventoryContainer.getType and self.inventoryContainer:getType() == "floor" then
            if GridInventory_GlobalDrag.sourceGrid then
                GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
            end
            GridInventory_GlobalDrag = nil
            ISMouseDrag.dragging = nil
            ISMouseDrag.draggingFocus = nil
            return
        end
        -- Drop em bolsa já tratado pelo caminho vanilla (dropItemsInContainer
        -- transferiu os itens e chamou onMouseUp(0,0) só pra limpar o estado
        -- global). Nunca reposicionar itens que já saíram do container.
        if GridInventory_GlobalDrag.handledByBag then
            if GridInventory_GlobalDrag.sourceGrid then
                GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
            end
            GridInventory_GlobalDrag = nil
            ISMouseDrag.dragging = nil
            ISMouseDrag.draggingFocus = nil
            return
        end

        local dropCol, dropRow = self:getGridCellAtMouse(x, y)
        local itemsData = GridInventory_GlobalDrag.itemsData
        
        if dropCol and dropRow then
            -- Tenta colocar todos ou nenhum (modo estrito para evitar perda de
            -- itens). O GridReorder.computeTargets calcula e valida os alvos de
            -- uma vez com o movedSet de TODOS os itens arrastados (pilhas podem
            -- sobrepor a própria origem sem colidir com os membros em movimento).
            local targets = GridReorder.computeTargets(self.gridCore, itemsData, dropCol, dropRow)

            if GridInventory_joypadDebug then
                print("[GridJoypad] same-grid drop: joypad=", tostring(GridInventory_GlobalDrag and GridInventory_GlobalDrag.joypad),
                    " col=", tostring(dropCol), " row=", tostring(dropRow),
                    " targets=", tostring(targets ~= nil),
                    " noop=", tostring(targets ~= nil and GridReorder.isNoOp(self.gridCore, targets)))
            end

            if targets then
                -- Drop na própria posição (no-op): consome o drop sem animação,
                -- sem broadcast redundante e sem "movimento" de mentira.
                if not GridReorder.isNoOp(self.gridCore, targets) then
                    if GridSandboxOptions.isReorderTimed() then
                        -- Caminho atrasado: a GridReorderAction faz a animação de
                        -- transferência e aplica no perform (~0.5s). No MP isso
                        -- dá uma janela pro servidor processar o movimento.
                        local playerObj = getSpecificPlayer(self.playerNum)
                        if playerObj then
                            local GridReorderAction = require("TimedActions/GridReorderAction")
                            ISTimedActionQueue.add(GridReorderAction:new(playerObj, self, targets))
                        else
                            self:performGridReorder(targets)
                        end
                    else
                        self:performGridReorder(targets)
                    end
                end
            end
        end

        if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid then
            GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
        end
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
        return
    end

    -- Se não é um drag do mesmo grid, mas estamos arrastando algo de outro lugar
    if ISMouseDrag.dragging and #ISMouseDrag.dragging > 0 then
        local dropCol, dropRow = self:getGridCellAtMouse(x, y)
        if dropCol and dropRow then
            -- Verifica se é um drag de outro grid nosso (temos os offsets e rotação!)
            local globalDragItems = nil
            if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid ~= self then
                globalDragItems = GridInventory_GlobalDrag.itemsData
            end

            local ItemFootprint = require("Algorithm/ItemFootprint")
            local isMultiDrag = (#ISMouseDrag.dragging > 1)
            if globalDragItems and #globalDragItems > 1 then
                isMultiDrag = true
            end

            -- PILHA ÚNICA arrastada (líder + membros na MESMA célula de origem):
            -- é UMA unidade lógica (uma célula, um footprint), NÃO um multi-drag
            -- de verdade. Se caísse no multi-drag, a posição de TODOS os membros
            -- seria limpa e o auto-sort jogaria a pilha pro começo do grid alvo
            -- (perda da posição salva). Detecta via célula de origem compartilhada
            -- e trata como item único (controle fino): a pilha aterrissa na célula
            -- do drop com a posição preservada.
            local singleStackLeaderId = nil
            if isMultiDrag and globalDragItems and #globalDragItems > 1
                and GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid
                and GridInventory_GlobalDrag.sourceGrid.gridCore then
                local first = globalDragItems[1]
                local sameCell = first.originalX ~= nil
                for i = 2, #globalDragItems do
                    local d = globalDragItems[i]
                    if d.originalX ~= first.originalX or d.originalY ~= first.originalY then
                        sameCell = false
                        break
                    end
                end
                if sameCell then
                    local sourceCore = GridInventory_GlobalDrag.sourceGrid.gridCore
                    for _, d in ipairs(globalDragItems) do
                        if sourceCore:isStackLeader(d.id) then
                            singleStackLeaderId = d.id
                            break
                        end
                    end
                    isMultiDrag = false
                end
            end
            
            local isFromPaperDoll = GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid and GridInventory_GlobalDrag.sourceGrid.slotName

            local singleStackHandled = false
            if singleStackLeaderId then
                local leaderData = nil
                for _, d in ipairs(globalDragItems) do
                    if d.id == singleStackLeaderId then
                        leaderData = d
                        break
                    end
                end

                if leaderData and leaderData.itemObj then
                    local leader = leaderData.itemObj
                    local rotated = leaderData.rotated or false
                    local fw, fh = ItemFootprint.getSize(leader)
                    local effectiveW = rotated and fh or fw
                    local effectiveH = rotated and fw or fh
                    local targetX = dropCol - (leaderData.grabOffsetX or 0)
                    local targetY = dropRow - (leaderData.grabOffsetY or 0)
                    local compatKey = leaderData.compatKey
                    local stackInfo = leaderData.stackInfo

                    if targetX < 1 then targetX = 1 end
                    if targetY < 1 then targetY = 1 end
                    if not self.gridCore:canPlaceItem(leader:getID(), targetX, targetY,
                        effectiveW, effectiveH, nil, compatKey, rotated, stackInfo) then
                        local fx, fy = self.gridCore:findFreeSpace(leader:getID(), effectiveW,
                            effectiveH, compatKey, stackInfo, rotated)
                        targetX, targetY = fx, fy
                    end

                    if targetX and targetY and self.inventoryContainer:isItemAllowed(leader) then
                        local targetSig = GridContainer.containerSignature(self.inventoryContainer)
                        for _, d in ipairs(globalDragItems) do
                            local item = d.itemObj
                            if item then
                                local md = item:getModData()
                                local previousX = md.gridX
                                local previousY = md.gridY
                                local previousRot = md.gridRot or false
                                local previousContainer = md.gridContainer
                                md.gridX = targetX
                                md.gridY = targetY
                                md.gridRot = rotated
                                md.gridContainer = targetSig
                                -- Posição MANUAL: a consolidação não move este item.
                                md.gridManual = true
                                GridClientNetwork.sendItemMove(self.inventoryContainer,
                                    item:getID(), targetX, targetY, rotated, targetSig, true)
                                GridInventory_InTransit[item:getID()] = {
                                    startedAt = getTimeInMillis(),
                                    grid = self,
                                    source = item:getContainer(),
                                    item = item,
                                    previousX = previousX,
                                    previousY = previousY,
                                    previousRot = previousRot,
                                    previousContainer = previousContainer,
                                }
                            end
                        end

                        -- Stack virtual (ex.: Twine) é composto por vários
                        -- InventoryItems independentes. Enfileira cada objeto
                        -- separadamente; passar a lista inteira permite que o
                        -- engine reagruppe a lista durante a ação e deixe parte
                        -- da pilha no autoFill. As posições já foram gravadas
                        -- acima para todos, antes do primeiro transfer.
                        self.gridCore:addGhostItem(leader:getID(), leader, targetX, targetY,
                            effectiveW, effectiveH, rotated, compatKey, stackInfo)
                        local playerInv = getPlayerInventory(self.playerNum)
                        if playerInv and playerInv.inventoryPane then
                            local stackItems = {}
                            for _, d in ipairs(globalDragItems) do
                                if d.itemObj and d.id ~= singleStackLeaderId then
                                    table.insert(stackItems, d.itemObj)
                                end
                            end
                            -- O líder deve ser o ÚLTIMO objeto transferido. Se
                            -- entrar antes, o engine promove/reagrupa a pilha
                            -- no meio da ação e os membros restantes podem
                            -- voltar ao autoFill durante o refresh.
                            if leader then
                                table.insert(stackItems, leader)
                            end
                            for _, item in ipairs(stackItems) do
                                playerInv.inventoryPane:transferItemsByWeight({item}, self.inventoryContainer)
                            end
                        end
                        singleStackHandled = true
                    end
                end
            end

            if not singleStackHandled then
            for index, itemObj in ipairs(ISMouseDrag.dragging) do
                if type(itemObj) == "table" and itemObj.items then
                    itemObj = itemObj.items[1]
                end
                
                -- Se o item vem de outro container, ou se está equipado e jogamos no próprio inventário
                local isEquipped = itemObj:isEquipped()
                local srcContainer = itemObj:getContainer()
                
                if srcContainer ~= self.inventoryContainer or isEquipped then
                    local targetX = dropCol
                    local targetY = dropRow
                    local rotated = false
                    
                    local fw, fh = ItemFootprint.getSize(itemObj)
                    local effectiveW = fw
                    local effectiveH = fh
                    
                    if isMultiDrag then
                        -- Se for múltiplos itens, joga o controle pela janela e deixa o AutoSort agir
                        local modData = itemObj:getModData()
                        modData.gridX = nil
                        modData.gridY = nil
                        modData.gridRot = false
                        modData.gridContainer = nil
                        
                        if itemObj == self.containerItem or not self.inventoryContainer:isItemAllowed(itemObj) then
                            -- Ignora, não pode guardar dentro de si mesmo ou item não é permitido
                        elseif isFromPaperDoll and srcContainer == self.inventoryContainer then
                            local playerObj = getSpecificPlayer(self.playerNum)
                            if playerObj then
                                if itemObj:getAttachedSlot() > -1 then
                                    ISTimedActionQueue.add(ISDetachItemHotbar:new(playerObj, itemObj))
                                else
                                    ISTimedActionQueue.add(ISUnequipAction:new(playerObj, itemObj, 50))
                                end
                            end
                        else
                            -- Multi-drag: SEM ghost (o ciclo de vida do ghost não
                            -- sobrevive ao refreshContainer, que recria o GridRender
                            -- — vira ghost preso). Só marca EM TRÂNSITO (lock):
                            -- o item não pode ser re-arrastado durante a transfer.
                            local modData = itemObj:getModData()
                            modData.gridX = nil
                            modData.gridY = nil
                            modData.gridRot = false
                            modData.gridContainer = nil
                            GridInventory_InTransit[itemObj:getID()] = {
                                startedAt = getTimeInMillis(),
                                grid = self,
                                source = itemObj:getContainer(),
                                item = itemObj,
                            }
                            -- MP: limpa a posição (auto-fit recalcula).
                            GridClientNetwork.clearServerPosition(self.inventoryContainer, itemObj:getID())
                            local playerInv = getPlayerInventory(self.playerNum)
                            if playerInv and playerInv.inventoryPane then
                                playerInv.inventoryPane:transferItemsByWeight({itemObj}, self.inventoryContainer)
                            end
                        end
                    else
                        -- Controle fino para 1 único item
                        if globalDragItems and globalDragItems[index] then
                            local dData = globalDragItems[index]
                            targetX = dropCol - (dData.grabOffsetX or 0)
                            targetY = dropRow - (dData.grabOffsetY or 0)
                            rotated = dData.rotated
                            effectiveW = dData.rotated and (dData.originalH or fh) or (dData.originalW or fw)
                            effectiveH = dData.rotated and (dData.originalW or fw) or (dData.originalH or fh)
                        end
                        
                        if targetX < 1 then targetX = 1 end
                        if targetY < 1 then targetY = 1 end

                        local compatKey, stackInfo = GridContainer.getStackInfo(itemObj)
                        
                        if not self.gridCore:canPlaceItem(itemObj:getID(), targetX, targetY, effectiveW, effectiveH, nil, compatKey, rotated, stackInfo) then
                            local fx, fy = self.gridCore:findFreeSpace(itemObj:getID(), effectiveW, effectiveH, compatKey, stackInfo, rotated)
                            if fx and fy then
                                targetX = fx
                                targetY = fy
                            else
                                -- Saco cheio!
                                targetX = nil
                                targetY = nil
                            end
                        end
                        
                        if targetX and targetY then
                            if itemObj == self.containerItem or not self.inventoryContainer:isItemAllowed(itemObj) then
                                -- Ignora
                            else
                                local modData = itemObj:getModData()
                                modData.gridX = targetX
                                modData.gridY = targetY
                                modData.gridRot = rotated
                                modData.gridContainer = GridContainer.containerSignature(self.inventoryContainer)
                                -- Posição MANUAL: a consolidação não move este item.
                                modData.gridManual = true
                                -- MP server-mandatory: servidor grava a posição (drop coords, não autoSlot).
                                GridClientNetwork.sendItemMove(self.inventoryContainer, itemObj:getID(), targetX, targetY, rotated, modData.gridContainer, true)
                                
                                if isFromPaperDoll and srcContainer == self.inventoryContainer then
                                    local playerObj = getSpecificPlayer(self.playerNum)
                                    if playerObj then
                                        if itemObj:getAttachedSlot() > -1 then
                                            ISTimedActionQueue.add(ISDetachItemHotbar:new(playerObj, itemObj))
                                        else
                                            ISTimedActionQueue.add(ISUnequipAction:new(playerObj, itemObj, 50))
                                        end
                                    end
                                else
                                    self.gridCore:addGhostItem(itemObj:getID(), itemObj, targetX, targetY, effectiveW, effectiveH, rotated, compatKey, stackInfo)
                                    -- Marca como EM TRÂNSITO: o item fica preso
                                    -- até o transfer completar (não dá pra
                                    -- re-arrastar enquanto a ação roda). Guarda
                                    -- o GRID ALVO — só ele pode liberar o lock
                                    -- (o grid origem também tem o item em items).
                                    GridInventory_InTransit[itemObj:getID()] = {
                                        startedAt = getTimeInMillis(),
                                        grid = self,
                                        source = itemObj:getContainer(),
                                        item = itemObj,
                                    }
                                    local playerInv = getPlayerInventory(self.playerNum)
                                    if playerInv and playerInv.inventoryPane then
                                        playerInv.inventoryPane:transferItemsByWeight({itemObj}, self.inventoryContainer)
                                    end
                                end
                            end
                        end
                    end
                end
            end
            end
        end
        if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid then
            GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
        end
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
        return
    end

    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid then
        GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
    end
    GridInventory_GlobalDrag = nil
    ISMouseDrag.dragging = nil
    ISMouseDrag.draggingFocus = nil
end

function GridRender:onMouseUpOutside(x, y)
    -- Painel colapsado: cancela drag em curso e ignora o release fora do grid
    if self:isUnderCollapsedPage() then
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
        return
    end
    -- Ctrl+clique solto FORA do grid: não abre o picker. Só limpa o flag.
    self.ctrlStackPeel = nil
end

--- Move UM membro da pilha para uma célula própria (livre) no MESMO grid.
--- Se o grid estiver cheio, transfere o membro pros bolsos. Usado pelo
--- stack picker ("pegar o melhor item da pilha") e pelo split.
---@param memberId string|number id do membro (objeto) a tirar da pilha
---@return boolean true se conseguiu tirar
function GridRender:takeStackMember(memberId)
    local memberData = self.gridCore.items[memberId]
    local member = memberData and memberData.itemObj
    if not member then return false end

    local w, h = ItemFootprint.getSize(member)
    local _, stackInfo = GridContainer.getStackInfo(member)
    -- findFreeSpace SEM compatKey: célula genuinamente livre (não re-empilha)
    local fx, fy = self.gridCore:findFreeSpace(memberId, w, h, nil, stackInfo)

    if fx and fy then
        local md = member:getModData()
        md.gridX = fx
        md.gridY = fy
        md.gridRot = false
        -- Peel manual: posição definida pelo jogador → a consolidação NÃO
        -- re-absorve este membro de volta na pilha.
        md.gridManual = true
        if self.inventoryContainer and self.inventoryContainer.setDrawDirty then
            self.inventoryContainer:setDrawDirty(true)
        end
        -- MP server-mandatory: servidor grava a nova posição (célula própria).
        GridClientNetwork.sendItemMove(self.inventoryContainer, member:getID(), fx, fy, false, md.gridContainer, true)
        -- Re-refresh o GridCore AGORA: hash de IDs não muda numa divisão.
        local gc = GridContainer.getOrCreate(self.inventoryContainer, self.playerNum)
        gc:refresh()
        return true
    else
        -- Grid cheio: transfere 1 membro pros bolsos (engine combina munição).
        local playerObj = getSpecificPlayer(self.playerNum)
        local playerInv = getPlayerInventory(self.playerNum)
        if playerObj and playerInv and playerInv.inventoryPane then
            local dst = playerObj:getInventory()
            if dst:hasRoomFor(playerObj, member) then
                GridClientNetwork.clearServerPosition(self.inventoryContainer, member:getID())
                playerInv.inventoryPane:transferItemsByWeight({member}, dst)
                return true
            end
        end
        return false
    end
end

--- Separar 1 item da pilha: pega o PRIMEIRO membro disponível e tira da pilha.
--- (O split agora acontece no STACK PICKER — duplo clique na pilha.)

function GridRender:onRightMouseUp(x, y)
    -- Painel colapsado: nenhum contexto/comando de grid
    if self:isUnderCollapsedPage() then
        return
    end

    -- Clique direito no HEADER do grid: abre o MESMO menu de contexto que o
    -- clique direito na coluna de containers do painel (ISInventoryPage:
    -- onBackpackRightMouseDown). Isso expõe Rename Bag, DevTools (Edit Grid
    -- Size), etc. direto no grid. Para o inventário do jogador (sem item
    -- contendo) o vanilla não abre menu de bag; mas o DevTools aparece no
    -- menu de ITEM (a bolsa principal é um item), então usamos o container
    -- contendo (se existir) ou o próprio inventário como item falso.
    if self.headerH and self.headerH > 0 then
        if y >= self.gridPadding and y <= self.gridPadding + self.headerH then
            local container = self.inventoryContainer
            if container then
                -- Acha o BOTÃO REAL da coluna de containers que representa este
                -- container e reusa o clique direito nativo dele (onBackpack
                -- RightMouseDown) — o MESMO menu da coluna: Rename Bag, Refill
                -- Container, etc. (o DevTools é adicionado DEPOIS, no contexto
                -- recém-criado — ISContextMenu.get LIMPA o menu a cada chamada,
                -- então adicionar antes seria apagado).
                local pLoot = getPlayerLoot and getPlayerLoot(self.playerNum)
                local pInv = getPlayerInventory and getPlayerInventory(self.playerNum)
                local targetBtn = nil
                local page = nil
                for _, pg in ipairs({pInv, pLoot}) do
                    if pg and pg.backpacks then
                        for _, btn in ipairs(pg.backpacks) do
                            if btn and btn.inventory == container then
                                targetBtn = btn
                                page = pg
                                break
                            end
                        end
                    end
                    if targetBtn then break end
                end
                -- Menu da coluna vanilla (Rename Bag, Refill, etc.) pra bags.
                if targetBtn then
                    if targetBtn.onRightMouseDown then
                        targetBtn.onRightMouseDown(targetBtn, x, y)
                    elseif targetBtn.onBackpackRightMouseDown then
                        targetBtn.onBackpackRightMouseDown(targetBtn, x, y)
                    end
                end
                -- DevTools com o CONTAINER como alvo (edita o grid do mundo/
                -- jogador, não só bags com item). Adiciona DEPOIS do menu da
                -- coluna (o ISContextMenu.get limpa a cada chamada).
                local GridDevToolUI = require("UI/GridDevTool")
                if GridDevToolUI and GridDevToolUI.addContextOption then
                    local context = ISContextMenu.get(self.playerNum, getMouseX(), getMouseY())
                    if context then
                        GridDevToolUI.addContextOption(context, self.playerNum, container)
                    end
                end
            end
            return
        end
    end

    if GridInventory_GlobalDrag then
        -- Rotaciona TODOS os itens sendo arrastados no grupo!
        for _, draggedItem in ipairs(GridInventory_GlobalDrag.itemsData) do
            draggedItem.rotated = not draggedItem.rotated
            draggedItem.grabOffsetX, draggedItem.grabOffsetY = draggedItem.grabOffsetY, draggedItem.grabOffsetX
        end
    else
        -- Grid travado (bolsa aninhada no mundo): o menu de contexto é a porta
        -- de entrada do "Take/Loot" do vanilla — bloqueia pra não deixar tirar.
        if self:isLocked() then
            return
        end

        -- BUSCA: contexto em item OCULTO inicia/retoma a vasculhada (sem menu).
        if self:needsSearch() then
            local col, row = self:getGridCellAtMouse(x, y)
            if col and row then
                local cellId = self.gridCore.cells[col][row]
                if cellId then
                    local cellData = self.gridCore.items[cellId]
                    if cellData and cellData.itemObj and self:isItemHidden(cellData.itemObj) then
                        self:startSearch()
                        return
                    end
                else
                    self:startSearch()
                    return
                end
            end
        end

        local col, row = self:getGridCellAtMouse(x, y)
        if col and row then
            local itemId = self.gridCore.cells[col][row]
            if itemId then
                local modifierAction = nil
                if isAltKeyDown() then modifierAction = GridModOptions.getModifierAction("RightAlt")
                elseif isCtrlKeyDown() then modifierAction = GridModOptions.getModifierAction("RightCtrl")
                elseif isShiftKeyDown() then modifierAction = GridModOptions.getModifierAction("RightShift")
                end

                if modifierAction and modifierAction ~= 6 then
                    -- 2 é Take One (que não faz sentido no right click pois não tem arrasto). Se for 2, ignoramos.
                    if modifierAction == 2 then
                        modifierAction = 6
                    end
                    
                    if modifierAction == 1 then
                        if GridInventory_openStackPicker and self.gridCore:getStackSize(itemId) > 1 then
                            GridInventory_openStackPicker(self.playerNum, self, itemId)
                        end
                        return
                    end
                    
                    local actionConsumed = self:executeModifierAction(modifierAction, itemId)
                    if actionConsumed then return end
                end

                local itemData = self.gridCore.items[itemId]
                if itemData and itemData.itemObj then
                    local inv = itemData.itemObj:getContainer()
                    local isInPlayerInv = inv and inv:isInCharacterInventory(getSpecificPlayer(self.playerNum)) or false
                    
                    ISInventoryPaneContextMenu.createMenu(self.playerNum, isInPlayerInv, {itemData.itemObj}, self:getAbsoluteX() + x, self:getAbsoluteY() + y)
                end
            end
        end
    end
end

function GridRender:removeFromUIManager()
    self:destroy()
    ISPanel.removeFromUIManager(self)
end

function GridRender:destroy()
    if self.toolRender then
        self.toolRender:removeFromUIManager()
        self.toolRender:setVisible(false)
        self.toolRender = nil
    end
end

function GridRender:updateTooltip()
    -- Cursor de joypad: o tooltip segue o cursor virtual (não o mouse).
    local joyCursor = GridJoypad.isCursorOn(self)
    -- Com o cursor virtual VISÍVEL, o tooltip do MOUSE é suprimido em todos os
    -- grids — só o grid do cursor mostra tooltip (na posição da célula). Senão
    -- o grid sob o mouse real criava/sobrepunha um tooltip na posição do mouse.
    local joypadActive = GridJoypad.isCursorVisible(self.playerNum)

    -- Checa se o mouse está sobre esse grid E sobre o painel pai (para evitar tooltips quando scrollar o grid pra fora da view)
    local isOver = joyCursor or (not joypadActive and self:isMouseOver())
    if not joyCursor and isOver and self.parent and not self.parent:isMouseOver() then
        isOver = false
    end
    
    if not isOver or not self:getIsVisible() then
        if self.toolRender then
            self.toolRender:removeFromUIManager()
            self.toolRender:setVisible(false)
            self.toolRender = nil
        end
        return
    end
    
    local col, row
    local tx, ty
    if joyCursor then
        local cursor = GridJoypad.cursors[self.playerNum]
        if cursor then
            col, row = cursor.col, cursor.row
            -- Posição do tooltip: canto INFERIOR DIREITO do footprint do item
            -- sob o cursor — longe dos botões A/B/X/Y (que ficam abaixo da
            -- célula do cursor) e padronizada pro tamanho do item. Sem item,
            -- usa a própria célula do cursor.
            local d = nil
            if self.gridCore and self.gridCore.cells and self.gridCore.cells[col] then
                local fid = self.gridCore.cells[col][row]
                if fid then d = self.gridCore.items[fid] end
            end
            if d and d.itemObj and not d.stackMemberOf and d.x and d.y and d.w and d.h then
                -- Canto inferior DIREITO do footprint: a borda DIREITA do item é
                -- (d.x+d.w-1)*cellSize e a borda inferior (d.y+d.h-1)*cellSize —
                -- o tooltip encosta no canto, sem 1 slot de folga (antes usava
                -- d.x+d.w, que fica uma célula além).
                tx = self:getAbsoluteX() + self.gridPadding + ((d.x + d.w - 1) * self.cellSize)
                ty = self:getAbsoluteY() + self.gridPadding + (self.headerH or 0) + ((d.y + d.h - 1) * self.cellSize)
            else
                tx = self:getAbsoluteX() + self.gridPadding + ((col - 1) * self.cellSize)
                ty = self:getAbsoluteY() + self.gridPadding + (self.headerH or 0) + ((row - 1) * self.cellSize)
            end
        end
    else
        local mx = self:getMouseX()
        local my = self:getMouseY()
        col, row = self:getGridCellAtMouse(mx, my)
    end
    
    local hoveredItem = nil
    if col and row and self.gridCore and self.gridCore.cells then
        local itemId = self.gridCore.cells[col][row]
        if itemId and self.gridCore.items[itemId] then
            hoveredItem = self.gridCore.items[itemId].itemObj
        end
    end

    -- BUSCA (Tarkov): item OCULTO não mostra tooltip (você não sabe o que é).
    -- Suprime o tooltip e zera o render existente.
    if hoveredItem and self:isItemHidden(hoveredItem) then
        if self.toolRender then
            self.toolRender:removeFromUIManager()
            self.toolRender:setVisible(false)
            self.toolRender = nil
        end
        return
    end
    
    if hoveredItem and not ISMouseDrag.dragging and not GridInventory_GlobalDrag and not self.draggingMarquis then
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
        
        if not joyCursor then
            -- Mouse: o tooltip segue o mouse (followMouse default).
            self.toolRender.followMouse = true
            local gmx = getMouseX()
            local gmy = getMouseY()
            tx = gmx + 15
            ty = gmy + 15
        else
            -- Cursor virtual: desliga o followMouse — o ISToolTipInv:render
            -- reposicionaria no mouse todo frame; com followMouse=false ele
            -- respeita o setX/setY abaixo (posição da célula do cursor).
            self.toolRender.followMouse = false
        end
        
        if self.toolRender.width and (tx + self.toolRender.width > getCore():getScreenWidth()) then
            tx = tx - self.toolRender.width - 15
        end
        if self.toolRender.height and (ty + self.toolRender.height > getCore():getScreenHeight()) then
            ty = ty - self.toolRender.height - 15
        end
        
        self.toolRender:setX(tx)
        self.toolRender:setY(ty)
    else
        if self.toolRender then
            self.toolRender:removeFromUIManager()
            self.toolRender:setVisible(false)
            self.toolRender = nil
        end
    end
end

function GridRender:update()
    ISPanel.update(self)
    self:updateTooltip()

    -- Auto-Search edge-trigger: só ativa quando o container ACABA de se tornar o alvo ativo.
    -- Usa tabela global por container (sobrevive rebuilds dos grids — o hash muda
    -- a cada frame de search, o que recria as instâncias GridRender).
    local autoSearchKey = tostring(self.playerNum) .. ":" .. tostring(self:searchKey())

    local isTargetActive = false
    if not self:isUnderCollapsedPage() and self:isVisible() and self.parent:isVisible() then
        local pLoot = getPlayerLoot(self.playerNum)
        local pInv = getPlayerInventory(self.playerNum)
        local pLootVis = pLoot and pLoot:getIsVisible()
        local pInvVis = pInv and pInv:getIsVisible()
        if (pLootVis and pLoot.inventory == self.inventoryContainer) or (pInvVis and pInv.inventory == self.inventoryContainer) then
            isTargetActive = true
        end
    end

    if isTargetActive then
        if not _autoSearchDone[autoSearchKey] then
            _autoSearchDone[autoSearchKey] = true
            if GridModOptions.cache.autoSearch and self:needsSearch() and not self._searchActive then
                self:startSearch()
            end
        end
    else
        -- Container não é mais ativo: limpa pra poder re-trigger se voltar
        _autoSearchDone[autoSearchKey] = nil
    end

    -- Itens com ação de transferência na fila (pra safe-guard de ghost).
    local q = ISTimedActionQueue.getTimedActionQueue(getSpecificPlayer(self.playerNum))
    local activeTransfers = {}
    if q and q.queue then
        -- IMPORTANTE: o ISTimedActionQueue NÃO tem campo `action` — a ação
        -- atual é `queue[1]` e os transfers enfileirados depois ficam em
        -- `queue[i]`. O ISInventoryTransferAction:checkQueueList() absorve
        -- TODOS os transfers seguintes pro queueList da ação atual (queue[1]) —
        -- mesmo com peso > 0.1 cada item ganha entrada própria (o limite de
        -- 0.1 só decide merge em lote; a absorção acontece sempre). Sem varrer
        -- o queueList de cada ação na fila, o ciclo de vida do InTransit via
        -- "not activeTransfers" acha que itens AINDA em transferência foram
        -- cancelados → restaura a posição pra origem → ao chegar no alvo
        -- posValid=false → caem no autoFill. Era isso que fazia só os 2
        -- primeiros itens caírem no x,y (o 1º transfere no perform imediato; o
        -- 2º fica como action.item da queue[1] durante a 1ª janela; o 3º+ era
        -- cancelado no frame seguinte à absorção).
        for i = 1, #q.queue do
            local act = q.queue[i]
            if act.item and type(act.item) == "userdata" and act.item.getID then
                activeTransfers[act.item:getID()] = true
            end
            if act.queueList then
                for j = 1, #act.queueList do
                    local entry = act.queueList[j]
                    if entry and entry.items then
                        for k = 1, #entry.items do
                            local it = entry.items[k]
                            if it and type(it) == "userdata" and it.getID then
                                activeTransfers[it:getID()] = true
                            end
                        end
                    end
                end
            end
        end
    end

    local ghosts = self.gridCore and self.gridCore.ghostItems
    if ghosts then
        -- Checa presença sem `next` (não exposto no ambiente Kahlua do jogo):
        -- usa pairs e quebra no primeiro par pra não montar activeTransfers à toa.
        local anyGhost = false
        for _ in pairs(ghosts) do
            anyGhost = true
            break
        end

        if anyGhost then
            local currentTime = getTimeInMillis()
            for gId, gData in pairs(ghosts) do
                -- Safe-guard de ghost preso (sem InTransit): remove se não há
                -- transfer pendente E o item NÃO está em trânsito E já passou 500ms.
                -- Ghost de REORDER (reorderPending) é gerenciado pela própria
                -- GridReorderAction (add no enqueue, remove no perform/stop) —
                -- NÃO pode cair nesse guard, senão some no meio da ação.
                if not gData.reorderPending
                    and not activeTransfers[gId]
                    and not (GridInventory_InTransit and GridInventory_InTransit[gId])
                    and (currentTime - gData.timeAdded > 500) then
                    self.gridCore:removeGhostItem(gId)
                end
            end
        end
    end

    -- Ciclo de vida do InTransit (roda todo frame). Sinais CONFIÁVEIS:
    --  - saiu da ORIGEM (item:getContainer() != source) → entregue (alvo ou
    --    overflow) → libera. Usa o item GUARDADO no registro (não o ghost) —
    --    o refreshContainer DESTRÓI/recria o GridRender, então o ghost e o
    --    info.grid ficam stale após a transferência.
    --  - chegou no grid alvo (colocado) → libera;
    --  - cancelada/presa (item nunca saiu da origem) → libera após 5s.
    if GridInventory_InTransit then
        local now = getTimeInMillis()
        for itemId, info in pairs(GridInventory_InTransit) do
            local item = info and info.item
            local isTarget = info and info.grid == self
            local placedHere = isTarget and self.gridCore.items[itemId] and not (ghosts and ghosts[itemId])
            local movedAway = item and item.getContainer and info.source
                and item:getContainer() ~= info.source
            -- "stuck" só pode liberar item que NÃO está mais referenciado por
            -- NENHUMA transferência (nem action.item, nem queueList, nem queue).
            -- Transferência em lote de 100 twines demora ~100s: sem isso o guard
            -- de 5s limparia o InTransit no meio e restauraria a posição.
            local stuck = info.startedAt and (now - info.startedAt > 5000)
                and not activeTransfers[itemId]
            local cancelled = item and item.getContainer and info.source
                and item:getContainer() == info.source
                and not activeTransfers[itemId]

            if placedHere or movedAway or stuck or cancelled then
                if cancelled and info.previousX and info.previousY then
                    local md = item:getModData()
                    md.gridX = info.previousX
                    md.gridY = info.previousY
                    md.gridRot = info.previousRot or false
                    md.gridContainer = info.previousContainer
                    local sourceGrid = GridContainer.getOrCreate(item:getContainer(), self.playerNum)
                    sourceGrid:refresh()
                end
                -- Item ENTREGUE ao destino (saiu da origem): o grid do destino
                -- precisa re-renderizar agora — senão o item recém-chegado (ex.:
                -- de dentro de uma bolsa no porta-malas) só aparece no próximo
                -- refresh forçado (re-selecionar o container).
                if movedAway and item and item.getContainer and GridClientNetwork then
                    GridClientNetwork.markGridChanged(item:getContainer(), self.playerNum)
                end
                if ghosts and ghosts[itemId] then
                    self.gridCore:removeGhostItem(itemId)
                end
                GridInventory_InTransit[itemId] = nil
            end
        end
    end

    -- Se o mouse foi solto (em qualquer lugar da tela) — SÓ pro drag de MOUSE.
    -- O drag de JOYPAD não usa o mouse: `isMouseButtonDown(0)` é sempre falso,
    -- então este bloco LIMPARIA o drag todo frame (o preview verde piscava 1
    -- frame e o item "caía" — o drag de joypad tem o próprio ciclo A/B).
    if GridInventory_GlobalDrag and not GridInventory_GlobalDrag.joypad
        and GridInventory_GlobalDrag.sourceGrid == self and not isMouseButtonDown(0) then
        -- Drop em cima de uma bolsa (caminho próprio do mod): transfere pra
        -- dentro da bolsa e limpa. Idempotente com o vanilla: se o
        -- dropItemsInContainer já transferiu, o GridInventory_GlobalDrag já
        -- foi zerado e isto é no-op. Volta cedo pra não cair no drop-no-chão.
        if GridInventory_BagDrop.tryHandleMouseUp(self.playerNum) then
            return
        end

        local mx = getMouseX()
        local my = getMouseY()
        local uis = UIManager.getUI()
        local mouseOverUI = false
        
        -- Zomboid loop pra ver se o mouse soltou em cima de alguma interface
        for i=0,uis:size()-1 do
            local ui = uis:get(i)
            if ui:isPointOver(mx, my) then
                mouseOverUI = true
                break
            end
        end

        -- Se não soltou em nenhuma UI, significa que soltou no chão (Mundo 3D)!
        if not mouseOverUI then
            for _, draggedItem in ipairs(GridInventory_GlobalDrag.itemsData) do
                if draggedItem and draggedItem.itemObj then
                    ISInventoryPaneContextMenu.dropItem(draggedItem.itemObj, self.playerNum)
                end
            end
        end

        -- Independente se caiu no chão, no Loot, ou no vácuo, limpar a renderização global
        if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid then
            GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
        end
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
        self.draggingMarquis = false
    end
    
    if not isMouseButtonDown(0) then
        self.clickedItemId = nil
        if self.draggingMarquis then
            self.draggingMarquis = false
            -- Seleção termina fora do painel
        end
    end
end

-- Expõe a borda em degrade pro GlobalDragRender (ghost do drag) reusar a MESMA
-- lógica visual do item posicionado.
GridRender.drawGradientBorder = drawGradientBorder

return GridRender
