--- ItemFootprint.lua
--- Algoritmo dinâmico para calcular o tamanho de um item (Width, Height)
--- baseado nas suas propriedades nativas da B42 (Peso, Categoria, Tipo).

local ItemFootprint = {}

-- Dicionário de overrides fixos para itens que a matemática não adivinha bem.
-- Pode ser expandido por outros mods conectando nessa tabela.
ItemFootprint.Overrides = {
    -- TODO: Adicionar os itens mais críticos depois
}

-- Cache por fullType: o resultado da FÓRMULA (sem overrides) é 100% determinado
-- pelo fullType, então só precisa ser calculado uma vez por tipo de item, não
-- uma vez por instância. Overrides NÃO são cacheados aqui de propósito, pra
-- continuar refletindo mudanças ao vivo feitas pelo GridDevTool.
local _sizeCache = {}

--- Limpa o cache de tamanhos calculados. Chame isso se os thresholds de peso
--- ou a lógica de categorias mudar em runtime (ex: hot-reload no dev).
function ItemFootprint.clearCache()
    _sizeCache = {}
end

-- Teto de segurança: mesmo um item absurdamente pesado não deve estourar a grid.
local MAX_W, MAX_H = 6, 12

local function clamp(v, maxV)
    if v > maxV then return maxV end
    return v
end

--- Calcula w/h a partir da fórmula (peso + categoria). NÃO considera overrides.
--- @param item InventoryItem
local function computeFormulaSize(item)
    -- ATENÇÃO: getWeight() é o peso BASE do script (fixo por tipo).
    -- getActualWeight() inclui modificadores de instância — e, para itens
    -- container, normalmente inclui o peso do CONTEÚDO, e para armas pode
    -- incluir o peso de attachments. Usar getActualWeight() aqui faria o
    -- tamanho na grid mudar conforme a mochila enche/esvazia ou a arma troca
    -- de acessório, o que quebra o layout salvo do jogador.
    -- Confirme o nome exato do método na sua build (pode variar entre
    -- patches do B42) antes de assumir que getWeight() é o certo.
    local weight = item:getWeight()
    local isWeapon = instanceof(item, "HandWeapon")
    local isClothing = instanceof(item, "Clothing")
    local isBag = instanceof(item, "InventoryContainer")
    local isFood = instanceof(item, "Food")
    local isMoveable = instanceof(item, "Moveable")

    local w, h = 1, 1

    if isWeapon then
        if item:isTwoHandWeapon() then
            -- Armas longas de duas mãos (Espingardas, Rifles, Tacos, Machados, Lanças)
            if weight >= 3.0 then
                w, h = 2, 5 -- Muito pesada (Marreta)
            elseif weight >= 2.0 then
                w, h = 2, 4 -- Escopetas, Rifles
            elseif weight >= 1.5 then
                w, h = 1, 4 -- Tacos de Baseball, Facões longos
            else
                w, h = 1, 3 -- Tacos leves, pedaços de cano
            end
        else
            -- Armas de uma mão (Pistolas, Facas, Cassetetes)
            if weight >= 1.5 then
                w, h = 1, 3 -- Pé de cabra
            elseif weight >= 0.8 then
                w, h = 2, 2 -- Revólveres pesados, Martelos
            elseif weight >= 0.3 then
                w, h = 1, 2 -- Pistolas leves, Facas médias
            else
                w, h = 1, 1 -- Canetas, Facas de manteiga
            end
        end
    elseif isBag then
        if weight >= 2.0 then
            w, h = 4, 4 -- Mochilas Grandes
        elseif weight >= 1.0 then
            w, h = 3, 3 -- Mochilas Médias, Maletas
        else
            w, h = 2, 2 -- Pochetes, Sacolas plásticas
        end
    elseif isClothing then
        if weight >= 2.0 then
            w, h = 2, 3 -- Casacos pesados, Coletes Balísticos
        elseif weight >= 1.0 then
            w, h = 2, 2 -- Calças, Camisas
        else
            w, h = 1, 2 -- Luvas, Chapéus, Óculos
        end
    elseif isFood then
        if weight >= 1.0 then
            w, h = 2, 2 -- Melancia, Repolho grande
        elseif weight >= 0.3 then
            w, h = 1, 2 -- Garrafa d'água, Comida Enlatada
        else
            w, h = 1, 1 -- Pílulas, Frutas pequenas, Snacks
        end
    elseif isMoveable then
        if weight >= 15.0 then
            w, h = 6, 10
        elseif weight >= 10.0 then
            w, h = 6, 7 -- Sofás grandes, Camas
        elseif weight >= 5.0 then
            w, h = 4, 6 -- Cadeiras pesadas, Mesas médias
        elseif weight >= 2.0 then
            w, h = 3, 3 -- Cadeiras leves, Caixas pequenas
        else
            w, h = 3, 2 -- Decorações móveis leves
        end
    else
        -- Itens Gerais (Materiais, Junk, Eletrônicos)
        if weight >= 5.0 then
            w, h = 3, 3 -- Geradores, Pneus, Móveis
        elseif weight >= 2.0 then
            w, h = 2, 3 -- Tábuas, Chapas de metal (itens compridos)
        elseif weight >= 1.0 then
            w, h = 2, 2 -- Galão de gasolina, Caixa de ferramentas
        elseif weight >= 0.3 then
            w, h = 1, 2 -- Walkie Talkie, Livros, Fitas
        else
            w, h = 1, 1 -- Chaveiro (Keychain), Pregos, Sementes
        end
    end

    return clamp(w, MAX_W), clamp(h, MAX_H)
end

---@param item InventoryItem Objeto nativo do PZ
---@return number, number width e height do item
function ItemFootprint.getSize(item)
    if not item then return 1, 1 end

    local fullType = item:getFullType()

    -- 1. Overrides sempre têm prioridade e são checados ao vivo (não cacheados),
    --    pra permitir tunar via GridDevTool sem precisar limpar cache.
    local override = ItemFootprint.Overrides[fullType]
    if GridDevTool and GridDevTool.Overrides and GridDevTool.Overrides[fullType] then
        override = GridDevTool.Overrides[fullType]
    end
    if override and override.w and override.h then
        return override.w, override.h
    end

    -- 2. Cache por tipo: a fórmula só depende do fullType (peso base + categoria
    --    são fixos por tipo de item), então calculamos uma vez só.
    local cached = _sizeCache[fullType]
    if cached then
        return cached[1], cached[2]
    end

    local w, h = computeFormulaSize(item)
    _sizeCache[fullType] = { w, h }
    return w, h
end

return ItemFootprint