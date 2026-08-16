--- GridItemCatalog.lua
--- Catálogo de itens do jogo pro GridDevBrowser (browser de debug): enumera
--- ScriptItems, classifica por categoria (reusando o ItemCategory), calcula o
--- footprint (ItemFootprint.getSize) e oferece filtro (busca + categoria) e
--- paginação. LÓGICA PURA e testável — não depende de ISUI; o client injeta o
--- classificador (que instancia o item real) e a fonte de ScriptItems.

local GridItemCatalog = {}

-- Ordem das categorias no seletor do browser (todas vêm do ItemCategory).
GridItemCatalog.categoryOrder = {
    "MISC", "MELEE", "RANGED", "AMMO", "MAGAZINE", "ATTACHMENT",
    "FOOD", "CLOTHING", "CONTAINER", "HEALING", "BOOK",
    "ENTERTAINMENT", "KEY", "SEED", "MOVEABLE", "CORPSEANIMAL",
}

--- Constrói o catálogo a partir da lista de ScriptItem.
--- Cada entrada: { fullType, displayName, category, w, h }.
---@param items table array de ScriptItem-like (getFullName/getDisplayName/getObsolete/isHidden)
---@param classify fun(fullType:string): string, number, number  retorna category, w, h (ou nil se falhar)
---@return table entries ordenado por fullType
function GridItemCatalog.build(items, classify)
    local entries = {}
    for _, s in ipairs(items) do
        local fullName = s.getFullName and s:getFullName()
        if fullName then
            local obsolete = s.getObsolete and s:getObsolete()
            local hidden = s.isHidden and s:isHidden()
            if not obsolete and not hidden then
                local displayName = (s.getDisplayName and s:getDisplayName()) or fullName
                local category, w, h
                if classify then
                    category, w, h = classify(fullName)
                end
                entries[#entries + 1] = {
                    fullType = fullName,
                    displayName = displayName,
                    category = category or "MISC",
                    w = w or 1,
                    h = h or 1,
                }
            end
        end
    end
    table.sort(entries, function(a, b) return a.fullType < b.fullType end)
    return entries
end

--- Ordena entries por fullType (in-place, retorna a mesma tabela).
--- Usado pelo build incremental do client após acumular os chunks.
---@param entries table
---@return table entries
function GridItemCatalog.sortEntries(entries)
    table.sort(entries, function(a, b) return a.fullType < b.fullType end)
    return entries
end

--- Filtra as entradas por busca (substring em fullType/displayName,
--- case-insensitive) e por categoria.
---@param entries table
---@param query string|nil
---@param category string|nil categoria exata (nil = todas)
---@return table filtered
function GridItemCatalog.filter(entries, query, category)
    local q = query and string.lower(query) or ""
    local out = {}
    for _, e in ipairs(entries) do
        if not category or e.category == category then
            if q == "" or string.find(string.lower(e.fullType), q, 1, true)
                or (e.displayName and string.find(string.lower(e.displayName), q, 1, true)) then
                out[#out + 1] = e
            end
        end
    end
    return out
end

--- Constrói o índice de DERIVADOS a partir de pares de evolved recipes:
--- base fullType -> array de fullTypes resultantes (dedup + ordenado).
--- A fonte real no jogo é o global getEvolvedRecipes() (objetos EvolvedRecipe
--- com getBaseItem/getResultItem retornando STRING fullType); o client converte
--- pra pares { base, result } e passa aqui (lógica pura/testável).
---@param pairs table array de { base = string, result = string }
---@return table index: base -> { fullType, ... }
function GridItemCatalog.buildDerivedIndex(pairsIn)
    local index = {}
    for _, p in ipairs(pairsIn or {}) do
        if p and p.base and p.result then
            local list = index[p.base]
            if not list then list = {} index[p.base] = list end
            list[#list + 1] = p.result
        end
    end
    for base in pairs(index) do
        local seen, out = {}, {}
        table.sort(index[base])
        for _, t in ipairs(index[base]) do
            if not seen[t] then
                seen[t] = true
                out[#out + 1] = t
            end
        end
        index[base] = out
    end
    return index
end

--- Itens derivados de um base (resultados de evolved recipes), ordenados.
---@param index table índice de GridItemCatalog.buildDerivedIndex
---@param base string fullType do item base (ex: "Base.Bowl")
---@return table array de fullTypes derivados (pode ser vazio)
function GridItemCatalog.getDerived(index, base)
    return index and index[base] or {}
end

--- Pagina uma lista filtrada.
---@param filtered table
---@param page number 1-based
---@param pageSize number
---@return table pageItems, number pageCount
function GridItemCatalog.paginate(filtered, page, pageSize)
    local total = #filtered
    local pageCount = math.max(1, math.ceil(total / pageSize))
    if page < 1 then page = 1 end
    if page > pageCount then page = pageCount end
    local start = (page - 1) * pageSize + 1
    local items = {}
    for i = start, math.min(total, start + pageSize - 1) do
        items[#items + 1] = filtered[i]
    end
    return items, pageCount
end

return GridItemCatalog
