--- OverflowGridRender.lua
--- Renderiza a lista de itens não posicionados (Overflow) no fundo do inventário.
--- Força todos os itens a serem 1x1 e bloqueia interações contextuais.

require "ISUI/ISPanel"
local GridRender = require("UI/GridRender/GridRender")
local GridCore = require("DataModel/GridCore")

local OverflowGridRender = GridRender:derive("OverflowGridRender")

function OverflowGridRender:new(x, y, unpositionedItems, playerNum, isLootMode, invContainer, cItem, cIcon)
    -- Cria um GridCore falso que acomoda exatamente todos os itens 1x1
    local columns = 6
    local rows = math.max(1, math.ceil(#unpositionedItems / columns))
    local fakeCore = GridCore.new(columns, rows)
    
    local index = 1
    for row = 1, rows do
        for col = 1, columns do
            if index <= #unpositionedItems then
                local item = unpositionedItems[index]
                -- Insere forçado 1x1
                fakeCore:insertItem(item:getID(), col, row, 1, 1, false, item)
                index = index + 1
            end
        end
    end

    local o = GridRender.new(self, x, y, fakeCore, playerNum, invContainer, 999, cItem, cIcon)
    o.isOverflow = true
    o.isLootMode = isLootMode
    return o
end

function OverflowGridRender:prerender()
    if not self.isLootMode then
        -- Fundo vermelho de alerta apenas para o jogador
        self:drawRect(0, 0, self.width, self.height, 0.9, 0.2, 0.05, 0.05)
        self:drawRectBorder(0, 0, self.width, self.height, 1, 1, 0, 0)
    end
    
    GridRender.prerender(self)
end

function OverflowGridRender:onRightMouseUp(x, y)
    -- Bloqueia o menu de contexto!
    return
end

function OverflowGridRender:doDoubleClick(x, y)
    -- Bloqueia o uso rápido (comer, equipar, etc)!
    return
end

--- BUSCA (Tarkov): o overflow NÃO inicia vasculhada — ele é uma janela de
--- saída dos itens que não couberam; a busca acontece no grid principal.
--- Sem isso, clicar no overflow herdaria o GridRender.startSearch e revelaria
--- TUDO de uma vez (o gridCore falso do overflow não tem as pilhas ocultas).
function OverflowGridRender:startSearch()
    return false
end

--- BUSCA (Tarkov): o overflow nunca pede "vasculhar" (bloqueia o onMouseDown
--- herdado que iniciaria a busca).
function OverflowGridRender:needsSearch()
    return false
end

function OverflowGridRender:onMouseUp(x, y)
    -- O overflow é de SAÍDA APENAS. 
    -- Se tem um drag ativo que veio de fora, bloqueia.
    if ISMouseDrag.dragging and GridInventory_GlobalDrag and GridInventory_GlobalDrag.sourceGrid ~= self then
        -- Cancela o drop
        GridInventory_GlobalDrag = nil
        ISMouseDrag.dragging = nil
        ISMouseDrag.draggingFocus = nil
        return
    end
    
    -- Deixa o GridRender original cuidar de drops cancelados que voltaram pra ele
    GridRender.onMouseUp(self, x, y)
end

return OverflowGridRender
