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

-- ─── Constructor ──────────────────────────────────────────────────────────────
function AvatarUseDropZone:new(x, y, w, h, playerNum)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.playerNum  = playerNum or 0
    o.background = false
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

-- ─── Render ───────────────────────────────────────────────────────────────────
function AvatarUseDropZone:render()
    -- Só aparece quando há um drag ativo com uma ação disponível
    if not GridInventory_GlobalDrag then return end

    local item = getDraggedItem()
    if not item then return end

    local actionType = getUseActionType(item)
    if not actionType then return end

    -- Cinza padrão do mod
    self:drawRect(0, 0, self.width, self.height, COLOR_FILL.a, COLOR_FILL.r, COLOR_FILL.g, COLOR_FILL.b)
    self:drawRectBorder(0, 0, self.width, self.height, COLOR_BORDER.a, COLOR_BORDER.r, COLOR_BORDER.g, COLOR_BORDER.b)

    -- Apenas o texto da ação, centralizado e em branco
    local label = getActionLabel(actionType, item)
    local th = getTextManager():MeasureStringY(UIFont.Small, label)
    self:drawTextCentre(label, self.width / 2, (self.height - th) / 2, 1, 1, 1, 1, UIFont.Small)
end

-- ─── Drop: ponte para o "Use" vanilla ─────────────────────────────────────────
function AvatarUseDropZone:onMouseUp(x, y)
    local item = getDraggedItem()
    if not item then return end

    local playerObj = getSpecificPlayer(self.playerNum)
    if not playerObj then
        cancelDrag()
        return
    end

    -- Quem decide se e como o item pode ser usado é o próprio vanilla
    -- (lata fechada, garrafa selada, comida crua, literatura vazia, etc).
    local useOption = findVanillaUseOption(self.playerNum, item)
    if useOption then
        invokeVanillaUse(useOption, self.playerNum)
    end

    cancelDrag()
end

return AvatarUseDropZone
