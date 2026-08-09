--- ScatterLayout.lua
--- Distribuição "natural" de loot em containers recém-abertos.
---
--- Por que determinístico:
---   O PZ NÃO sincroniza a tabela ModData de itens entre clientes (o mod grava
---   gridX/gridY localmente, sem transmit). Num servidor, dois jogadores podem
---   abrir o MESMO container em clientes diferentes. Se cada um sorteasse a
---   posição dos itens com math.random(), cada um veria um layout diferente e o
---   container "dessincronizaria" visualmente. Para NUNCA quebrar o MP, todo o
---   sorteio aqui é 100% determinístico:
---     seed = hash(identidade_do_container + id_do_item)
---   e os itens são processados em ordem fixa (ordenados por getID(), o net
---   entity ID, que É sincronizado entre clientes). Logo, qualquer cliente que
---   abra o mesmo container com os mesmos itens deriva EXATAMENTE o mesmo
---   layout, sem precisar de um byte de tráfego de rede.
---
--- Consequências:
---   - Itens sem posição salva (modData.gridX/Y) são espalhados.
---   - Itens já posicionados pelo jogador continuam onde estão (a posição salva
---     tem prioridade no GridContainer:refresh).
---   - A grade nunca sobrepõe itens (canPlaceItem é respeitado) e, se o sorteio
---     não achar vaga após N tentativas, cai no findFreeSpace original (nunca
---     aumenta o overflow).

local ScatterLayout = {}

-- Liga/desliga o feature por completo.
ScatterLayout.enabled = true
-- Se true, também espalha o inventário pessoal do jogador e mochilas.
-- (Padrão false: o inventário do jogador continua organizado/compactado.)
ScatterLayout.scatterPlayerInventory = false
-- Número máximo de posições sorteadas por item antes do fallback organizado.
ScatterLayout.maxAttempts = 16

-- ─── PRNG determinístico (Park-Miller / MINSTD) ───────────────────────────────
-- Aritmética pura, sem bitwise e sem math.random (estado global). Os produtos
-- ficam abaixo de 2^53, então o resultado é bit-a-bit idêntico em qualquer
-- runtime Lua (5.1, Kahlua do PZ, Luajit).

local M = 2147483647 -- 2^31 - 1 (primo)
local A = 48271

--- Hash determinístico de string (DJB2) -> [0, 2^31-1).
local function hashString(str)
    local h = 5381
    for i = 1, #str do
        local c = str:byte(i)
        h = (h * 33 + c) % M
    end
    return h
end

--- Retorna uma função geradora de números em [0, 1).
local function newRNG(seed)
    local s = seed % M
    if s <= 0 then s = s + M - 1 end
    return function()
        s = (s * A) % M
        return (s - 1) / (M - 1)
    end
end

-- ─── Identidade determinística do container ───────────────────────────────────
-- Deve ser IGUAL em todos os clientes que enxergam o mesmo container.
-- Usamos o que o PZ sincroniza: tipo do container, tipo do objeto pai e as
-- coordenadas do quadrado no mundo (X/Y/Z). Para o inventário do jogador (só o
-- dono vê), a identidade é local mesmo — não importa para o MP.

---@param inventory ItemContainer
---@return string
function ScatterLayout.buildSeedKey(inventory)
    local key = "C:" .. tostring(inventory:getType())
    local parent = inventory:getParent()
    if parent then
        local ok = pcall(function()
            key = key .. ":P" .. tostring(parent:getType())
            if parent.getSquare then
                local sq = parent:getSquare()
                if sq and sq.getX then
                    key = key .. ":S" .. tostring(sq:getX()) .. "_" .. tostring(sq:getY()) .. "_" .. tostring(sq:getZ())
                end
            end
        end)
    end
    return key
end

--- Decide se o container deve receber layout espalhado.
--- Containers de loot (mundo, cadáveres, chão) sim; inventário/mochilas do
--- jogador apenas se scatterPlayerInventory estiver ligado.
---@param inventory ItemContainer
---@param playerNum number
---@return boolean
function ScatterLayout.shouldScatter(inventory, playerNum)
    if not ScatterLayout.enabled then return false end
    if ScatterLayout.scatterPlayerInventory then return true end
    local player = playerNum ~= nil and getSpecificPlayer(playerNum) or nil
    if player and inventory:isInCharacterInventory(player) then
        return false
    end
    return true
end

--- Sorteia uma posição livre para um item sem posição salva.
---@param grid GridCoreInstance
---@param itemId string|number
---@param w number largura natural do item
---@param h number altura natural do item
---@param seedKey string identidade determinística do container
---@param compatKey string? chave de empilhamento (itens compatíveis na mesma
---   célula podem compartilhar posição — ver GridCore:canPlaceItem)
---@param stackInfo table? { limit, units } — limite de unidades da pilha
---@return number, number, boolean|nil x, y, rotacionado (nil se não achou)
function ScatterLayout.place(grid, itemId, w, h, seedKey, compatKey, stackInfo)
    if not ScatterLayout.enabled then return nil end

    w, h = tonumber(w), tonumber(h)
    local rng = newRNG(hashString(tostring(seedKey) .. "#" .. tostring(itemId)))

    -- Empilháveis: se já existe uma pilha compatível (mesmo retângulo), o item
    -- se junta a ela em vez de sortear posição nova. Mantém determinismo: a
    -- posição da pilha vem do seed do PRIMEIRO item do tipo.
    if compatKey then
        local sx, sy, srot = grid:findCompatibleStack(itemId, w, h, compatKey, stackInfo)
        if sx then
            return sx, sy, srot
        end
    end

    for _ = 1, ScatterLayout.maxAttempts do
        -- Orientação natural (não rotacionada) primeiro
        local maxX = grid.width - w + 1
        local maxY = grid.height - h + 1
        if maxX >= 1 and maxY >= 1 then
            local x = 1 + math.floor(rng() * maxX)
            local y = 1 + math.floor(rng() * maxY)
            if grid:canPlaceItem(itemId, x, y, w, h, nil, compatKey, false, stackInfo) then
                return x, y, false
            end
        end

        -- Depois rotacionado (itens compridos "em pé")
        if w ~= h then
            local rMaxX = grid.width - h + 1
            local rMaxY = grid.height - w + 1
            if rMaxX >= 1 and rMaxY >= 1 then
                local x = 1 + math.floor(rng() * rMaxX)
                local y = 1 + math.floor(rng() * rMaxY)
                if grid:canPlaceItem(itemId, x, y, h, w, nil, compatKey, true, stackInfo) then
                    return x, y, true
                end
            end
        end
    end

    return nil, nil, nil
end

return ScatterLayout
