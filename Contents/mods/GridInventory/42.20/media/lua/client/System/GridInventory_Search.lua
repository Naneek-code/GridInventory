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

-- Memoização de containerKey: o cálculo (buildContainerRef → instanceof +
-- scan dos objetos do square + concat de string) roda por frame no render
-- (1x por grid + 1x por item). O resultado é ESTÁVEL pra vida do container
-- (coords/objIndex/sprite do mundo são fixos; o id do container-de-item é
-- fixo; o keyId de veículo é fixo) e o único ramo que varia por jogador
-- (isInCharacterInventory → nil) é coberto pela chave por playerNum.
-- Tabela com chaves FRACAS: container morto não vaza. O valor é { result }
-- (tabela envoltória) pra distinguir "não computado" de "computado nil".
local containerKeyCache = setmetatable({}, { __mode = "k" })

--- Chave estável de um container (string). Retorna nil p/ containers que nunca
--- são ocultados (chão, inventário do jogador).
---@param container ItemContainer
---@param playerObj IsoPlayer|nil jogador para checar se o container é do inventário
---   dele (mochilas vestidas/equipadas/nas mãos) — esses NUNCA são vasculhados.
---@return string|nil
function GridInventory_Search.containerKey(container, playerObj)
    if not container then return nil end
    local pIdx = (playerObj and playerObj.getPlayerNum and playerObj:getPlayerNum()) or -1
    local perPlayer = containerKeyCache[container]
    if not perPlayer then
        perPlayer = {}
        containerKeyCache[container] = perPlayer
    end
    local v = perPlayer[pIdx]
    if v then return v[1] end

    local result = GridInventory_Search._containerKeyUncached(container, playerObj)
    perPlayer[pIdx] = { result }
    return result
end

--- Cálculo sem cache (separado pra transparência/teste).
---@param container ItemContainer
---@param playerObj IsoPlayer|nil
---@return string|nil
function GridInventory_Search._containerKeyUncached(container, playerObj)
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

-- ============================================================================
-- Caches de PERFORMANCE do render
-- ============================================================================

-- Cache POR FRAME das consultas de busca (render), ESCOPADO pelo container
-- (chave fraca: container morto não vaza). O GridRender chama beginFrame() no
-- update() de cada grid; dentro de um MESMO frame o estado (itens do container
-- + revelações) não muda, então needsSearch/hasHiddenItems/countHiddenStacks/
-- isItemHidden compartilham UMA varredura do container por frame, em vez de
-- re-iterar os itens e re-checar cada um várias vezes. Escopar pelo OBJETO do
-- container (mesmo padrão do GridContainer.instances) evita colisão de cache
-- se dois containers chegarem a compartilhar a MESMA containerKey.
-- _searchVersion é incrementado a cada revelação (markSearched/SYNC_SEARCH):
-- invalida o cache na hora, sem esperar o próximo frame.
local _frame = 0
local _searchVersion = 0
local _frameCache = setmetatable({}, { __mode = "k" }) -- [container] = { ["pn|containerKey"] = entry }

--- Marca o início de um frame (chamado pelo update() de cada GridRender).
--- Faz o cache daquele frame ser recalculado (os itens podem ter mudado).
function GridInventory_Search.beginFrame()
    _frame = _frame + 1
end

--- (Re)calcula o info de busca de (playerNum, containerKey, container) se o
--- cache não estiver fresco pro frame atual; senão reusa. Retorna { hasAny,
--- hiddenStacks, hiddenIds } — hiddenIds = itemId -> true dos itens AINDA
--- ocultos. nil se containerKey é inválido (nunca oculta: chão/jogador).
---@param playerNum number
---@param containerKey string
---@param container ItemContainer
---@return table|nil
local function getFrameInfo(playerNum, containerKey, container)
    if not containerKey or not container then return nil end
    local perPlayer = _frameCache[container]
    if not perPlayer then
        perPlayer = {}
        _frameCache[container] = perPlayer
    end
    local cacheKey = tostring(playerNum or "") .. "|" .. containerKey
    local entry = perPlayer[cacheKey]
    if entry and entry.stamp == _frame and entry.version == _searchVersion then
        return entry
    end

    local byPlayer = GridInventory_Search.sessions[playerNum]
    if not byPlayer then
        byPlayer = {}
        GridInventory_Search.sessions[playerNum] = byPlayer
    end
    -- Persistido lido UMA vez por varredura (fallback do MP pós-join; a sessão
    -- já foi semeada do mesmo modData no seed).
    local persisted = nil
    if getSpecificPlayer and playerNum ~= nil then
        local playerObj = getSpecificPlayer(playerNum)
        if playerObj then persisted = getPersistedSet(playerObj) end
    end

    local hiddenIds = {}
    local counted = {} -- posKey -> true (dedupe de pilhas na contagem)
    local hiddenStacks = 0
    local hasAny = false
    local items = container.getItems and container:getItems() or nil
    if items then
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it and it.getID then
                -- Equipado/vestido (ex.: roupa em corpse): já visível, nunca oculta.
                if not GridInventory_Search.isAlwaysRevealed(it) then
                    local sid = tostring(it:getID())
                    local searched = byPlayer[sid]
                    if not searched and persisted then
                        searched = persisted[sid]
                        if searched then byPlayer[sid] = true end
                    end
                    if not searched then
                        hiddenIds[sid] = true
                        hasAny = true
                        -- Só conta o LÍDER da pilha: posições iguais = 1 pilha.
                        local md = it.getModData and it:getModData() or nil
                        if md and tonumber(md.gridX) then
                            local posKey = tostring(md.gridX) .. "_" .. tostring(md.gridY) .. "_" .. tostring(md.gridRot or false)
                            if not counted[posKey] then
                                counted[posKey] = true
                                hiddenStacks = hiddenStacks + 1
                            end
                        else
                            hiddenStacks = hiddenStacks + 1
                        end
                    end
                end
            end
        end
    end

    entry = {
        stamp = _frame,
        version = _searchVersion,
        hasAny = hasAny,
        hiddenStacks = hiddenStacks,
        hiddenIds = hiddenIds,
    }
    perPlayer[cacheKey] = entry
    return entry
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
    -- Invalida o cache de render na hora: a revelação muda o resultado das
    -- consultas de busca IMEDIATAMENTE (sem esperar o próximo frame).
    _searchVersion = _searchVersion + 1

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
    _searchVersion = _searchVersion + 1
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
---@param container ItemContainer
---@return boolean
function GridInventory_Search.hasHiddenItems(playerNum, containerKey, container)
    local info = getFrameInfo(playerNum, containerKey, container)
    return info and info.hasAny or false
end

--- Item está OCULTO neste frame (render)? Usa o cache do frame (O(1)) quando
--- disponível; senão cai no isSearched (lookup O(1) de sessão + fallback).
--- Pré-condições do chamador (GridRender:isItemHidden): containerKey válido,
--- busca ligada, item não equipado. Aqui é só "está no conjunto de ocultos?".
---@param playerNum number
---@param containerKey string
---@param itemId string|number
---@param container ItemContainer
---@return boolean
function GridInventory_Search.isItemHidden(playerNum, containerKey, itemId, container)
    if itemId == nil then return false end
    if not containerKey then return false end
    local perPlayer = container and _frameCache[container]
    if perPlayer then
        local cacheKey = tostring(playerNum or "") .. "|" .. containerKey
        local entry = perPlayer[cacheKey]
        if entry and entry.stamp == _frame and entry.version == _searchVersion then
            return not not entry.hiddenIds[tostring(itemId)]
        end
    end
    return not GridInventory_Search.isSearched(playerNum, containerKey, itemId)
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
function GridInventory_Search.countHiddenStacks(playerNum, containerKey, container)
    local info = getFrameInfo(playerNum, containerKey, container)
    return info and info.hiddenStacks or 0
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
