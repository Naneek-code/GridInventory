-- search_test.lua — GridInventory_Search: busca de containers do mundo (Tarkov).
-- Cobre: chave estável por container, estado POR JOGADOR persistente no modData,
-- revelação por item, contagem de pilhas ocultas, auto-revela transferência.

local H = require("harness")
H.setName("search_test")

-- O GridInventory_Search mora em client/System (fora dos paths do harness).
-- GRID_MOD_BASE (absoluto, exportado pelo run_tests.sh) resolve de QUALQUER cwd;
-- o caminho relativo é o fallback pra rodar a suite direto da raiz do repo.
local MOD_BASE = os.getenv("GRID_MOD_BASE")
    or "Contents/mods/GridInventory"
package.path = package.path
    .. ";" .. MOD_BASE .. "/42.20/media/lua/client/?.lua"
    .. ";" .. MOD_BASE .. "/42.20/media/lua/client/System/?.lua"

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
    H.ok(GridInventory_Search.countHiddenStacks(0, key, container) == 2,
        "2 pilhas ocultas inicialmente")

    -- revela tudo
    GridInventory_Search.revealAll(0, key, container:getItems())
    H.ok(GridInventory_Search.isSearched(0, key, "sA") == true and GridInventory_Search.isSearched(0, key, "sB") == true,
        "revealAll revela todos")
    H.ok(GridInventory_Search.countHiddenStacks(0, key, container) == 0,
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
    H.ok(GridInventory_Search.countHiddenStacks(0, key, container) == 1,
        "pilha (mesma posição) conta como 1 [" .. GridInventory_Search.countHiddenStacks(0, key, container) .. "]")
end

-- ─── Regressão: item revelado segue revelado em OUTRO container ─────────────
-- O estado é POR ITEM (não por container): mover um item já vasculhado de um
-- container de mundo pra outro NÃO pode escondê-lo de novo.
do
    local item = makeItem("m1")
    local containerA = makeWorldContainer({ item }, 1)
    local containerB = makeWorldContainer({ item }, 2)
    local keyA = GridInventory_Search.containerKey(containerA)
    local keyB = GridInventory_Search.containerKey(containerB)
    H.ok(keyA ~= keyB, "containers diferentes têm chaves diferentes")

    GridInventory_Search.markSearched(_players[0], keyA, "m1")
    H.ok(GridInventory_Search.isSearched(0, keyA, "m1") == true, "revelado em A")
    H.ok(GridInventory_Search.isSearched(0, keyB, "m1") == true,
        "item revelado em A também é visto em B (persistência POR ITEM)")

    -- e sobrevive a relogar (novo cache de sessão)
    GridInventory_Search.sessions = {}
    H.ok(GridInventory_Search.isSearched(0, keyB, "m1") == true,
        "após reset de sessão, continua revelado em B (modData persistente)")

    -- countHiddenStacks também respeita (B não re-esconde o item revelado em A)
    H.ok(GridInventory_Search.countHiddenStacks(0, keyB, containerB) == 0,
        "B não conta o item revelado em A como pilha oculta")
end

-- ─── Migração do formato antigo (container -> {itens}) ──────────────────────
do
    -- simula save antigo: md["GridInventory_Searched"][containerKey][itemId] = true
    local md = _players[0]:getModData()
    local root = {}
    root["obj:1_2_0:3:crate"] = { old1 = true, old2 = true }
    md["GridInventory_Searched"] = root
    GridInventory_Search.sessions = {}
    H.ok(GridInventory_Search.isSearched(0, "qualquer", "old1") == true,
        "migração: item do formato antigo (container->itens) vira plano")
    H.ok(GridInventory_Search.isSearched(0, "qualquer", "old2") == true,
        "migração: segundo item também migra")
    H.ok(GridInventory_Search.isSearched(0, "qualquer", "inexistente") == false,
        "migração: item não marcado segue oculto")
    local flat = md["GridInventory_Searched"]
    H.ok(flat["old1"] == true and flat["old2"] == true, "modData reescrito no formato plano")
    H.ok(type(flat["obj:1_2_0:3:crate"]) ~= "table", "container antigo removido do modData")
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
    H.ok(GridInventory_Search.hasHiddenItems(0, key, container) == true,
        "só o não-equipado conta como oculto (hasHiddenItems true)")
    GridInventory_Search.markSearched(_players[0], key, "neq1")
    H.ok(GridInventory_Search.hasHiddenItems(0, key, container) == false,
        "equipado não conta: marcado o não-equipado -> nada oculto")
end

-- ─── Cache POR FRAME (render): beginFrame + isItemHidden ────────────────────
do
    local itA = makeItem("fcA")
    local container = makeWorldContainer({ itA }, 1)
    local key = GridInventory_Search.containerKey(container)
    GridInventory_Search.sessions = {}
    GridInventory_Search.beginFrame()

    -- frame com item oculto: isItemHidden via cache bate com o scan
    H.ok(GridInventory_Search.hasHiddenItems(0, key, container) == true,
        "frame: item oculto detectado na varredura")
    H.ok(GridInventory_Search.isItemHidden(0, key, "fcA", container) == true,
        "frame: isItemHidden via cache")

    -- revela no MESMO frame → _searchVersion invalida o cache na hora
    GridInventory_Search.markSearched(_players[0], key, "fcA")
    H.ok(GridInventory_Search.hasHiddenItems(0, key, container) == false,
        "frame: revelação invalida o cache no mesmo frame")
    H.ok(GridInventory_Search.isItemHidden(0, key, "fcA", container) == false,
        "frame: item revelado deixa de ser oculto")

    -- frame NOVO (beginFrame) recalcula: só o novo item conta como oculto
    local container2 = makeWorldContainer({ itA, makeItem("fcB") }, 1)
    local key2 = GridInventory_Search.containerKey(container2)
    GridInventory_Search.beginFrame()
    H.ok(GridInventory_Search.countHiddenStacks(0, key2, container2) == 1,
        "frame novo: só o item novo é oculto (itens podem ter mudado)")

    -- container DIFERENTE com a MESMA containerKey (mock reusa as props)
    -- não colide no cache: o cache é escopado pelo objeto do container.
    local container3 = makeWorldContainer({ makeItem("fcC") }, 1)
    local key3 = GridInventory_Search.containerKey(container3)
    H.ok(key3 == key2, "container mock com mesmas props tem a mesma chave")
    H.ok(GridInventory_Search.countHiddenStacks(0, key3, container3) == 1,
        "container diferente com a mesma chave não colide no cache")
end

-- ─── Animação de DESCOBERTA (Tarkov) ────────────────────────────────────────
do
    GridInventory_Search.revealAnim = {}

    -- Sem revelação: sem animação.
    H.ok(GridInventory_Search.getRevealProgress("nao_revelado") == nil,
        "anim: item não revelado não tem progresso")

    -- markSearched registra a animação do item.
    GridInventory_Search.markSearched(_players[0], "keyAnim", "anim1")
    local p = GridInventory_Search.getRevealProgress("anim1")
    H.ok(p ~= nil and p >= 0 and p <= 1, "anim: markSearched registra o wipe (progresso " .. tostring(p) .. ")")

    -- markSearchedSession também registra (eco do MP).
    GridInventory_Search.markSearchedSession(0, "keyAnim", "anim2")
    H.ok(GridInventory_Search.getRevealProgress("anim2") ~= nil,
        "anim: markSearchedSession registra o wipe")

    -- Limpeza lazy: força o tempo a passar (o stub avança a cada getTimeInMillis)
    -- até a animação expirar.
    local guard = 0
    while GridInventory_Search.getRevealProgress("anim1") ~= nil and guard < 500 do
        guard = guard + 1
    end
    H.ok(GridInventory_Search.getRevealProgress("anim1") == nil,
        "anim: wipe expira sozinho após o tempo")
    H.ok(GridInventory_Search.revealAnim["anim1"] == nil,
        "anim: chave expirada é removida do mapa (lazy)")
end

H.finish()
