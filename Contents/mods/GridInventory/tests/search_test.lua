-- search_test.lua — GridInventory_Search: busca de containers do mundo (Tarkov).
-- Cobre: chave estável por container, estado POR JOGADOR persistente no modData,
-- revelação por item, contagem de pilhas ocultas, auto-revela transferência.

local H = require("harness")
H.setName("search_test")

-- O GridInventory_Search mora em client/System (fora dos paths do harness).
package.path = package.path
    .. ";Contents/mods/GridInventory/42.20/media/lua/client/?.lua"
    .. ";Contents/mods/GridInventory/42.20/media/lua/client/System/?.lua"

-- ── Stubs do ambiente PZ ─────────────────────────────────────────────────────
local _players = {}
_G.getSpecificPlayer = function(pn) return _players[pn] end
_G.instanceof = function() return false end
_G.getPlayer = function() return _players[0] end
_G.ISTimedActionQueue = { getTimedActionQueue = function() return nil end }
_G.getCell = function() return { getGridSquare = function() return nil end } end
_G.getSandboxOptions = function() return nil end
-- ISInventoryPane mockado ANTES do require: o hook de auto-revelação instala
-- no load do módulo (se ISInventoryPane existir).
_G.ISInventoryPane = {}

-- ItemContainer mock: tipo, pai (objeto no mundo), itens.
local seq = 0
local function makeItem(id)
    seq = seq + 1
    return {
        getID = function() return id end,
        getFullType = function() return "Base.Test" .. seq end,
        getModData = function()
            if not _G.__md then _G.__md = {} end
            if not _G.__md[id] then _G.__md[id] = {} end
            return _G.__md[id]
        end,
        getContainer = function() return nil end,
    }
end

local function makeWorldContainer(items, objIndex)
    local list = items or {}
    -- parent declarado ANTES e preenchido depois: no Lua 5.1, uma closure
    -- definida DENTRO de uma tabela literal captura a variável como nil (a
    -- atribuição ainda não completou) → declarar primeiro evita o bug.
    local parent = {}
    parent.getSquare = function()
        return { getX = function() return 5 end, getY = function() return 6 end, getZ = function() return 0 end,
            getObjects = function()
                return { size = function() return 3 end,
                    get = function(_, i)
                        if i == objIndex then return parent end
                        return {}
                    end }
            end }
    end
    parent.getSprite = function() return { getName = function() return "crate" end } end
    local container = {
        getType = function() return "crate" end,
        getItems = function()
            return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
        end,
        getContainingItem = function() return nil end,
        getParent = function() return parent end,
    }
    -- associa item:getContainer ao container
    for _, it in ipairs(list) do it.getContainer = function() return container end end
    return container
end

-- Mock de jogador com modData persistente (player:getModData).
local function makePlayer(pn)
    local p = {
        getPlayerNum = function() return pn end,
        getModData = function()
            if not _players.__pdm then _players.__pdm = {} end
            if not _players.__pdm[pn] then _players.__pdm[pn] = {} end
            return _players.__pdm[pn]
        end,
        getInventory = function() return nil end,
        isInCharacterInventory = function() return false end,
    }
    return p
end

-- Limpa estado global entre testes
local function resetPlayers()
    _players = {}
    _players[0] = makePlayer(0)
    _players[1] = makePlayer(1)
    _G.__md = {}
    -- limpa o cache de sessão do módulo
    local S = require("System/GridInventory_Search")
    S.sessions = {}
end

local GridInventory_Search = require("System/GridInventory_Search")
resetPlayers()

-- ─── Chave estável do container ─────────────────────────────────────────────
do
    local c = makeWorldContainer({}, 1)
    local key = GridInventory_Search.containerKey(c)
    H.ok(key ~= nil, "container de mundo tem chave [" .. tostring(key) .. "]")
    local key2 = GridInventory_Search.containerKey(makeWorldContainer({}, 1))
    H.ok(key == key2, "mesma chave para o mesmo objeto [estável]")
    -- objIndex diferente → chave diferente
    local key3 = GridInventory_Search.containerKey(makeWorldContainer({}, 2))
    H.ok(key ~= key3, "objIndex diferente → chave diferente")
end

-- ─── Chão / inventário do jogador nunca ocultam ─────────────────────────────
do
    local floor = {
        getType = function() return "floor" end,
        getParent = function() return nil end,
        getContainingItem = function() return nil end,
    }
    H.ok(GridInventory_Search.containerKey(floor) == nil, "chão não tem chave (nunca oculta)")

    local playerInv = {
        getType = function() return "inventory" end,
        getParent = function()
            return { getType = function() return "IsoPlayer" end }
        end,
        getContainingItem = function() return nil end,
    }
    H.ok(GridInventory_Search.containerKey(playerInv) == nil, "inventário do jogador não tem chave")
end

-- ─── MOCHILA do jogador (vestida/equipada) nunca oculta ─────────────────────
-- Container dentro do inventário do jogador (isInCharacterInventory) → nil,
-- mesmo sendo uma bolsa (ref.type == "item"). Sem isso, mover itens entre
-- bolsas do próprio inventário pedia re-search.
do
    local bagItem = { getID = function() return "bag123" end }
    local wornBag = {
        getType = function() return "bag" end,
        getParent = function() return bagItem end,
        getContainingItem = function() return bagItem end,
        isInCharacterInventory = function() return true end,
    }
    H.ok(GridInventory_Search.containerKey(wornBag, _players[0]) == nil,
        "bolsa vestida/equipada do jogador NÃO tem chave (nunca oculta)")

    -- bolsa NO CHÃO (isInCharacterInventory false) continua sendo mundo
    local floorBag = {
        getType = function() return "bag" end,
        getParent = function() return bagItem end,
        getContainingItem = function() return bagItem end,
        isInCharacterInventory = function() return false end,
    }
    H.ok(GridInventory_Search.containerKey(floorBag, _players[0]) ~= nil,
        "bolsa no chão ainda é mundo (tem chave)")

    -- sem playerObj: mantém o comportamento (não pode checar isInCharacterInventory)
    H.ok(GridInventory_Search.containerKey(wornBag) ~= nil,
        "sem playerObj, mochila tem chave (não dá pra saber se é do jogador)")
end

-- ─── Estado POR JOGADOR (persistente no modData) ────────────────────────────
do
    local items = { makeItem("a1") }
    local container = makeWorldContainer(items, 1)
    local key = GridInventory_Search.containerKey(container)

    -- jogador 0 vasculha o item a1
    GridInventory_Search.markSearched(_players[0], key, "a1")
    H.ok(GridInventory_Search.isSearched(0, key, "a1") == true, "jogador 0 vê a1 vasculhado")
    H.ok(GridInventory_Search.isSearched(1, key, "a1") == false, "jogador 1 NÃO vê a1 (por jogador)")
    H.ok(GridInventory_Search.isSearched(0, key, "outro") == false, "item não vasculhado -> false")
end

-- ─── Persistência: estado sobrevive a "recarregar" (novo cache de sessão) ──
do
    local items = { makeItem("p1") }
    local container = makeWorldContainer(items, 1)
    local key = GridInventory_Search.containerKey(container)
    GridInventory_Search.markSearched(_players[0], key, "p1")
    -- simula relogar: zera o cache de sessão, o modData (persistido) fica
    GridInventory_Search.sessions = {}
    H.ok(GridInventory_Search.isSearched(0, key, "p1") == true,
        "após reset de sessão, item continua vasculhado (modData persistente)")
end

-- ─── Revelar tudo + contagem de pilhas ocultas ──────────────────────────────
do
    local itA = makeItem("sA")
    local itB = makeItem("sB")
    local items = { itA, itB }
    local container = makeWorldContainer(items, 1)
    local key = GridInventory_Search.containerKey(container)

    -- nenhum vasculhado → 2 pilhas ocultas (cada um com posição própria)
    itA:getModData().gridX, itA:getModData().gridY = 1, 1
    itB:getModData().gridX, itB:getModData().gridY = 1, 2
    H.ok(GridInventory_Search.countHiddenStacks(0, key, container:getItems()) == 2,
        "2 pilhas ocultas inicialmente")

    -- revela tudo
    GridInventory_Search.revealAll(0, key, container:getItems())
    H.ok(GridInventory_Search.isSearched(0, key, "sA") == true and GridInventory_Search.isSearched(0, key, "sB") == true,
        "revealAll revela todos")
    H.ok(GridInventory_Search.countHiddenStacks(0, key, container:getItems()) == 0,
        "0 pilhas ocultas após revealAll")
end

-- ─── Pilha (mesma posição) conta como 1 ─────────────────────────────────────
do
    local it1 = makeItem("st1")
    local it2 = makeItem("st2")
    local items = { it1, it2 }
    local container = makeWorldContainer(items, 1)
    local key = GridInventory_Search.containerKey(container)
    it1:getModData().gridX, it1:getModData().gridY = 2, 2
    it2:getModData().gridX, it2:getModData().gridY = 2, 2 -- mesma posição = pilha
    H.ok(GridInventory_Search.countHiddenStacks(0, key, container:getItems()) == 1,
        "pilha (mesma posição) conta como 1 [" .. GridInventory_Search.countHiddenStacks(0, key, container:getItems()) .. "]")
end

-- ─── Auto-revela: item transferido pelo jogador ─────────────────────────────
-- ISInventoryPane já foi mockado no topo (antes do require → hook instalado).
do
    H.ok(GridInventory_Search.transferHookInstalled == true, "hook de transferência instalado")

    local it = makeItem("t1")
    local container = makeWorldContainer({}, 1)
    local key = GridInventory_Search.containerKey(container)
    -- origem = inventário do jogador
    it.getContainer = function()
        return { isInCharacterInventory = function() return true end }
    end

    -- chama o hook instalado (ISInventoryPane.transferItemsByWeight)
    local pane = { playerObj = _players[0], inventoryPage = { playerObj = _players[0] } }
    ISInventoryPane.transferItemsByWeight(pane, { it }, container)
    H.ok(GridInventory_Search.isSearched(0, key, "t1") == true,
        "item transferido pelo jogador auto-revela")

    -- item de ORIGEM não-jogador (ex.: outro container) NÃO auto-revela
    GridInventory_Search.sessions = {}
    local it2 = makeItem("t2")
    it2.getContainer = function() return container end -- origem = próprio container
    ISInventoryPane.transferItemsByWeight(pane, { it2 }, container)
    H.ok(GridInventory_Search.isSearched(0, key, "t2") == false,
        "item de origem não-jogador NÃO auto-revela")
end

-- ─── Itens EQUIPADOS (roupa em corpse) nunca precisam ser vasculhados ───────
do
    local equipped = makeItem("eq1")
    equipped.isEquipped = function() return true end
    H.ok(GridInventory_Search.isAlwaysRevealed(equipped) == true,
        "item equipado -> sempre revelado")

    local notEquipped = makeItem("neq1")
    notEquipped.isEquipped = function() return false end
    H.ok(GridInventory_Search.isAlwaysRevealed(notEquipped) == false,
        "item NÃO equipado -> pode precisar vasculhar")

    -- hasHiddenItems ignora itens equipados
    local items = { notEquipped, equipped }
    local container = makeWorldContainer(items, 1)
    local key = GridInventory_Search.containerKey(container)
    GridInventory_Search.sessions = {}
    H.ok(GridInventory_Search.hasHiddenItems(0, key, container:getItems()) == true,
        "só o não-equipado conta como oculto (hasHiddenItems true)")
    GridInventory_Search.markSearched(_players[0], key, "neq1")
    H.ok(GridInventory_Search.hasHiddenItems(0, key, container:getItems()) == false,
        "equipado não conta: marcado o não-equipado -> nada oculto")
end

H.finish()
