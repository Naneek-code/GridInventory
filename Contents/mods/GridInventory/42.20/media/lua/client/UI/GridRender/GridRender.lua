--- GridRender.lua
--- O coração visual do GridInventory. 
--- Responsável por desenhar a malha de fundo (os quadrados) e sobrepor os itens nela.

require "ISUI/ISPanel"
require "TimedActions/ISUnequipAction"
local ItemFootprint = require("Algorithm/ItemFootprint")
local GridContainer = require("DataModel/GridContainer")
local GridClientNetwork = require("Network/GridClientNetwork")

GridRender = ISPanel:derive("GridRender")

-- Configurações visuais do nosso estilo "Tarkov"

local GridRender = ISPanel:derive("GridRender")
local GRID_PADDING = 10
local ITEM_BG_COLOR = {r=0.4, g=0.4, b=0.4, a=0.5}
local ITEM_BG_FROZEN = {r=0.2, g=0.6, b=0.9, a=0.5}
local ITEM_BG_HOT = {r=0.9, g=0.2, b=0.2, a=0.5}

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

--- Capacidade de PESO real de um container: o teto que o jogo realmente aplica
--- (getEffectiveCapacity — o MESMO usado pelo hasRoomFor pra bloquear). Ex.: o
--- inventário do jogador mostra getMaxWeight() = 12 ("confortável", força), mas
--- o jogador consegue carregar até getEffectiveCapacity = 50. Usar o teto real
--- evita "Overloaded" prematuro (o jogador ainda cabe). Fallback pra getMaxWeight
--- / getCapacity se getEffectiveCapacity não existir.
local function gridCapacity(container, playerObj)
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
    local headerH = 28
    if noHeader then headerH = 0 end
    local width = (gridCore.width * 40) + (GRID_PADDING * 2)
    local height = (gridCore.height * 40) + (GRID_PADDING * 2) + headerH
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.gridCore = gridCore
    o.inventoryContainer = inventoryContainer
    o.containerItem = containerItem
    o.gridIndex = gridIndex or 1
    o.fallbackIcon = fallbackIcon
    o.headerH = headerH
    o.cellSize = 40
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
    local active = {}

    -- Favorito
    if item.isFavorite and item:isFavorite() then
        table.insert(active, self.icons.favorite)
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

function GridRender:drawItemIconRotated(item, x, y, w, h, isRotated, r, g, b, a)
    if not item then return end
    local texture = item:getTex() or item:getTexture()
    if not texture then return end
    
    r = r or 1
    g = g or 1
    b = b or 1
    a = a or 1
    
    local texW = texture:getWidth()
    local texH = texture:getHeight()
    
    local isCustomTint = (r ~= 1 or g ~= 1 or b ~= 1)
    
    -- Itens com máscara de fluido NÃO passam pelo DrawItemIcon nativo nem na
    -- posição normal: o Java desenha a máscara com geometria própria que, em
    -- alguns itens, nasce 1px menor que o conteúdo do item. O caminho manual
    -- abaixo (SpriteRenderer com UVs) renderiza a máscara alinhada e no tamanho
    -- exato da textura base — o mesmo já usado nos itens rotacionados.
    local hasFluidMask = item.getTextureFluidMask and item:getTextureFluidMask() ~= nil
    
    if not isRotated and not isCustomTint and not hasFluidMask then
        -- Quando não há rotação, tint especial nem máscara de fluido, usamos o
        -- renderizador NATIVO (DrawItemIcon).
        -- Para evitar as margens invisíveis do jogo e deixar o item igualzinho ao tamanho real do Grid:
        -- Calculamos a escala baseada nos pixels VISÍVEIS (getWidth).
        local scale = math.min(w / texW, h / texH)
        
        -- Descobrimos o tamanho que a imagem "com margens" (getWidthOrig) deve ter para o miolo bater na escala
        local fullW = texture:getWidthOrig() * scale
        local fullH = texture:getHeightOrig() * scale
        
        -- Centralizamos o "miolo visível" (croppedW/H) dentro do Grid (w/h)
        local croppedW = texW * scale
        local croppedH = texH * scale
        local centerOffsetX = (w - croppedW) / 2
        local centerOffsetY = (h - croppedH) / 2
        
        -- Subtraímos o offset nativo do jogo (margem da esquerda/topo) pra anular o padding original do DrawItemIcon
        local relX = x + centerOffsetX - (texture:getOffsetX() * scale)
        local relY = y + centerOffsetY - (texture:getOffsetY() * scale)
        
        self.javaObject:DrawItemIcon(item, relX, relY, a, fullW, fullH)
    else
        -- Fallback manual (para itens deitados E para itens com máscara de
        -- fluido na posição normal). Usa geometria de vértices nativos do
        -- DrawTexture + SpriteRenderer com UVs (recorte de volume d'água).
        local visualTexW = isRotated and texH or texW
        local visualTexH = isRotated and texW or texH
        local scale = math.min(w / visualTexW, h / visualTexH)
        
        local drawW = (isRotated and texH or texW) * scale
        local drawH = (isRotated and texW or texH) * scale
        
        local offsetX = (w - drawW) / 2
        local offsetY = (h - drawH) / 2
        
        local absX = self:getAbsoluteX() + x + offsetX
        local absY = self:getAbsoluteY() + y + offsetY
        
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
        
        local renderTex = function(texToDraw, red, green, blue)
            if not isRotated then
                self.javaObject:DrawTexture(texToDraw, absX, absY, absX+drawW, absY, absX+drawW, absY+drawH, absX, absY+drawH, red, green, blue, a)
            else
                self.javaObject:DrawTexture(texToDraw, absX, absY+drawH, absX, absY, absX+drawW, absY, absX+drawW, absY+drawH, red, green, blue, a)
            end
        end
        
        -- Textura Base (já vem com a sprite de queimado/podre graças ao getTex())
        renderTex(texture, finalR, finalG, finalB)
        
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
end

--- Badge de contagem no canto inferior-direito da célula: mostra o NÚMERO DE
--- ITENS na pilha (getStackSize), não a soma de getCount() — o jogador quer
--- saber quantos itens estão empilhados naquela célula.
function GridRender:drawStackCountBadge(itemId, drawX, drawY, drawW, drawH)
    local total = self.gridCore and self.gridCore:getStackSize(itemId) or 1
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

function GridRender:render()
    local mouseX = self:getMouseX()
    local mouseY = self:getMouseY()
    
    if self.headerH and self.headerH > 0 then
        self:drawRect(GRID_PADDING, GRID_PADDING, self.width - (GRID_PADDING*2), self.headerH - 4, 0.5, 0.1, 0.1, 0.1)
        
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
            self:drawRectBorder(GRID_PADDING, GRID_PADDING, self.width - (GRID_PADDING*2), self.headerH - 4, 0.9, 1.0, 0.9, 0.3)
        else
            self:drawRectBorder(GRID_PADDING, GRID_PADDING, self.width - (GRID_PADDING*2), self.headerH - 4, 0.8, 0.3, 0.3, 0.3)
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
            if self.inventoryContainer:getType() == "floor" then
                text = getTextOrNull("IGUI_ContainerTitle_floor") or "Floor"
            elseif self.inventoryContainer:getType() == "inventory" or self.inventoryContainer:getType() == "none" then
                text = getTextOrNull("IGUI_InventoryTooltip") or "Inventory"
            else
                local cType = self.inventoryContainer:getType()
                text = getTextOrNull("IGUI_ContainerTitle_" .. tostring(cType)) or cType
            end
            tex = self.fallbackIcon
        end
        
        if self.gridIndex and self.gridIndex > 1 then
            text = text .. " (Overflow)"
        end
        
        local textX = GRID_PADDING + 5
        if tex then
            self:drawTextureScaledAspect(tex, textX, GRID_PADDING + 2, 20, 20, 1, 1, 1, 1)
            textX = textX + 25
        end

        -- ── PESO: calcula o TEXTO e a COR antes de desenhar qualquer coisa,
        -- só pra saber a largura que ele vai ocupar (ainda não desenha na tela).
        -- O DISPLAY mantém o getMaxWeight() (a capacidade "confortável" do
        -- personagem, ex.: 12) — é o que o jogador enxerga no vanilla. O teto
        -- real (getEffectiveCapacity, ex.: 50) só é usado no FEEDBACK.
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
        local weightReservedWidth = 0
        if weightStr then
            weightReservedWidth = getTextManager():MeasureStringX(UIFont.Small, weightStr) + 10
        end

        -- ── NOME: agora que já sabemos quanto espaço sobra, trunca e desenha.
        local titleMaxWidth = (self.width - GRID_PADDING - 5) - textX - weightReservedWidth
        local displayText = truncateText(text, titleMaxWidth, UIFont.Small)
        self:drawText(displayText, textX, GRID_PADDING + 4, 0.9, 0.9, 0.9, 1, UIFont.Small)

        -- ── PESO: desenha por último, já com texto e cor prontos de antes.
        if weightStr then
            local rightX = self.width - GRID_PADDING - 5
            self:drawTextRight(weightStr, rightX, GRID_PADDING + 4, weightR, weightG, weightB, 1, UIFont.Small)
        end
    end

    -- Desenha a malha do grid (os quadrados de cada slot)
    for col = 1, self.gridCore.width do
        for row = 1, self.gridCore.height do
            local cellX = GRID_PADDING + ((col - 1) * self.cellSize)
            local cellY = GRID_PADDING + (self.headerH or 0) + ((row - 1) * self.cellSize)
            
            -- Mantém a transparência natural preta, desenhando APENAS a borda
            self:drawRectBorder(cellX, cellY, self.cellSize, self.cellSize, 0.15, 0.5, 0.5, 0.5)
        end
    end

    local playerObj = getSpecificPlayer(self.playerNum)
    local hotbar = getPlayerHotbar(self.playerNum)

    -- Membros de pilha: mesmo sem render individual, precisam do tick de
    -- idade/umidade (o vanilla faz isso ao renderizar itens em containers
    -- visíveis). Só o LÍDER desenha o ícone.
    for itemId, data in pairs(self.gridCore.items) do
        if data.stackMemberOf and data.itemObj then
            if data.itemObj.updateAge then data.itemObj:updateAge() end
            if data.itemObj.updateWetness then data.itemObj:updateWetness() end
        end
    end

    for itemId, data in pairs(self.gridCore.items) do
        -- Membros de pilha não são desenhados individualmente: só o LÍDER
        -- renderiza (ícone + badge de contagem). As células apontam pro líder.
        if data.stackMemberOf then
            -- skip
        else
        -- Se estivermos arrastando, não renderizamos o item localmente se for um dos arrastados.
        local isDragged = GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid == self and GridInventory_GlobalDrag.itemsMap[itemId]
        
        if not isDragged then
            local drawX = GRID_PADDING + ((data.x - 1) * self.cellSize)
            local drawY = GRID_PADDING + (self.headerH or 0) + ((data.y - 1) * self.cellSize)
            
            local drawW = data.w * self.cellSize
            local drawH = data.h * self.cellSize

            local isSelected = self.selectedItems[itemId]

            if data.itemObj then
                -- B42/B41 Fix: O motor do Zomboid delega o tick de idade e umidade das roupas e comidas à renderização da UI (se estiver num container visível).
                -- Como pulamos o renderdetails do Vanilla, temos que disparar o update nós mesmos!
                if data.itemObj.updateAge then data.itemObj:updateAge() end
                if data.itemObj.updateWetness then data.itemObj:updateWetness() end
                
                local bgR, bgG, bgB, bgA = ITEM_BG_COLOR.r, ITEM_BG_COLOR.g, ITEM_BG_COLOR.b, ITEM_BG_COLOR.a
                
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
                
                if (data.itemObj.isFrozen and data.itemObj:isFrozen()) or freezeTime > 0 or heat < 0.99 then
                    -- Frio / Congelando
                    local t = math.max(freezeTime, invHeat)
                    if data.itemObj.isFrozen and data.itemObj:isFrozen() then t = 1.0 end
                    
                    bgR = ITEM_BG_COLOR.r + (ITEM_BG_FROZEN.r - ITEM_BG_COLOR.r) * t
                    bgG = ITEM_BG_COLOR.g + (ITEM_BG_FROZEN.g - ITEM_BG_COLOR.g) * t
                    bgB = ITEM_BG_COLOR.b + (ITEM_BG_FROZEN.b - ITEM_BG_COLOR.b) * t
                elseif heat > 1.01 then
                    -- Quente
                    local t = invHeat
                    bgR = ITEM_BG_COLOR.r + (ITEM_BG_HOT.r - ITEM_BG_COLOR.r) * t
                    bgG = ITEM_BG_COLOR.g + (ITEM_BG_HOT.g - ITEM_BG_COLOR.g) * t
                    bgB = ITEM_BG_COLOR.b + (ITEM_BG_HOT.b - ITEM_BG_COLOR.b) * t
                end
                
                if isSelected then
                    self:drawRect(drawX, drawY, drawW, drawH, bgA + 0.3, bgR + 0.3, bgG + 0.3, bgB + 0.3)
                else
                    self:drawRect(drawX, drawY, drawW, drawH, bgA, bgR, bgG, bgB)
                end
                
                self:drawRectBorder(drawX, drawY, drawW, drawH, 1, 0.7, 0.8, 1.0)

                self:drawItemIconRotated(data.itemObj, drawX, drawY, drawW, drawH, data.rotated, 1, 1, 1, 1)
                
                -- ── Ícones de status (sistema flex) ─────────────────────────────────
                self:drawItemStatusIcons(data.itemObj, drawX + 2, drawY + 2, playerObj, hotbar)
                
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

                -- Badge de contagem da pilha (soma de getCount() dos membros)
                if self.gridCore:getStackSize(itemId) > 1 then
                    self:drawStackCountBadge(itemId, drawX, drawY, drawW, drawH)
                end
            end
        end
    end
    end
    if self.gridCore.ghostItems then
        for gId, gData in pairs(self.gridCore.ghostItems) do
            local drawX = GRID_PADDING + ((gData.x - 1) * self.cellSize)
            local drawY = GRID_PADDING + (self.headerH or 0) + ((gData.y - 1) * self.cellSize)
            local drawW = gData.w * self.cellSize
            local drawH = gData.h * self.cellSize
            
            -- Fundo translúcido cinza para indicar fantasma
            self:drawRect(drawX, drawY, drawW, drawH, 0.3, 0.5, 0.5, 0.5)
            self:drawRectBorder(drawX, drawY, drawW, drawH, 0.5, 0.7, 0.7, 0.7)
            
            if gData.itemObj then
                -- Desenha o item com 50% de opacidade
                self:drawItemIconRotated(gData.itemObj, drawX, drawY, drawW, drawH, gData.rotated, 1, 1, 1, 0.5)
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

    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.itemsData and #GridInventory_GlobalDrag.itemsData > 0 then
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
            if firstItem.isFavorite and firstItem:isFavorite() and not isInPlayerInv then
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
                    msg = string.format(getText("IGUI_OverloadedPartial") or "Only %d of %d fit", fitsToAdd, totalToAdd)
                end
                self:drawTextCentre(msg, self.width/2, self.height/2 - 10, 1, 0.2, 0.2, 1, UIFont.Large)

            -- Cabe no peso, mas o hasRoomFor vanilla ainda recusa. Só confiamos
            -- nele quando NENHUM item arrastado já está na árvore do container
            -- alvo (senão ele conta o peso 2x e recusa por engano).
            elseif not anyInTree and not self.inventoryContainer:hasRoomFor(playerObj, firstItem) then
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
end

-- ============================================================================
-- SISTEMA DE DRAG AND DROP E CONTEXT MENU
-- ============================================================================

function GridRender:getGridCellAtMouse(x, y)
    local col = math.floor((x - GRID_PADDING) / self.cellSize) + 1
    local row = math.floor((y - GRID_PADDING - (self.headerH or 0)) / self.cellSize) + 1
    if col >= 1 and col <= self.gridCore.width and row >= 1 and row <= self.gridCore.height then
        return col, row
    end
    return nil, nil
end

function GridRender:onMouseDown(x, y)
    -- Verifica se clicou no Header!
    if self.headerH and self.headerH > 0 then
        if y >= GRID_PADDING and y <= GRID_PADDING + self.headerH then
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
        -- Ctrl num item EMPILHADO: marca o "peel". Sem arrasto (mouse-up) abre
        -- o STACK PICKER; com arrasto (Ctrl+drag) tira 1 item da pilha e inicia
        -- o drag com ele (maneira rápida de pegar 1 da pilha sem abrir painel).
        if isCtrlKeyDown() and self.gridCore:getStackSize(itemId) > 1 then
            self.ctrlStackPeel = itemId
            self.lastManualClickTime = nil
            self.lastManualClickItemId = nil
            self.selectedItems = {}
        end

        if isShiftKeyDown() then
            self.selectedItems[itemId] = not self.selectedItems[itemId]
            self.lastManualClickTime = nil
            self.lastManualClickItemId = nil
            return -- Se tá segurando shift só marca/desmarca, não arrasta e não ativa duplo clique
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
    -- O Zomboid chama isso se os pixels não mudarem mais de 5 e for dentro de 500ms.
    -- Como nós já interceptamos no onMouseDown de forma mais robusta, apenas chamamos nosso método.
    self:doDoubleClick(x, y)
    return true
end

function GridRender:onMouseUp(x, y)
    -- Ctrl+CLIQUE (sem arrasto) num stack: abre o STACK PICKER. Se foi um
    -- Ctrl+DRAG, o flag já foi consumido no onMouseMove (peel de 1 item).
    if self.ctrlStackPeel and not GridInventory_GlobalDrag
        and not (ISMouseDrag.dragging and #ISMouseDrag.dragging > 0) then
        local peelId = self.ctrlStackPeel
        self.ctrlStackPeel = nil
        if GridInventory_openStackPicker then
            GridInventory_openStackPicker(self.playerNum, self, peelId)
        end
        return
    end
    self.ctrlStackPeel = nil
    self.clickedItemId = nil
    if self.draggingMarquis then
        self.draggingMarquis = false
        local mX = self:getMouseX()
        local mY = self:getMouseY()
        
        local rx = math.min(self.marquisStartX, mX)
        local ry = math.min(self.marquisStartY, mY)
        local rw = math.abs(mX - self.marquisStartX)
        local rh = math.abs(mY - self.marquisStartY)
        
        for itemId, data in pairs(self.gridCore.items) do
            local itemX = GRID_PADDING + ((data.x - 1) * self.cellSize)
            local itemY = GRID_PADDING + (self.headerH or 0) + ((data.y - 1) * self.cellSize)
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
        local dropCol, dropRow = self:getGridCellAtMouse(x, y)
        local itemsData = GridInventory_GlobalDrag.itemsData
        
        if dropCol and dropRow then
            -- Tenta colocar todos ou nenhum (modo estrito para evitar perda de itens)
            local allCanPlace = true
            local targets = {}
            
            -- Set de TODOS os itens em movimento: arrastar uma PILHA inteira
            -- significa que os membros ainda ocupam a origem, mas vão sair — o
            -- alvo pode sobrepor a origem sem "colidir" com eles (phantom block).
            local movedSet = {}
            for _, di in ipairs(itemsData) do
                movedSet[di.id] = true
            end
            
            for _, draggedItem in ipairs(itemsData) do
                local effectiveW = draggedItem.rotated and draggedItem.originalH or draggedItem.originalW
                local effectiveH = draggedItem.rotated and draggedItem.originalW or draggedItem.originalH
                
                local targetX = dropCol - draggedItem.grabOffsetX
                local targetY = dropRow - draggedItem.grabOffsetY
                
                if targetX < 1 then targetX = 1 end
                if targetY < 1 then targetY = 1 end
                
                if not self.gridCore:canPlaceItem(draggedItem.id, targetX, targetY, effectiveW, effectiveH, draggedItem.id, draggedItem.compatKey, draggedItem.rotated, draggedItem.stackInfo, movedSet) then
                    allCanPlace = false
                    break
                end
                
                table.insert(targets, {item = draggedItem, tx = targetX, ty = targetY, ew = effectiveW, eh = effectiveH})
            end
            
            if allCanPlace then
                -- Remove TODOS os itens movidos ANTES de inserir: inserir um a um
                -- com o alvo sobrepondo a origem faz a promoção da origem (no
                -- removeItem) sobrescrever células onde já entrou um membro no
                -- alvo → pilhas com 3+ quebram (ordem arbitrária do pairs). Limpar
                -- tudo primeiro deixa o grid livre pra reassentar a pilha inteira.
                for _, t in ipairs(targets) do
                    self.gridCore:removeItem(t.item.id)
                end
                for _, t in ipairs(targets) do
                    self.gridCore:insertItem(t.item.id, t.tx, t.ty, t.ew, t.eh, t.item.rotated, t.item.itemObj, t.item.compatKey, t.item.stackInfo, movedSet)
                    if t.item.itemObj then
                        local modData = t.item.itemObj:getModData()
                        modData.gridX = t.tx
                        modData.gridY = t.ty
                        modData.gridRot = t.item.rotated
                        modData.gridContainer = GridContainer.containerSignature(self.inventoryContainer)
                        -- MP server-mandatory: o servidor grava e broadcasta a posição.
                        GridClientNetwork.sendItemMove(self.inventoryContainer, t.item.itemObj:getID(), t.tx, t.ty, t.item.rotated, modData.gridContainer)
                    end
                end
                self.selectedItems = {} -- Limpa seleção após mover com sucesso
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
            
            local isFromPaperDoll = GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid and GridInventory_GlobalDrag.sourceGrid.slotName

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
                            -- Transfere normalmente (Sem criar fantasma)
                            -- MP: limpa a posição no servidor (auto-fit recalcula).
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
                                -- MP server-mandatory: servidor grava a posição (drop coords, não autoSlot).
                                GridClientNetwork.sendItemMove(self.inventoryContainer, itemObj:getID(), targetX, targetY, rotated, modData.gridContainer)
                                
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
        if self.inventoryContainer and self.inventoryContainer.setDrawDirty then
            self.inventoryContainer:setDrawDirty(true)
        end
        -- MP server-mandatory: servidor grava a nova posição (célula própria).
        GridClientNetwork.sendItemMove(self.inventoryContainer, member:getID(), fx, fy, false)
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
    if GridInventory_GlobalDrag then
        -- Rotaciona TODOS os itens sendo arrastados no grupo!
        for _, draggedItem in ipairs(GridInventory_GlobalDrag.itemsData) do
            draggedItem.rotated = not draggedItem.rotated
            draggedItem.grabOffsetX, draggedItem.grabOffsetY = draggedItem.grabOffsetY, draggedItem.grabOffsetX
        end
    else
        local col, row = self:getGridCellAtMouse(x, y)
        if col and row then
            local itemId = self.gridCore.cells[col][row]
            if itemId then
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
    -- Checa se o mouse está sobre esse grid E sobre o painel pai (para evitar tooltips quando scrollar o grid pra fora da view)
    local isOver = self:isMouseOver()
    if isOver and self.parent and not self.parent:isMouseOver() then
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
    
    local mx = self:getMouseX()
    local my = self:getMouseY()
    local col, row = self:getGridCellAtMouse(mx, my)
    
    local hoveredItem = nil
    if col and row and self.gridCore and self.gridCore.cells then
        local itemId = self.gridCore.cells[col][row]
        if itemId and self.gridCore.items[itemId] then
            hoveredItem = self.gridCore.items[itemId].itemObj
        end
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
            local playerObj = getSpecificPlayer(self.playerNum)
            local q = ISTimedActionQueue.getTimedActionQueue(playerObj)
            local activeTransfers = {}

            if q then
                if q.action and q.action.item and type(q.action.item) == "userdata" and q.action.item.getID then
                    activeTransfers[q.action.item:getID()] = true
                end
                if q.queue then
                    for i = 1, #q.queue do
                        local act = q.queue[i]
                        if act.item and type(act.item) == "userdata" and act.item.getID then
                            activeTransfers[act.item:getID()] = true
                        end
                    end
                end
            end

            local currentTime = getTimeInMillis()
            for gId, gData in pairs(ghosts) do
                -- Apaga o fantasma se não houver NENHUMA action pendente pra ele na queue
                -- e já tiver passado 500ms desde a criação (pra não matar no 1º frame antes da action nascer)
                if not activeTransfers[gId] and (currentTime - gData.timeAdded > 500) then
                    self.gridCore:removeGhostItem(gId)
                end
            end
        end
    end

    -- Se o mouse foi solto (em qualquer lugar da tela)
    if GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid == self and not isMouseButtonDown(0) then
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

return GridRender
