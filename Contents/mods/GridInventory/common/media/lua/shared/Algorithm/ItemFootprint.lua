--- ItemFootprint.lua
--- Algoritmo dinâmico para calcular o tamanho de um item (Width, Height)
--- baseado nas suas propriedades nativas da B42 (Peso, Categoria, Tipo).

local ItemFootprint = {}

-- Dicionário de overrides fixos para itens que a matemática não adivinha bem.
-- Pode ser expandido por outros mods conectando nessa tabela.
ItemFootprint.Overrides = {
    
    -- TODO: Adicionar os itens mais críticos depois
}

---@param item InventoryItem Objeto nativo do PZ
---@return number, number width e height do item
function ItemFootprint.getSize(item)
    if not item then return 1, 1 end

    local fullType = item:getFullType()
    
    -- 1. Verifica Overrides Hardcoded ou Carregados do DevTool
    local override = ItemFootprint.Overrides[fullType]
    if GridDevTool and GridDevTool.Overrides and GridDevTool.Overrides[fullType] then
        override = GridDevTool.Overrides[fullType]
    end
    
    if override and override.w and override.h then
        return override.w, override.h
    end

    -- 2. Sistema Híbrido: Categoria -> Range de Peso -> Dimensões Exatas
    local weight = item:getActualWeight()
    local isWeapon = instanceof(item, "HandWeapon")
    local isClothing = instanceof(item, "Clothing")
    local isBag = instanceof(item, "InventoryContainer")
    local isFood = instanceof(item, "Food")
    
    local w, h = 1, 1
    
    if isWeapon then
        if item:isTwoHandWeapon() then
            -- Armas longas de duas mãos (Espingardas, Rifles, Tacos, Machados, Lanças)
            if weight >= 3.0 then
                w = 2; h = 5 -- Muito pesada (Marreta)
            elseif weight >= 2.0 then
                w = 2; h = 4 -- Escopetas, Rifles
            elseif weight >= 1.5 then
                w = 1; h = 4 -- Tacos de Baseball, Facões longos
            else
                w = 1; h = 3 -- Tacos leves, pedaços de cano
            end
        else
            -- Armas de uma mão (Pistolas, Facas, Cassetetes)
            if weight >= 1.5 then
                w = 1; h = 3 -- Pé de cabra
            elseif weight >= 0.8 then
                w = 2; h = 2 -- Revólveres pesados, Martelos
            elseif weight >= 0.3 then
                w = 1; h = 2 -- Pistolas leves, Facas médias
            else
                w = 1; h = 1 -- Canetas, Facas de manteiga
            end
        end
    elseif isBag then
        if weight >= 2.0 then
            w = 4; h = 4 -- Mochilas Grandes
        elseif weight >= 1.0 then
            w = 3; h = 3 -- Mochilas Médias, Maletas
        else
            w = 2; h = 2 -- Pochetes, Sacolas plásticas
        end
    elseif isClothing then
        if weight >= 2.0 then
            w = 2; h = 3 -- Casacos pesados, Coletes Balísticos
        elseif weight >= 1.0 then
            w = 2; h = 2 -- Calças, Camisas
        else
            w = 1; h = 2 -- Luvas, Chapéus, Óculos (1x2 ou 1x1 dependendo, 1x2 é mais seguro visualmente)
        end
    elseif isFood then
        if weight >= 1.0 then
            w = 2; h = 2 -- Melancia, Repolho grande
        elseif weight >= 0.3 then
            w = 1; h = 2 -- Garrafa d'água, Comida Enlatada
        else
            w = 1; h = 1 -- Pílulas, Frutas pequenas, Snacks
        end
    else
        -- Itens Gerais (Materiais, Junk, Eletrônicos)
        if weight >= 5.0 then
            w = 3; h = 3 -- Geradores, Pneus, Móveis
        elseif weight >= 2.0 then
            w = 2; h = 3 -- Tábuas, Chapas de metal (itens compridos)
        elseif weight >= 1.0 then
            w = 2; h = 2 -- Galão de gasolina, Caixa de ferramentas
        elseif weight >= 0.3 then
            w = 1; h = 2 -- Walkie Talkie, Livros, Fitas
        else
            w = 1; h = 1 -- Chaveiro (Keychain), Pregos, Sementes
        end
    end
    
    return w, h
end

return ItemFootprint
