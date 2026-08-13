require "ISUI/ISCollapsableWindow"
require "XpSystem/ISUI/ISCharacterScreen"
local PaperDollSlot      = require "UI/PaperDoll/PaperDollSlot"
local AvatarUseDropZone  = require "UI/PaperDoll/AvatarUseDropZone"

local PaperDollWindow = ISCollapsableWindow:derive("PaperDollWindow")

function PaperDollWindow:initialise()
    ISCollapsableWindow.initialise(self)

    self.title = getText("IGUI_PaperDoll_Title")
    
    self.scrollPanel = ISPanel:new(0, self:titleBarHeight(), self.width, self.height - self:titleBarHeight())
    self.scrollPanel.background = false
    
    self.scrollPanel.prerender = function(this)
        this:setStencilRect(0, 0, this.width, this.height)
        ISPanel.prerender(this)
    end
    
    self.scrollPanel.render = function(this)
        ISPanel.render(this)
        this:clearStencilRect()
    end
    
    self.scrollPanel.onMouseWheel = function(this, del)
        if this:getScrollHeight() > 0 then
            this:setYScroll(this:getYScroll() - (del * 40))
            return true
        end
        return false
    end
    
    self.scrollPanel:initialise()
    self.scrollPanel:instantiate()
    self:addChild(self.scrollPanel)
    
    -- IMPORTANT: These MUST be called AFTER instantiate/addChild!
    self.scrollPanel:setScrollChildren(true)
    self.scrollPanel:addScrollBars(true)

    -- Instancia o modelo 3D do personagem
    self.avatarW = 200
    self.avatarH = 400
    self.avatarX = (self.width - self.avatarW) / 2
    self.avatarY = (self.height - self.avatarH) / 2 + 100 -- Desce o painel inteiro do personagem sem afetar a escala

    self.avatarPanel = ISCharacterScreenAvatar:new(self.avatarX, self.avatarY, self.avatarW, self.avatarH)
    self.avatarPanel:setVisible(true)
    self.scrollPanel:addChild(self.avatarPanel)
    
    local playerObj = getSpecificPlayer(self.playerNum)
    self.avatarPanel:setCharacter(playerObj)
    -- Sem estado fixo (nil): o ActionGroup dirige as transições (idle, ext...).
    -- Com "idle" fixo o AnimatedModel reaplica o estado todo frame (via
    -- setCharacter) e cancela os fidgets (EventDoExt -> ext) na hora.
    self.avatarPanel:setState(nil)
    self.avatarPanel:setDirection(IsoDirections.S)
    self.avatarPanel:setIsometric(false)
    self.avatarPanel:setZoom(0)
    self.avatarPanel:setYOffset(0) -- Mantém o personagem centralizado dentro da caixa pra não guilhotinar!
    -- Vida: fidgets/idle aleatórios (olhar ao redor, coçar, etc) e animação
    -- mesmo com o jogo pausado.
    self.avatarPanel:setDoRandomExtAnimations(true)
    self.avatarPanel.animateWhilePaused = true

    -- Criar os slots de equipamento!
    self.slots = {}
    self.overflowSlots = {}
    self.hotbarUis = {}
    self.lastWornItemsHash = ""
    self.lastHotbarHash = ""
    
    local slotW, slotH = 50, 50
    local startY = self.avatarY + 50
    local padding = 10
    
    -- Slots da Esquerda (Cabeça, Rosto, Tronco, Jaqueta, Calças, Costas)
    local leftX = self.avatarX - slotW - padding
    local leftSlots = {
        {locations = {"SCBA", "SCBAnotank", "FullTop", "FullHat", "Hat", "FullHelmet", "Head", "powerhorns", "Wig", "Scarf", "Neck"}, name = getText("IGUI_PaperDoll_Hat")},
        {locations = {"SpecialMask", "MaskFull", "MaskEyes", "Mask", "Pupils", "Eyes", "RightEye", "LeftEye"}, name = getText("IGUI_PaperDoll_Mask")},
        {locations = {"Torso1Legs1", "Jersey", "Shirt", "ShortSleeveShirt", "Tshirt", "TankTop", "UnderwearTop", "Bra", "Bandeau", "Corset"}, name = getText("IGUI_PaperDoll_Shirt")},
        {locations = {"FullSuit", "FullSuitHead", "JacketSuit", "Jacket_Down", "JacketHat_Bulky", "Jacket_Bulky", "JacketHat", "Jacket", "BathRobe", "Boilersuit", "SweaterHat", "Sweater", "LongDress", "Dress", "SMUIJumpsuitPlus", "SMUITorsoRigPlus", "SMUIWebbingPlus", "Webbing", "TorsoRigPlus2", "TorsoRig", "TorsoRig2", "TorsoExtraVestBullet", "TorsoExtraVest", "VestTexture", "TorsoExtraPlus1", "RifleSling", "AmmoStrap", "TorsoExtra"}, name = getText("IGUI_PaperDoll_Jacket")},
        {locations = {"trousers", "legs", "Kneepads", "ShinPlateRight", "ShinPlateLeft", "ThighRight", "ThighLeft", "PantsExtra", "Pants", "pants_skinny", "LongSkirt", "Skirt", "ShortPants", "ShortsShort", "Legs1", "LowerBody", "Codpiece", "UnderwearExtra2", "UnderwearExtra1", "UnderwearBottom", "Underwear", "UnderwearInner"}, name = getText("IGUI_PaperDoll_Pants")}
    }
    
    for i, sData in ipairs(leftSlots) do
        local slot = PaperDollSlot:new(leftX, startY + (i-1)*(slotH + padding), slotW, slotH, self.playerNum, sData.locations, sData.name)
        slot:initialise()
        self.scrollPanel:addChild(slot)
        table.insert(self.slots, slot)
    end
    
    -- Slots da Direita
    local rightX = self.avatarX + self.avatarW + padding
    local rightSlots = {
        {locations = {"Necklace", "Necklace_Long", "BellyButton", "Nose", "Ears", "EarTop", "LeftWrist", "RightWrist", "Left_RingFinger", "Right_RingFinger", "Left_MiddleFinger", "Right_MiddleFinger"}, name = getText("IGUI_PaperDoll_Accessories")},
        {locations = {"waistbagsComplete", "waistbags", "waistbagsf", "FannyPackBack", "FannyPackFront", "SpecialBelt", "BeltExtraHL", "BeltExtra", "Belt420", "Belt419", "Belt", "Tail"}, name = getText("IGUI_PaperDoll_Belt")},
        {locations = {"HandsLeft", "HandsRight", "Hands", "SMUIGlovesPlus"}, name = getText("IGUI_PaperDoll_Hands")},
        {locations = {"Socks"}, name = getText("IGUI_PaperDoll_Socks")},
        {locations = {"AnkleHolster", "Shoes", "SMUIBootsPlus"}, name = getText("IGUI_PaperDoll_Shoes")}
    }
    
    for i, sData in ipairs(rightSlots) do
        local slot = PaperDollSlot:new(rightX, startY + (i-1)*(slotH + padding), slotW, slotH, self.playerNum, sData.locations, sData.name)
        slot:initialise()
        self.scrollPanel:addChild(slot)
        table.insert(self.slots, slot)
    end

    local bagY = startY + 5*(slotH + padding)
    local bagX = leftX -- Mesma coluna dos slots da esquerda
    local bagSlot = PaperDollSlot:new(bagX, bagY, slotW, slotH, self.playerNum, {"Back", "LowerBack", "TorsoExtra", "Satchel"}, getText("IGUI_PaperDoll_Back"))
    bagSlot:initialise()
    self.scrollPanel:addChild(bagSlot)
    table.insert(self.slots, bagSlot)

    -- Custom Slot: Overflow (Espelhado à Bag, lado direito)
    local overflowX = rightX -- Mesma coluna dos slots da direita
    self.overflowSlot = PaperDollSlot:new(overflowX, bagY, slotW, slotH, self.playerNum, {"OVERFLOW"}, "Extra")
    self.overflowSlot:initialise()
    self.scrollPanel:addChild(self.overflowSlot)

    -- Controles de Tempo (Apenas Single Player)
    if not isClient() then
        local btnW = 18
        local btnH = 18
        local spacing = 4
        local totalW = (btnW * 5) + (spacing * 4)
        
        -- Centralizar entre a Bag e o Overflow
        local areaX = bagX + slotW
        local areaW = overflowX - areaX
        local startX = areaX + (areaW / 2) - (totalW / 2)
        local btnY = bagY + (slotH / 2) - (btnH / 2)
        
        local btnData = {
            {name = "Pause", speed = 0, imgOff = "media/ui/speedControls/Pause_Off.png", imgOn = "media/ui/speedControls/Pause_On.png"},
            {name = "Play", speed = 1, imgOff = "media/ui/speedControls/Play_Off.png", imgOn = "media/ui/speedControls/Play_On.png"},
            {name = "Fast Forward x 1", speed = 2, imgOff = "media/ui/speedControls/FFwd1_Off.png", imgOn = "media/ui/speedControls/FFwd1_On.png"},
            {name = "Fast Forward x 2", speed = 3, imgOff = "media/ui/speedControls/FFwd2_Off.png", imgOn = "media/ui/speedControls/FFwd2_On.png"},
            {name = "Wait", speed = 4, imgOff = "media/ui/speedControls/Wait_Off.png", imgOn = "media/ui/speedControls/Wait_On.png"}
        }
        
        self.timeButtons = {}
        for i, b in ipairs(btnData) do
            local btn = ISButton:new(startX + (i-1)*(btnW + spacing), btnY, btnW, btnH, "", self, function(target, button)
                if UIManager.getSpeedControls() then
                    UIManager.getSpeedControls():ButtonClicked(button.internal)
                end
            end)
            btn.internal = b.name
            btn.targetSpeed = b.speed
            btn.imgOff = b.imgOff
            btn.imgOn = b.imgOn
            btn:initialise()
            btn:instantiate()
            btn:setImage(getTexture(b.imgOff))
            btn.borderColor = {r=0, g=0, b=0, a=0}
            btn.backgroundColor = {r=0, g=0, b=0, a=0}
            btn.backgroundColorMouseOver = {r=1, g=1, b=1, a=0.2}
            
            -- Lógica visual dinâmica no prerender do botão
            local og_prerender = btn.prerender
            btn.prerender = function(self)
                og_prerender(self)
                if UIManager.getSpeedControls() then
                    local currentSpeed = UIManager.getSpeedControls():getCurrentGameSpeed()
                    local isActive = (currentSpeed == self.targetSpeed)
                    
                    self:setImage(getTexture(isActive and self.imgOn or self.imgOff))
                    
                    if self.textureColor then
                        self.textureColor.a = isActive and 1.0 or 0.35
                    end
                end
            end
            
            self.scrollPanel:addChild(btn)
            table.insert(self.timeButtons, btn)
        end
    end

    -- Custom Slots: Primary and Secondary (1x2, lado a lado, abaixo da Bag)
    local wepY = bagY + 50 + padding
    local wepW, wepH = 155, 50
    local centerX = self.width / 2

    local primarySlot = PaperDollSlot:new(centerX - wepW - 5, wepY, wepW, wepH, self.playerNum, {"PRIMARY"}, getText("IGUI_PaperDoll_Primary"))
    primarySlot:initialise()
    self.scrollPanel:addChild(primarySlot)
    table.insert(self.slots, primarySlot)

    local secondarySlot = PaperDollSlot:new(centerX + 5, wepY, wepW, wepH, self.playerNum, {"SECONDARY"}, getText("IGUI_PaperDoll_Secondary"))
    secondarySlot:initialise()
    self.scrollPanel:addChild(secondarySlot)
    table.insert(self.slots, secondarySlot)

    local thW, thH = 40, 40
    local twoHandSlot = PaperDollSlot:new(centerX - (thW / 2), wepY + (wepH / 2) - (thH / 2), thW, thH, self.playerNum, {"TWOHANDED"}, "")
    twoHandSlot:initialise()
    twoHandSlot:setVisible(false)
    self.scrollPanel:addChild(twoHandSlot)
    table.insert(self.slots, twoHandSlot)

    -- Destrói a capacidade de arrastar, redimensionar ou fechar o PaperDoll
    self.moveWithMouse = false
    self.resizable = false
    self.pin = true
    self.isCollapsed = false
    self.closeButton:setVisible(false)
    self.collapseButton:setVisible(false)
    if self.infoButton then self.infoButton:setVisible(false) end
    -- Z-INDEX: clicar no PaperDoll o traz pra frente; re-sobemos a janela
    -- flutuante junto (mesmo mecanismo do ISInventoryPage — sem flicker).
    self.onMouseDown = function(this)
        if GridInventory_raiseFloating then
            GridInventory_raiseFloating(this.playerNum)
        end
    end

    -- Bloqueia a rotação e o zoom nativos da engine (Trava a estátua)
    self.avatarPanel.onMouseDown = function() end
    self.avatarPanel.onMouseMove = function() end
    self.avatarPanel.onMouseUp = function() end
    self.avatarPanel.onMouseMoveOutside = function() end
    self.avatarPanel.onMouseUpOutside = function() end
    self.avatarPanel.onMouseWheel = function() return false end

    -- Zona de drop sobre o render 3D: arraste um item aqui para usar/consumir/beber sem context menu
    -- Encolhida um pouco para não sobrepor os slots laterais.
    local dropInset = 0
    self.avatarDropZone = AvatarUseDropZone:new(self.avatarX + dropInset, self.avatarY + dropInset,
        self.avatarW - dropInset * 2, self.avatarH - dropInset * 2, self.playerNum, self.avatarPanel)
    self.avatarDropZone:initialise()
    self.scrollPanel:addChild(self.avatarDropZone)

    -- O drop zone cobre o avatar e ficaria por cima dos botões de tempo (z-order).
    -- Traz os botões de volta para o topo para continuarem clicáveis.
    if self.timeButtons then
        for _, btn in ipairs(self.timeButtons) do
            btn:bringToTop()
        end
    end
end

-- O PaperDoll NÃO expande por conta própria: o estado de collapse é controlado
-- pelo painel de inventário (espelhado no update do ISInventoryPage). Sem esse
-- no-op, o vanilla tenta expandir ao passar o mouse na titlebar, mas o espelho
-- puxa de volta na hora — um "fight" que deixa o hover sem efeito. Expande
-- apenas quando o inv expande (passar o mouse na titlebar do INV).
function PaperDollWindow:uncollapse()
end

function PaperDollWindow:prerender()
    ISCollapsableWindow.prerender(self)

    -- Cola o PaperDoll no lado DIREITO do inventário do jogador (Modo Seguro)
    local invPage = getPlayerInventory(self.playerNum)
    if invPage and invPage:getIsVisible() then
        self:setX(invPage:getRight())
        self:setY(invPage:getY())
        -- Mantém a altura sincronizada
        if self.height ~= invPage.height then
            self:setHeight(invPage.height)
        end
    end
    
    if self.scrollPanel then
        self.scrollPanel:setHeight(self.height - self:titleBarHeight())
        self.scrollPanel:setWidth(self.width)
    end
    
    -- Fundo do Paper Doll idêntico ao do GridInventory (não desenha quando
    -- colapsado junto com o inv — só a titlebar aparece, sem borda fantasma).
    if not self.isCollapsed then
        local titleH = self:titleBarHeight()
        self:drawRect(0, titleH, self.width, self.height - titleH, 0.65, 0.08, 0.08, 0.08)
        self:drawRectBorder(0, titleH, self.width, self.height - titleH, 0.5, 0.5, 0.5, 0.5)
    end
end

function PaperDollWindow:update()
    ISCollapsableWindow.update(self)
    local playerObj = getSpecificPlayer(self.playerNum)
    if playerObj then
        -- Avatar espelha a ação atual do personagem (comer/beber/ler/bandagem/etc),
        -- só depois que a timed action começa de verdade. RODA ANTES do setCharacter:
        -- no 1o frame o animset/vars já estão setados quando o modelo é reconstruído
        -- (o substate "actions" ativa com PerformingAction válido) e, no último frame,
        -- o animset volta a "player-avatar" ANTES da rebuild, resetando o ActionContext
        -- direto pro idle -- o estado "actions" nunca é avaliado com vars limpos, então
        -- o nó default-fallback (Bob_EmoteSurrender) não é selecionado.
        if self.avatarDropZone then
            self.avatarDropZone:updateAvatarAction(playerObj)
        end

        -- Garante que o Avatar continua refletindo o personagem (roupas equipadas, sangue, etc)
        if self.avatarPanel then
            self.avatarPanel:setCharacter(playerObj)
        end
    end
    
    if playerObj then
        -- Throttle: hashing das roupas/hotbar (montagem de strings por frame)
        -- roda no maximo a cada 100ms. O setCharacter acima continua por frame
        -- (é um no-op barato, pois o modelo so e reconstruido quando muda).
        local now = getTimestampMs()
        self.lastDollHashCheck = self.lastDollHashCheck or 0
        if now - self.lastDollHashCheck >= 100 then
            self.lastDollHashCheck = now

            local wornItems = playerObj:getWornItems()
            local hash = ""
            for i=0, wornItems:size()-1 do
                local item = wornItems:get(i):getItem()
                hash = hash .. tostring(item:getID()) .. "_"
            end
            
            -- Adicionamos também as mãos ao hash!
            local prim = playerObj:getPrimaryHandItem()
            local sec = playerObj:getSecondaryHandItem()
            if prim then hash = hash .. tostring(prim:getID()) .. "_P_" end
            if sec then hash = hash .. tostring(sec:getID()) .. "_S_" end
            
            if self.lastWornItemsHash ~= hash then
                self.lastWornItemsHash = hash
                -- Avisa os PaperDollSlots que o wornItems mudou (cache de localização)
                GridInventory_WornCacheEpoch = GridInventory_WornCacheEpoch or {}
                GridInventory_WornCacheEpoch[self.playerNum] = (GridInventory_WornCacheEpoch[self.playerNum] or 0) + 1
                self:refreshOverflow(wornItems, prim, sec)
            end
            
            local hotbar = getPlayerHotbar(self.playerNum)
            if hotbar then
                hotbar:update()
                
                local hbHash = ""
                for i, slot in pairs(hotbar.availableSlot) do
                    hbHash = hbHash .. tostring(slot.slotType) .. "_" .. tostring(hotbar.attachedItems[i] and hotbar.attachedItems[i]:getID() or "0")
                end
                if self.lastHotbarHash ~= hbHash then
                    self.lastHotbarHash = hbHash
                    self:refreshHotbarUIs(hotbar)
                end
            end
        end
    end
end

-- Insere espaço antes de cada letra maiúscula que vem depois de uma minúscula
-- (ex: "HandWorking" -> "Hand Working", "DrinkingLiquid" -> "Drinking Liquid")
-- Também trata siglas seguidas de palavra (ex: "HTMLParser" -> "HTML Parser")
local function camelCaseToSpaces(str)
    if not str or str == "" then return str end

    -- Caso 1: minúscula seguida de maiúscula
    str = string.gsub(str, "(%l)(%u)", "%1 %2")

    -- Caso 2: sequência de maiúsculas seguida por Maiúscula+minúscula (siglas)
    str = string.gsub(str, "(%u)(%u%l)", "%1 %2")

    return str
end

local ACTION_TRANSLATION_KEYS = {
    ISEquipWeaponAction       = "IGUI_ActionBar_Equipping",
    ISWearClothing            = "IGUI_ActionBar_Wearing",
    ISUnequipAction           = "IGUI_ActionBar_Unequipping",
    ISInventoryTransferAction = "IGUI_ActionBar_Transferring",
    ISEatFoodAction           = "IGUI_ActionBar_Eating",
    ISDrinkFluidAction        = "IGUI_ActionBar_DrinkingFluid",
    ISReadABook               = "IGUI_ActionBar_Reading",
    ISAttachItemHotbar        = "IGUI_ActionBar_Attaching",
    ISDetachItemHotbar        = "IGUI_ActionBar_Detaching",
    ISDropItemAction          = "IGUI_ActionBar_Dropping",
    ISGrabItemAction          = "IGUI_ActionBar_Grabbing",
    ISReloadWeaponAction      = "IGUI_ActionBar_Reloading",
    ISRackFirearm             = "IGUI_ActionBar_RackingFirearm",
    ISTakeWaterAction         = "IGUI_ActionBar_TakeWater",
    GridReorderAction         = "IGUI_ActionBar_GridReorder",
    GridSearchAction          = "IGUI_ActionBar_Searching"
}

function PaperDollWindow:render()
    ISCollapsableWindow.render(self)
    local playerObj = getSpecificPlayer(self.playerNum)
    if not playerObj then return end
    -- Colapsado: só a titlebar aparece (o maxDrawHeight clipa os children,
    -- mas este desenho é feito no render() do próprio painel, depois do
    -- clearStencilRect — sem o guard ele vazaria a barra de progresso).
    if self.isCollapsed then return end
    if ISTimedActionQueue then
        local queue = ISTimedActionQueue.getTimedActionQueue(playerObj)
        if queue and queue.queue and queue.queue[1] then
            local action = queue.queue[1]
            if action.getJobDelta then
                local progress = action:getJobDelta()
                if progress > 0 and progress <= 1 then
                    local barW = self.avatarW - 20
                    local barH = 15
                    local barX = self.avatarX + 10
                    local scrollOffset = self.scrollPanel and self.scrollPanel:getYScroll() or 0
                    local barY = self.avatarY - 20 + scrollOffset + self:titleBarHeight()

                    local actionName = getText("IGUI_ActionBar_Generic")
                    if action.Type then
                        local t = tostring(action.Type)
                        local key = ACTION_TRANSLATION_KEYS[t]
                        if key then
                            actionName = getText(key)
                        else
                            -- Sem mapeamento: fallback com espaçamento automático, não traduzido.
                            actionName = string.gsub(t, "^IS", "")
                            actionName = string.gsub(actionName, "Action$", "")
                            actionName = camelCaseToSpaces(actionName)
                        end
                    end

                    self:drawTextCentre(actionName, barX + (barW/2), barY - 18, 1, 1, 1, 1, UIFont.Small)
                    self:drawRect(barX, barY, barW, barH, 0.7, 0, 0, 0)
                    self:drawRectBorder(barX, barY, barW, barH, 1.0, 0.4, 0.4, 0.4)
                    self:drawRect(barX + 2, barY + 2, (barW - 4) * progress, barH - 4, 0.9, 0, 0.6, 0)
                end
            end
        end
    end
end

function PaperDollWindow:refreshOverflow(wornItems, prim, sec)
    local fixedSlotsMap = {}
    for _, s in ipairs(self.slots) do
        if s.getEquippedItems then
            local items = s:getEquippedItems()
            for _, it in ipairs(items) do
                fixedSlotsMap[it] = true
            end
        end
    end
    
    self.overflowSlot.itemsList = {}
    
    local function addIfMissing(item)
        if not item or fixedSlotsMap[item] then return end
        if item.isHidden and item:isHidden() then return end
        table.insert(self.overflowSlot.itemsList, item)
    end
    
    addIfMissing(prim)
    addIfMissing(sec)
    
    for i=0, wornItems:size()-1 do
        local wornItem = wornItems:get(i)
        addIfMissing(wornItem:getItem())
    end
end

function PaperDollWindow:refreshHotbarUIs(hotbar)
    for _, ui in ipairs(self.hotbarUis) do
        self:removeChild(ui)
    end
    self.hotbarUis = {}
    
    local numSlots = 0
    for _ in pairs(hotbar.availableSlot) do numSlots = numSlots + 1 end
    if numSlots == 0 then 
        self.hotbarBottomY = self.avatarY + 484
        self.scrollPanel:setScrollHeight(self.hotbarBottomY + 40)
        return 
    end
    
    local padding = 10
    local centerX = self.width / 2
    local startY = self.avatarY + 470 -- Abaixo das mãos (wepY + wepH + padding)
    
    local function createHotbarSlot(x, y, w, h, slotObj)
        if not slotObj then return end
        local slotName = getTextOrNull("IGUI_HotbarAttachment_" .. slotObj.data.slotType) or slotObj.data.name
        
        local ui = PaperDollSlot:new(x, y, w, h, self.playerNum, {"HOTBAR_" .. tostring(slotObj.idx)}, slotName)
        ui.hotbarRef = hotbar
        ui.hotbarSlotIndex = slotObj.idx
        ui.hotbarProviderTexture = slotObj.data.texture
        ui.hotbarSlotDef = slotObj.data.def
        
        ui:initialise()
        self.scrollPanel:addChild(ui)
        table.insert(self.hotbarUis, ui)
    end
    
    -- Intercepta Back e Belt para o layout customizado da primeira linha!
    local backSlot, beltLeft, beltRight
    local remainingSlots = {}
    
    for slotIndex, slot in pairs(hotbar.availableSlot) do
        local stype = string.lower(slot.slotType or "")
        stype = string.gsub(stype, " ", "") -- remove espaços para match seguro
        if string.find(stype, "back") then backSlot = {idx=slotIndex, data=slot}
        elseif string.find(stype, "beltleft") then beltLeft = {idx=slotIndex, data=slot}
        elseif string.find(stype, "beltright") then beltRight = {idx=slotIndex, data=slot}
        else remainingSlots[slotIndex] = slot end
    end
    
    -- Agrupa slots restantes pelo provider (textura do item)
    local groups = {}
    local groupOrder = {}
    
    for slotIndex, slot in pairs(remainingSlots) do
        local texStr = "none"
        if slot.texture then
            texStr = tostring(slot.texture:getName())
        end
        
        if not groups[texStr] then
            groups[texStr] = {}
            table.insert(groupOrder, texStr)
        end
        table.insert(groups[texStr], {idx=slotIndex, data=slot})
    end
    
    local curY = startY
    
    -- Custom Row: Back (grande), Belts
    if backSlot or beltLeft or beltRight then
        local rowH = 64
        local backW, backH = 128, 64
        local beltSize = 64
        
        local totalW = 0
        if backSlot then totalW = totalW + backW end
        if beltLeft then totalW = totalW + (totalW > 0 and padding or 0) + beltSize end
        if beltRight then totalW = totalW + (totalW > 0 and padding or 0) + beltSize end
        
        local currentX = centerX - (totalW / 2)
        
        if backSlot then
            createHotbarSlot(currentX, curY, backW, backH, backSlot)
            currentX = currentX + backW + padding
        end
        
        if beltLeft then
            createHotbarSlot(currentX, curY + (rowH/2) - (beltSize/2), beltSize, beltSize, beltLeft)
            currentX = currentX + beltSize + padding
        end
        
        if beltRight then
            createHotbarSlot(currentX, curY + (rowH/2) - (beltSize/2), beltSize, beltSize, beltRight)
        end
        
        curY = curY + rowH + padding
    end
    
    -- Para cada grupo de slots que vieram do mesmo item, renderiza-os lado a lado!
    for _, texStr in ipairs(groupOrder) do
        local slotsInGroup = groups[texStr]
        local numInGroup = #slotsInGroup
        local slotSize = 64
        
        local totalW = (numInGroup * slotSize) + ((numInGroup - 1) * padding)
        local startX = centerX - (totalW / 2)
        
        -- Garante a simetria ao ordenar pelo índice (ex: Left primeiro, Right depois se houver padrão)
        table.sort(slotsInGroup, function(a, b) return a.idx < b.idx end)
        
        for i, slotObj in ipairs(slotsInGroup) do
            createHotbarSlot(startX + (i-1)*(slotSize + padding), curY, slotSize, slotSize, slotObj)
        end
        
        curY = curY + slotSize + padding
    end
    
    self.hotbarBottomY = curY
    self.scrollPanel:setScrollHeight(curY + 40)
    self.lastWornItemsHash = "" -- Força o overflow a reposicionar abaixo da hotbar no próximo frame
end

function PaperDollWindow:new(x, y, width, height, playerNum)
    local o = ISCollapsableWindow:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.title = "Equipamentos"
    o.playerNum = playerNum
    o.resizable = false
    return o
end

return PaperDollWindow
