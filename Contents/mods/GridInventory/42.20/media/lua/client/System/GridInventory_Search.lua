--- GridInventory_Search.lua
--- Busca de containers do mundo (estilo Tarkov): itens não identificados ficam
--- ocultos atrás de uma máscara até o jogador vasculhar o container.
---
--- Estado POR JOGADOR e PERSISTENTE: cada jogador tem sua própria descoberta,
--- guardada no player:getModData() (salvo pelo jogo, sobrevive a relogar). O
--- cache de sessão (GridInventory_Search.sessions[playerNum]) é só pra leitura
--- rápida no render; o source da verdade é o modData do jogador.
---
--- Persistência POR ITEM (não por container): o jogador marca um ITEM como
--- vasculhado, e essa marca o acompanha em QUALQUER container onde ele esteja.
--- Mover um item já revelado de um container pra outro NÃO o esconde de novo —
--- o jogador já sabe o que é. O formato antigo (container -> {itens}) é migrado
--- automaticamente pro formato plano (itemId -> true) na primeira leitura.
---
--- Chave de container: string estável (containerRef serializado) — o MESMO
--- container re-resolvido entre sessões mapeia pra mesma chave. A chave ainda
--- é usada pro "abri o container" (primeira abertura) e no protocolo de rede,
--- mas NÃO para o estado de itens revelados. Chão e inventário do jogador
--- nunca são ocultados.

local GridProtocol = require("Network/GridProtocol")

local GridInventory_Search = {}

-- Cache de sessão: GridInventory_Search.sessions[playerNum][itemId] = true
GridInventory_Search.sessions = {}

-- MODDATA keys (persistem no save do jogador)
local MD_SEARCHED = "GridInventory_Searched"
local MD_OPENED = "GridInventory_Opened"

--- Chave estável de um container (string). Retorna nil p/ containers que nunca
--- são ocultados (chão, inventário do jogador).
---@param container ItemContainer
---@param playerObj IsoPlayer|nil jogador para checar se o container é do inventário
---   dele (mochilas vestidas/equipadas/nas mãos) — esses NUNCA são vasculhados.
---@return string|nil
function GridInventory_Search.containerKey(container, playerObj)
    if not container then return nil end
    -- Chão: nunca vasculha (virtual por jogador, sempre visível)
    if container.getType and container:getType() == "floor" then return nil end
    -- Container DENTRO do inventário do jogador (bolsa vestida/equipada/mão):
    -- é do personagem, sempre visível — nunca vira "mundo" pra vasculhar.
    if playerObj and container.isInCharacterInventory
        and container:isInCharacterInventory(playerObj) then
        return nil
    end
    local ref = GridProtocol.buildContainerRef(container)
    if not ref then return nil end
    if ref.type == "player" then return nil end -- inventário do jogador
    if ref.type == "floor" then return nil end

    local key
    if ref.type == "object" then
        key = "obj:" .. tostring(ref.x) .. "_" .. tostring(ref.y) .. "_" .. tostring(ref.z)
            .. ":" .. tostring(ref.objIndex or -1) .. ":" .. tostring(ref.spriteName or "?")
    elseif ref.type == "item" then
        key = "item:" .. tostring(ref.itemId)
    elseif ref.type == "worlditem" then
        key = "worlditem:" .. tostring(ref.itemId)
    elseif ref.type == "vehicle" then
        key = "veh:" .. tostring(ref.keyId)
    else
        key = "other:" .. ref.type
    end
    return key
end

--- Conjunto de itens vasculhados do jogador (modData persistente, FLAT).
--- itemId -> true. Migra automaticamente o formato antigo
--- (containerKey -> {itemId}) na primeira leitura, achando as sub-tabelas.
---@param playerObj IsoPlayer
---@return table (string -> true)
local function getPersistedSet(playerObj)
    local md = playerObj.getModData and playerObj:getModData()
    if not md then return {} end
    local root = md[MD_SEARCHED]
    if not root then root = {} md[MD_SEARCHED] = root end

    -- Detectar formato antigo (alguma chave com valor tabela = containerKey).
    local oldFormat = false
    for _, v in pairs(root) do
        if type(v) == "table" then oldFormat = true break end
    end
    if not oldFormat then return root end

    -- Achata [containerKey][itemId] em [itemId], preservando entradas planas
    -- que já existirem (formato misto).
    local flat = {}
    for k, v in pairs(root) do
        if type(v) == "table" then
            for id in pairs(v) do flat[tostring(id)] = true end
        else
            flat[k] = true
        end
    end
    -- Reescreve o modData no formato plano.
    for k in pairs(root) do root[k] = nil end
    for id in pairs(flat) do root[id] = true end
    return root
end

--- Cache de sessão de um jogador (flat, itemId -> true). Cria se faltar e
--- SEMEIA do modData persistente (relogar não perde o estado).
---@param playerNum number
---@return table (string -> true)
local function getSessionSet(playerNum)
    local byPlayer = GridInventory_Search.sessions[playerNum]
    if not byPlayer then
        byPlayer = {}
        GridInventory_Search.sessions[playerNum] = byPlayer
        local playerObj = getSpecificPlayer and getSpecificPlayer(playerNum)
        if playerObj then
            local persisted = getPersistedSet(playerObj)
            for id in pairs(persisted) do byPlayer[id] = true end
        end
    end
    return byPlayer
end

--- Verdadeiro se o jogador JÁ ABRIU o container alguma vez (persistente).
---@param playerObj IsoPlayer
---@param containerKey string
---@return boolean
function GridInventory_Search.hasOpened(playerObj, containerKey)
    if not playerObj or not containerKey then return false end
    local md = playerObj.getModData and playerObj:getModData()
    if not md then return false end
    local opened = md[MD_OPENED]
    return opened and opened[containerKey] == true
end

--- Marca que o jogador abriu o container (persistente).
---@param playerObj IsoPlayer
---@param containerKey string
function GridInventory_Search.markOpened(playerObj, containerKey)
    if not playerObj or not containerKey then return end
    local md = playerObj.getModData and playerObj:getModData()
    if not md then return end
    local opened = md[MD_OPENED]
    if not opened then opened = {} md[MD_OPENED] = opened end
    opened[containerKey] = true
end

--- Marca um ITEM como vasculhado (persistente + cache de sessão).
--- No MP, envia pro servidor (server-mandatory): o servidor grava no modData
--- do jogador e persiste no save — sem isso, relogar perdia tudo. No SP marca
--- direto no modData local. O containerKey só é usado pra encaminhar ao
--- servidor (protocolo); o estado em si é POR ITEM, vale em qualquer container.
---@param playerObj IsoPlayer
---@param containerKey string|nil
---@param itemId string|number
function GridInventory_Search.markSearched(playerObj, containerKey, itemId)
    if not playerObj or itemId == nil then return end
    local pn = playerObj.getPlayerNum and playerObj:getPlayerNum() or 0
    getSessionSet(pn)[tostring(itemId)] = true

    if isClient and isClient() then
        -- MP: servidor é a autoridade. Acumula num buffer (lote por frame) e
        -- envia — não grava no modData local (o eco do servidor aplica).
        GridInventory_Search._buffer = GridInventory_Search._buffer or {}
        GridInventory_Search._buffer[containerKey or "_"] = GridInventory_Search._buffer[containerKey or "_"] or {}
        GridInventory_Search._buffer[containerKey or "_"][tostring(itemId)] = true
    else
        -- SP: modData local persiste direto.
        getPersistedSet(playerObj)[tostring(itemId)] = true
    end
end

--- Descarrega o buffer de revelações pendentes pro servidor (MP). Chamado uma
--- vez por frame (Events.OnTick) — agrupa os itens revelados no mesmo tick.
function GridInventory_Search.flushBuffer()
    local buffer = GridInventory_Search._buffer
    if not buffer then return end
    GridInventory_Search._buffer = nil
    local any = false
    for _ in pairs(buffer) do any = true break end
    if not any then return end
    local GridClientNetwork = require("Network/GridClientNetwork")
    if not (GridClientNetwork and GridClientNetwork.sendSearchReveal) then return end
    for containerKey, ids in pairs(buffer) do
        local list = {}
        for id in pairs(ids) do table.insert(list, id) end
        GridClientNetwork.sendSearchReveal(containerKey, list)
    end
end

-- Flush do buffer a cada tick (MP).
if Events and Events.OnTick then
    Events.OnTick.Add(function()
        GridInventory_Search.flushBuffer()
    end)
end

--- Marca um item como vasculhado SÓ na sessão local (sem enviar ao servidor).
--- Usado no eco do servidor (SYNC_SEARCH) — o servidor já persistiu.
---@param playerNum number
---@param containerKey string|nil
---@param itemId string|number
function GridInventory_Search.markSearchedSession(playerNum, containerKey, itemId)
    if itemId == nil then return end
    getSessionSet(playerNum)[tostring(itemId)] = true
end

--- Item NUNCA precisa ser vasculhado? Itens EQUIPADOS/vestidos (ex.: roupas em
--- corpses) já estão visíveis "no olho" — o jogador vê o que é sem vasculhar,
--- então não faz sentido ocultá-los (cairia no grid e precisaria vasculhar de
--- novo um item que ele já identificou).
---@param item InventoryItem
---@return boolean
function GridInventory_Search.isAlwaysRevealed(item)
    if not item then return true end
    if item.isEquipped and item:isEquipped() then return true end
    return false
end

--- Item vasculhado? (sessão, mais rápido). Fallback pro modData.
--- O item fica revelado em QUALQUER container (conhecimento por item, não por
--- container), então o containerKey não entra no estado.
---@param playerNum number
---@param containerKey string|nil
---@param itemId string|number
---@return boolean
function GridInventory_Search.isSearched(playerNum, containerKey, itemId)
    if itemId == nil then return true end
    local sid = tostring(itemId)
    local byPlayer = GridInventory_Search.sessions[playerNum]
    if byPlayer and byPlayer[sid] then return true end
    -- Fallback: o modData pode ter sido sincronizado (MP) depois do seed da
    -- sessão; confere o persistido e cacheia.
    local playerObj = playerNum ~= nil and getSpecificPlayer(playerNum)
    if playerObj then
        local persisted = getPersistedSet(playerObj)
        if persisted[sid] then
            getSessionSet(playerNum)[sid] = true
            return true
        end
    end
    return false
end

--- Container PRECISA ser vasculhado? (opção ligada + container de mundo + já
--- aberto antes + não totalmente vasculhado).
---@param playerNum number
---@param container ItemContainer
---@return boolean, string|nil precisa, containerKey
function GridInventory_Search.needsSearch(playerNum, container)
    if not container then return false, nil end
    local containerKey = GridInventory_Search.containerKey(container)
    if not containerKey then return false, nil end -- chão/jogador

    local playerObj = playerNum ~= nil and getSpecificPlayer(playerNum)
    if not playerObj then return false, containerKey end

    -- Só revela se o jogador JÁ abriu o container (1ª abertura = tudo oculto
    -- é o loot a vasculhar; antes disso o refresh ainda não o posicionou).
    if not GridInventory_Search.hasOpened(playerObj, containerKey) then
        return true, containerKey
    end
    return false, containerKey
end

--- Se o container tem pelo menos um item ainda NÃO vasculhado.
---@param playerNum number
---@param containerKey string
---@param items table lista de itens nativos (getItems)
---@return boolean
function GridInventory_Search.hasHiddenItems(playerNum, containerKey, items)
    if not containerKey or not items then return false end
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it.getID then
            -- Equipado/vestido (ex.: roupa em corpse): já visível, nunca oculta.
            if GridInventory_Search.isAlwaysRevealed(it) then
                -- skip
            elseif not GridInventory_Search.isSearched(playerNum, containerKey, it:getID()) then
                return true
            end
        end
    end
    return false
end

--- Revela TODOS os itens do container (usado quando a busca é instantânea ou
--- no perform da ação).
---@param playerNum number
---@param containerKey string
---@param items table lista de itens nativos
function GridInventory_Search.revealAll(playerNum, containerKey, items)
    if not containerKey or not items then return end
    local playerObj = playerNum ~= nil and getSpecificPlayer(playerNum)
    if not playerObj then return end
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it.getID then
            GridInventory_Search.markSearched(playerObj, containerKey, it:getID())
        end
    end
end

--- Conta quantas PILHAS (líderes) do container ainda estão ocultas. Usado no
--- header ("Vasculhar (N)") — N é nº de pilhas, não de itens individuais.
---@param playerNum number
---@param containerKey string
---@param items table lista de itens nativos
---@return number
function GridInventory_Search.countHiddenStacks(playerNum, containerKey, items)
    if not containerKey or not items then return 0 end
    local counted = {}
    local hidden = 0
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if it and it.getID then
            -- Equipado/vestido (roupa em corpse): nunca conta como oculto.
            if GridInventory_Search.isAlwaysRevealed(it) then
                -- skip
            else
                local id = tostring(it:getID())
                if not GridInventory_Search.isSearched(playerNum, containerKey, id) then
                    -- Só conta o LÍDER da pilha (o item que "guia" a célula).
                    -- Pilhas: o líder é quem tem posição própria; membros têm a
                    -- MESMA posição (x/y iguais). Contamos cada posição única.
                    local md = it.getModData and it:getModData() or nil
                    if md and tonumber(md.gridX) then
                        local posKey = tostring(md.gridX) .. "_" .. tostring(md.gridY) .. "_" .. tostring(md.gridRot or false)
                        if not counted[posKey] then
                            counted[posKey] = true
                            hidden = hidden + 1
                        end
                    else
                        -- Sem posição salva (não posicionado ainda): conta individual.
                        hidden = hidden + 1
                    end
                end
            end
        end
    end
    return hidden
end

-- ============================================================================
-- AUTO-REVELAÇÃO de transferência do JOGADOR
-- ============================================================================
-- O que VOCÊ coloca num container nasce revelado (você sabe o que acabou de
-- pôr). Só loot não identificado (que já estava lá na 1ª abertura) fica oculto.
-- A marca é POR ITEM (vale em qualquer container), então o item colocado fica
-- revelado pro jogador onde quer que ele vá.
-- Intercepta o ISInventoryPane:transferItemsByWeight (cobre Take All / Transfer
-- All / mover via menu e os caminhos do mod que chamam o pane). Quando o
-- destino é um container de mundo e a origem é o inventário do jogador, marca
-- os itens transferidos como vasculhados.
GridInventory_Search.transferHookInstalled = false
if not GridInventory_Search.transferHookInstalled and ISInventoryPane then
    GridInventory_Search.transferHookInstalled = true
    local og_transferByWeight = ISInventoryPane.transferItemsByWeight
    function ISInventoryPane:transferItemsByWeight(items, target)
        if og_transferByWeight then
            og_transferByWeight(self, items, target)
        end
        if not items or not target then return end
        local playerObj = self and self.player and self.playerObj
            or (self.inventoryPage and self.inventoryPage.playerObj)
        if not playerObj and getPlayer then playerObj = getPlayer() end
        if not playerObj then return end
        -- Só auto-revela se o DESTINO é um container de mundo vasculhável
        -- (mochilas do inventário do jogador retornam nil → skip).
        local destKey = GridInventory_Search.containerKey(target, playerObj)
        if not destKey then return end
        -- Origem = inventário do jogador (o item veio DELE) → revela.
        local pn = playerObj.getPlayerNum and playerObj:getPlayerNum() or 0
        for _, item in ipairs(items) do
            if item and item.getID then
                local src = item.getContainer and item:getContainer()
                local fromPlayer = src and src.isInCharacterInventory
                    and src:isInCharacterInventory(playerObj)
                if fromPlayer then
                    GridInventory_Search.markSearched(playerObj, destKey, item:getID())
                end
            end
        end
    end
end

return GridInventory_Search
