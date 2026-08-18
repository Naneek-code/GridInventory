require "Hotbar/ISHotbar"

-- A hotbar nativa do Zomboid processa os tooltips calculando apenas a posição do mouse (getSlotIndexAt),
-- e ignora completamente o Z-order ou quem está na frente.
-- Isso faz com que ela desenhe tooltips duplicados caso a janela do PaperDoll esteja desenhada por cima dela.
-- Vamos interceptar o getSlotIndexAt para retornar -1 (slot nenhum) se o mouse estiver sobre o PaperDoll.

local og_getSlotIndexAt = ISHotbar.getSlotIndexAt
-- Upvalues de funções Java globais (sempre presentes no runtime).
-- NOTA: GridInventory_PaperDollWindow é uma tabela global MUTÁVEL definida por
-- outro arquivo (ISInventoryPage_Hijack) que carrega DEPOIS deste — por isso
-- NÃO pode virar upvalue aqui (congelaria em nil); lida como global em runtime.
local getPlayerInventoryFn = getPlayerInventory
local getPlayerLootFn = getPlayerLoot
function ISHotbar:getSlotIndexAt(x, y)
    -- Verifica o PaperDoll
    local paperDoll = GridInventory_PaperDollWindow and GridInventory_PaperDollWindow[self.playerNum]
    if paperDoll and paperDoll:isVisible() and paperDoll:isMouseOver() then
        return -1
    end
    
    -- Verifica o Inventário do jogador
    local invPage = getPlayerInventoryFn(self.playerNum)
    if invPage and invPage:isVisible() and invPage:isMouseOver() then
        return -1
    end
    
    -- Verifica o Loot do jogador
    local lootPage = getPlayerLootFn(self.playerNum)
    if lootPage and lootPage:isVisible() and lootPage:isMouseOver() then
        return -1
    end
    
    return og_getSlotIndexAt(self, x, y)
end
