--- AvatarUseDropZone.lua
--- Painel invisível sobre o render 3D do personagem no PaperDoll.
---
--- Quando um item é arrastado e solto sobre essa área, o mod NÃO constrói
--- nenhuma ação por conta própria. Em vez disso, ele monta o context menu
--- VANILLA do item (ISInventoryPaneContextMenu.createMenu) e invoca a opção
--- de "usar" (Comer/Beber/Tomar pílula/Ler) exatamente como um clique vanilla
--- faria. Assim, TODAS as verificações do jogo são respeitadas:
--- lata fechada sem abridor, garrafa selada, comida que não pode ser comida
--- crua (arroz), literatura/cartão sem conteúdo, etc.

require "ISUI/ISPanel"

local AvatarUseDropZone = ISPanel:derive("AvatarUseDropZone")

-- ─── Paleta de feedback visual ────────────────────────────────────────────────
-- Cinza padrão do mod (mesmo dos slots e células do Grid).
local COLOR_FILL   = { a=0.2, r=0.3, g=0.3, b=0.3 }
local COLOR_BORDER = { a=0.15, r=0.5, g=0.5, b=0.5 }

-- ─── Lista de ações espelháveis e fallback controlado ─────────────────────────
-- O avatar usa o AnimSet "player", cujo estado "actions" tem um nó de recurso
-- `default-fallback` (Bob_EmoteSurrender) que toca quando NENHUM nó de ação casa
-- as condições. O avatar só espelha IsPerformingAnAction + PerformingAction, então
-- ações cujos nós exigem variáveis extras (AttachAnim, WearClothingLocation,
-- Weapon, FoodType, ReadType...) nunca casariam e tocariam o surrender.
--
-- SAFE_ACTIONS = PerformingActions com pelo menos um nó de condições 100%
-- satisfeitas no avatar (só PerformingAction + booleans que o avatar já
-- seta/limpa). O casamento das condições do jogo é case-insensitive
-- (AnimCondition.check usa equalsIgnoreCase e, para variável não definida com
-- condição BOOL=false, casa como false), então o lookup da lista ignora o case
-- para refletir o que o jogo grava via enum.toString() ("Eat", "Chop_tree"...).
-- Essas são espelhadas de verdade. Qualquer outra ação é espelhada com a
-- animação genérica de transferência (TransferItemOnSelf -> Bob_IdleLooting_Mid)
-- para o boneco continuar "vivo" sem tocar o surrender. Lista gerada de
-- media/AnimSets/player/actions/*.xml (ver /tmp/gridtest/build_whitelist.py);
-- falha segura: valor novo fora da lista só usa o fallback genérico.
local SAFE_ACTIONS = {
    "AnimalLure",
    "ApplyGlaze",
    "BlowGlass",
    "BlowTorch",
    "Build",
    "Chisel_Surface",
    "ChoppingBlock_Hammer",
    "Craft",
    "CraftArmourPiece",
    "CraftKnifeSpear",
    "CraftWeapon1H",
    "CraftWeapon2H",
    "CutWire",
    "Destroy",
    "Dig",
    "DropWhileMoving",
    "EquipItem",
    "ExamineVehicle",
    "Forage",
    "HammerOre",
    "HammerSmashSurface",
    "InsertBullets",
    "Knitting",
    "LightFire_KnotchedPlank",
    "Loot",
    "MakeChum",
    "MakeWithBrick",
    "Making",
    "MakingElectrical",
    "MakingHammer_Surface",
    "MakingJewellery",
    "MixFluids",
    "MixingBowl",
    "MixingBucket",
    "MixingFood",
    "MixingMortarPestle",
    "OpenAmmoBox",
    "OpenBeerBottle",
    "OpenChampagne",
    "OpenTinCan",
    "PackSack",
    "PackingBox",
    "PetAnimal",
    "PlaceAmmoInBox",
    "PutSeedsInPacket",
    "Rake",
    "RemoveBarricade",
    "RemoveBullets",
    "RemoveBush",
    "RemoveCurtain",
    "RipSheets",
    "RollDice",
    "SawLog",
    "SawOffShotgun",
    "SawSmallItemMetal",
    "ScrubClothWithSoap",
    "ScrubFloor",
    "ScrubFloor_Mop",
    "ScrubWall",
    "ScrubWall_Mop",
    "SewingCloth",
    "SharpenBlade",
    "SharpenStake",
    "Shave",
    "Shear",
    "SlicingFood",
    "SmithingHammer",
    "TakeGasFromPump",
    "TakeGasFromVehicle",
    "TakePills",
    "Take_Off_Rack_Mid",
    "TanLeatherBarrel",
    "Threshing",
    "TransferItemOnSelf",
    "Tying_High",
    "UnPackBox",
    "UnPackSack",
    "UncorkBottle",
    "UnequipItem",
    "Untie_Mid",
    "UseBandsaw",
    "UseGrindingSlab",
    "UseGrindingStone",
    "UseHandPress",
    "UseLathe",
    "UseSpinningWheel",
    "UseStandingDrill",
    "UseStoneQuern",
    "Use_Ripple_Comb",
    "VehicleTrailer",
    "VehicleWash",
    "VehicleWorkOnMid",
    "VehicleWorkOnTire",
    "WashFace",
    "WearClothing",
    "Welding",
    "changeBait",
    "chop_tree",
    "disassemble",
    "disassembleElectrical",
    "drink",
    "drink_tap",
    "eat",
    "fill_container_tap",
    "paint",
    "pour",
    "read",
    "refuelgascan",
}
local SAFE_ACTIONS_SET = {}
local SAFE_ACTIONS_SET_LOWER = {}
for _, v in ipairs(SAFE_ACTIONS) do
    SAFE_ACTIONS_SET[v] = true
    SAFE_ACTIONS_SET_LOWER[v:lower()] = true
end

-- ─── Constructor ──────────────────────────────────────────────────────────────
function AvatarUseDropZone:new(x, y, w, h, playerNum, avatarPanel)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.playerNum   = playerNum or 0
    o.avatarPanel = avatarPanel
    o.background  = false
    o.borderColor = { r=0, g=0, b=0, a=0 }
    return o
end

-- ─── Helpers ──────────────────────────────────────────────────────────────────

--- Retorna o primeiro item do drag ativo, ou nil.
local function getDraggedItem()
    if not GridInventory_GlobalDrag then return nil end
    if not GridInventory_GlobalDrag.itemsData then return nil end
    if #GridInventory_GlobalDrag.itemsData == 0 then return nil end
    return GridInventory_GlobalDrag.itemsData[1].itemObj
end

--- Cancela o drag global do mod (mesma limpeza feita pelo GridRender).
local function cancelDrag()
    if GridInventory_GlobalDrag then
        if GridInventory_GlobalDrag.sourceGrid then
            GridInventory_GlobalDrag.sourceGrid.selectedItems = {}
        end
        GridInventory_GlobalDrag = nil
    end
    ISMouseDrag.dragging = nil
    ISMouseDrag.draggingFocus = nil
end

-- ─── Ponte para o "Use" vanilla ────────────────────────────────────────────────

--- Callbacks vanilla de "uso" que queremos acionar.
local USE_OPTION_TYPES = {}
USE_OPTION_TYPES[ISInventoryPaneContextMenu.onDrinkFluid]      = "drink"
USE_OPTION_TYPES[ISInventoryPaneContextMenu.onEatItems]        = "eat"
USE_OPTION_TYPES[ISInventoryPaneContextMenu.onPillsItems]      = "pill"
USE_OPTION_TYPES[ISInventoryPaneContextMenu.onLiteratureItems] = "read"
USE_OPTION_TYPES[ISInventoryPaneContextMenu.onMediaText]       = "media"

local USE_PRIORITY = {
    drink = 1,
    eat   = 2,
    pill  = 3,
    read  = 4,
    media = 5,
}

--- Monta o context menu vanilla do item e devolve a opção de "usar" que o
--- próprio jogo liberaria (não marcada como notAvailable), varrendo menus e
--- submenus. O menu é fechado logo em seguida (não chega a aparecer na tela).
--- Retorna a option, ou nil se o vanilla não permite usar o item.
local function findVanillaUseOption(playerNum, item)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return nil end
    if not getPlayerContextMenu(playerNum) then return nil end
    if not getPlayerLoot(playerNum) then return nil end
    if getCore():getGameMode() == "Tutorial" then return nil end

    local inv = item:getContainer()
    local isInPlayerInv = inv and inv:isInCharacterInventory(playerObj) or false

    local menu = ISInventoryPaneContextMenu.createMenu(playerNum, isInPlayerInv, { item }, 0, 0, nil)
    if not menu then return nil end

    local best, bestPriority
    local function walk(ctx)
        for _, option in ipairs(ctx.options) do
            if option.onSelect and USE_OPTION_TYPES[option.onSelect] and not option.notAvailable then
                local prio = USE_PRIORITY[USE_OPTION_TYPES[option.onSelect]]
                if option.param1 == 1 then
                    prio = prio - 0.5 -- prefere a porção inteira (Eat All / Drink All)
                end
                if not bestPriority or prio < bestPriority then
                    best = option
                    bestPriority = prio
                end
            end
            if option.subOption then
                local sub = ctx:getSubMenu(option.subOption)
                if sub then walk(sub) end
            end
        end
    end
    walk(menu)

    -- Fecha o menu antes de invocar, exatamente como o vanilla faz ao clicar.
    menu:closeAll()
    return best
end

--- Invoca a option exatamente como o vanilla faria ao clicar nela.
local function invokeVanillaUse(option, playerNum)
    ISContextMenu.globalPlayerContext = playerNum
    option.onSelect(option.target, option.param1, option.param2, option.param3, option.param4,
                    option.param5, option.param6, option.param7, option.param8, option.param9,
                    option.param10)
end

-- ─── Classificação leve (apenas feedback visual) ───────────────────────────────
-- A decisão REAL de "pode usar" acontece no onMouseUp, via o menu vanilla.

--- Retorna um actionType aproximado ("eat"/"drink"/"pill"/"read") ou nil.
local function getUseActionType(item)
    if not item then return nil end

    -- Fluido bebível (vanilla: não vazio, primary fluid é bebida/bleach)
    if item.getFluidContainer then
        local fc = item:getFluidContainer()
        if fc and not fc:isEmpty() and fc:getPrimaryFluid() then
            local fluid = fc:getPrimaryFluid()
            local isDrinkable = fluid:getFluidType() == FluidType.Bleach
                or (fluid.isCategory and fluid:isCategory(FluidCategory.Beverage))
            if isDrinkable then
                -- Garrafa selada: vanilla só permite beber se der para esvaziar
                -- ou se houver recipe de abertura.
                if fc:canPlayerEmpty() or (item:isSealed() and item:getOpeningRecipe()) then
                    return "drink"
                end
            end
        end
    end

    -- Pílulas / remédios (vanilla: DrainableComboItem com tag consumível)
    if item.hasTag and instanceof(item, "DrainableComboItem") then
        if item:hasTag(ItemTag.CONSUMABLE) or item:hasTag(ItemTag.Pill) or item:hasTag(ItemTag.Pills) then
            return "pill"
        end
    end

    -- Comida (vanilla: categoria Food, respeitando CantEat / recipe de abertura)
    if item.getCategory and item:getCategory() == "Food" then
        local openingRecipe = item.getOpeningRecipe and item:getOpeningRecipe()
        local scriptItem = item.getScriptItem and item:getScriptItem()
        local cantEat = scriptItem and scriptItem:isCantEat()
        if not cantEat or openingRecipe then
            if openingRecipe
                or (item.getHungerChange and item:getHungerChange() < 0)
                or (item.getCustomMenuOption and item:getCustomMenuOption()) then
                return "eat"
            end
        end
    end

    -- Literatura / mídia com conteúdo (vanilla: categoria Literature)
    if item.getCategory and item:getCategory() == "Literature" then
        local canWrite = item.canBeWrite and item:canBeWrite()
        local uninteresting = item.hasTag and item:hasTag(ItemTag.UNINTERESTING)
        if not canWrite and not uninteresting then
            return "read"
        end
    end
    if item.getMediaData and item:getMediaData() then
        local media = item:getMediaData()
        if media.getTranslatedExtra and media:getTranslatedExtra() then
            return "read"
        end
    end

    return nil
end

local ACTION_FALLBACKS = {
    eat   = "IGUI_AvatarDrop_Eat",
    drink = "IGUI_AvatarDrop_Drink",
    read  = "IGUI_AvatarDrop_Read",
    pill  = "IGUI_AvatarDrop_Take",
}

local function getActionLabel(actionType, item)
    if item and item.getCustomMenuOption and item:getCustomMenuOption() then
        return item:getCustomMenuOption()
    end
    local key = ACTION_FALLBACKS[actionType]
    return (key and getTextOrNull(key)) or actionType
end

-- ─── Avatar reage às ações do personagem (dar vida ao boneco) ─────────────────
-- Toda timed action que o jogo anima define "PerformingAction" e
-- "IsPerformingAnAction" no personagem (via setActionAnim do vanilla, no
-- ISBaseTimedAction). Aqui ESPELHAMOS isso no avatar: trocamos para o AnimSet
-- "player" e replicamos as variáveis, então o boneco executa a MESMA animação
-- de interação do personagem (comer, beber, ler, pílulas, bandagem, artesanato,
-- etc.) — e só DEPOIS que a ação começa de verdade (após soltar o item).
-- Chamado todo frame pelo PaperDollWindow:update.

function AvatarUseDropZone:updateAvatarAction(playerObj)
    if not self.avatarPanel then return end
    if not playerObj then return end

    local performing = playerObj:getVariableBoolean("IsPerformingAnAction")
    local actionAnim = playerObj:getVariableString("PerformingAction")

    if performing and actionAnim and actionAnim ~= "" then
        if not self.avatarInAction then
            self.avatarInAction = true
            -- Mesmo mecanismo do personagem real no mundo: idle -> actions.
            self.avatarPanel:setAnimSetName("player")
            -- Fidgets aleatórios (EventDoExt) desligados durante a ação para
            -- não interferirem na transição para o substate "actions".
            self.avatarPanel:setDoRandomExtAnimations(false)
            -- Condições extras de segurança (TakePills pede sneaking=false e
            -- nearWallCrouching=false; a transição idle->actions pede
            -- isTurning=false). Com variável não definida o padrão já é false,
            -- mas garantimos explicitamente para não cair no fallback.
            self.avatarPanel:setVariable("sneaking", false)
            self.avatarPanel:setVariable("nearWallCrouching", false)
            self.avatarPanel:setVariable("isTurning", false)
        end
        self.avatarPanel:setVariable("IsPerformingAnAction", true)
        -- Fallback controlado: se a ação não está na lista segura (ex.: precisa
        -- de variáveis extras que não espelhamos, como AttachAnim, e nunca
        -- casaria um nó), espelhamos a animação genérica de transferência
        -- (Bob_IdleLooting_Mid, o personagem só mexe os braços) em vez de tocar
        -- o nó default-fallback (Bob_EmoteSurrender) ou ficar parado.
        -- O lookup ignora maiúsculas/minúsculas: o jogo grava PerformingAction
        -- via enum.toString() ("Eat", "Drink", "Chop_tree"...), mas os nós do
        -- AnimSet usam minúsculas ("eat"...), e o casamento de condição do jogo
        -- é case-insensitive (equalsIgnoreCase) — então o espelhamento também é.
        local safe = SAFE_ACTIONS_SET[actionAnim] or SAFE_ACTIONS_SET_LOWER[actionAnim:lower()]
        self.avatarPanel:setVariable("PerformingAction", safe and actionAnim or "TransferItemOnSelf")
    elseif self.avatarInAction then
        self.avatarInAction = false
        self.avatarPanel:clearVariable("IsPerformingAnAction")
        self.avatarPanel:clearVariable("PerformingAction")
        self.avatarPanel:clearVariable("sneaking")
        self.avatarPanel:clearVariable("nearWallCrouching")
        self.avatarPanel:clearVariable("isTurning")
        self.avatarPanel:setAnimSetName("player-avatar")
        self.avatarPanel:setDoRandomExtAnimations(true)
    end
end

-- ─── Render ───────────────────────────────────────────────────────────────────
function AvatarUseDropZone:render()
    -- Só aparece quando há um drag ativo com uma ação disponível
    if not GridInventory_GlobalDrag then
        -- Highlight do joypad (alvo selecionado no modo PaperDoll).
        if self.joySelected then
            self:drawRectBorder(0, 0, self.width, self.height, 1.3, 1.0, 1.0, 1.0)
        end
        return
    end

    local item = getDraggedItem()
    if not item then return end

    local actionType = getUseActionType(item)
    if not actionType then return end

    -- Cinza padrão do mod
    self:drawRect(0, 0, self.width, self.height, COLOR_FILL.a, COLOR_FILL.r, COLOR_FILL.g, COLOR_FILL.b)
    self:drawRectBorder(0, 0, self.width, self.height, COLOR_BORDER.a, COLOR_BORDER.r, COLOR_BORDER.g, COLOR_BORDER.b)

    -- Highlight do joypad (alvo selecionado no modo PaperDoll).
    if self.joySelected then
        self:drawRectBorder(1, 1, self.width - 2, self.height - 2, 1.3, 1.0, 1.0, 1.0)
    end

    -- Apenas o texto da ação, centralizado e em branco
    local label = getActionLabel(actionType, item)
    local th = getTextManager():MeasureStringY(UIFont.Large, label)
    self:drawTextCentre(label, self.width / 2, (self.height - th) / 2, 1, 1, 1, 1, UIFont.Large)
end

-- ─── Clique direito: menu de tratamento (igual ao Health Panel vanilla) ───────
-- Não mapeia a posição para osso nenhum: lista TODAS as partes do corpo que
-- precisam de atenção e abre, para cada uma, o MESMO submenu de tratamento que
-- o health panel vanilla usa (bandagem, desinfetar, costurar, tala, bala,
-- queimadura...). Tudo é reaproveitado de ISHealthPanel.doBodyPartContextMenu,
-- então as verificações e as ações são 100% do jogo.

--- "Health panel" mínimo (tabela) para o vanilla montar o menu de tratamento.
local function makeHealthPanel(playerObj)
    local panel = {
        character       = playerObj,
        otherPlayer     = nil, -- trata o próprio personagem (sem outro jogador)
        blockingMessage = nil,
    }
    panel.getAbsoluteX = function() return 0 end
    panel.getAbsoluteY = function() return 0 end
    setmetatable(panel, { __index = ISHealthPanel })
    return panel
end

--- Partes do corpo que precisam de atenção (mesma regra do health panel).
local function getDamagedParts(playerObj)
    local result = {}
    local bodyParts = playerObj:getBodyDamage():getBodyParts()
    for i = 1, bodyParts:size() do
        local bodyPart = bodyParts:get(i - 1)
        if bodyPart:HasInjury() or bodyPart:bandaged() or bodyPart:stitched()
            or bodyPart:getSplintFactor() > 0 or bodyPart:getAdditionalPain() > 10
            or bodyPart:getStiffness() > 5 then
            table.insert(result, bodyPart)
        end
    end
    return result
end

--- Rótulo curto do ferimento (para diferenciar as partes no menu).
local function getInjuryLabel(bodyPart)
    if bodyPart:bandaged() then return getText("IGUI_health_Bandaged") end
    if bodyPart:getSplintFactor() > 0 then return getText("IGUI_health_Splinted") end
    if bodyPart:stitched() then return getText("IGUI_health_Stitched") end
    if bodyPart:bleeding() then return getText("IGUI_health_Bleeding") end
    if bodyPart:getFractureTime() > 0 then return getText("IGUI_health_Fracture") end
    if bodyPart:isBurnt() then return getText("IGUI_health_Burned") end
    if bodyPart:haveBullet() then return getText("IGUI_health_Wounded") end
    if bodyPart:haveGlass() then return getText("IGUI_health_Wounded") end
    if bodyPart:bitten() then return getText("IGUI_health_Bitten") end
    if bodyPart:deepWounded() then return getText("IGUI_health_DeepWound") end
    if bodyPart:isCut() then return getText("IGUI_health_Cut") end
    if bodyPart:scratched() then return getText("IGUI_health_Scratched") end
    return nil
end

function AvatarUseDropZone:onRightMouseUp(x, y)
    -- Não interferir com o drag de item (botão direito gira o item)
    if GridInventory_GlobalDrag then return true end
    if not ISHealthPanel or not ISHealthPanel.doBodyPartContextMenu then return true end
    if not getPlayerContextMenu(self.playerNum) then return true end

    local playerObj = getSpecificPlayer(self.playerNum)
    if not playerObj then return true end

    local damagedParts = getDamagedParts(playerObj)
    if #damagedParts == 0 then return true end

    local context = ISContextMenu.get(self.playerNum, x + self:getAbsoluteX(), y + self:getAbsoluteY())
    if not context then return true end

    -- Redireciona o ISContextMenu.get do vanilla para dentro de cada submenu,
    -- assim reaproveitamos o menu de tratamento inteiro (bandagem, desinfetar,
    -- costurar, tala...) sem copiar nenhuma lógica. Sincronizado e envolto em
    -- pcall: qualquer erro só loga e não corrompe o context menu global.
    local realGet = ISContextMenu.get
    local panel = makeHealthPanel(playerObj)

    for _, bodyPart in ipairs(damagedParts) do
        local sub = context:getNew(context)
        ISContextMenu.get = function() return sub end
        -- O restore do ISContextMenu.get fica DENTRO do pcall: se o
        -- doBodyPartContextMenu lançar, o global é restaurado mesmo assim
        -- (antes o restore ficava fora e o global podia ficar corrompido).
        local ok = pcall(function()
            ISHealthPanel.doBodyPartContextMenu(panel, bodyPart, 0, 0)
            ISContextMenu.get = realGet
        end)
        if ok then ISContextMenu.get = realGet end

        if not ok or sub:isEmpty() then
            -- Sem tratamento disponível nesta parte: descarta o submenu
            sub:setVisible(false)
            sub:removeFromUIManager()
            context.instanceMap[sub.subOptionNums] = nil
            table.insert(context.subMenuPool, sub)
        else
            local label = BodyPartType.getDisplayName(bodyPart:getType())
            local injury = getInjuryLabel(bodyPart)
            if injury then
                label = label .. " (" .. injury .. ")"
            end
            local option = context:addOption(label, nil)
            context:addSubMenu(option, sub)
        end
    end

    if context:isEmpty() then
        context:setVisible(false)
    end
    return true
end

-- ─── Drop: ponte para o "Use" vanilla ─────────────────────────────────────────
function AvatarUseDropZone:onMouseUp(x, y)
    local item = getDraggedItem()
    if not item then return end
    AvatarUseDropZone.useItem(self.playerNum, item)
    cancelDrag()
end

--- Usa um item no avatar (comer/beber/ler/tomar pílula) via o menu vanilla.
--- Reutilizado pelo joypad (modo PaperDoll): o retângulo do avatar é um alvo
--- navegável e, com um item arrastado, A ativa o "use".
function AvatarUseDropZone.useItem(playerNum, item)
    if not item then return false end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return false end
    -- Quem decide se e como o item pode ser usado é o próprio vanilla
    -- (lata fechada, garrafa selada, comida crua, literatura vazia, etc).
    local useOption = findVanillaUseOption(playerNum, item)
    if useOption then
        invokeVanillaUse(useOption, playerNum)
        return true
    end
    return false
end

return AvatarUseDropZone
