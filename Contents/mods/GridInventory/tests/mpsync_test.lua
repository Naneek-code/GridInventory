-- mpsync_test.lua — lógica server-mandatory do MP.
-- Cobre: GridProtocol.buildContainerRef, isAdmin, processMove via OnClientCommand
-- (ok/inválido/notfound/clear/equipped), stacking na validação, CLEAR_HAND,
-- REQ_OVERRIDES admin-only, e o SYNC_ITEM do cliente (eco aplicado).

local H = require("harness")
H.setName("mpsync_test")

-- ── Stubs do ambiente ───────────────────────────────────────────────────────
_G.isServer = function() return true end
_G.getTimestampMs = function() return 0 end
_G.instanceof = function(a, b)
    return (a and a._isPlayer) and b == "IsoPlayer" or false
end
_G.sendServerCommand = function() end
_G.getCell = function() return { getGridSquare = function() return nil end } end

local onClientCommand = nil
local onServerCommand = nil
_G.Events = {
    OnClientCommand = { Add = function(fn) onClientCommand = fn end },
    OnServerCommand = { Add = function(fn) onServerCommand = fn end },
    OnTick = { Add = function() end },
    OnGameBoot = { Add = function() end },
    OnGameStart = { Add = function() end },
}

-- GridDevTool mock
_G.GridDevTool = { Overrides = {}, replaceOverrides = function(self, ov) self.Overrides = ov end }

package.path = H.base .. "/42.20/media/lua/server/?.lua;"
    .. H.base .. "/42.20/media/lua/client/?.lua;"
    .. package.path

local GridProtocol = require("Network/GridProtocol")
local GridContainer = require("DataModel/GridContainer")
local GridServerNetwork = require("Network/GridServerNetwork")
local GridClientNetwork = require("Network/GridClientNetwork")

-- ── Mocks de container/item ─────────────────────────────────────────────────
local function makeItem(id, fullType, weight, gx, gy, rot, opts)
    opts = opts or {}
    local md = { gridX = gx, gridY = gy, gridRot = rot or false }
    return {
        getID = function() return id end,
        getModData = function() return md end,
        getFullType = function() return fullType or "Base.Test" .. id end,
        getWeight = function() return weight or 0.1 end,
        canStack = function() return true end,
        getCount = function() return 1 end,
        isHidden = function() return false end,
        isEquipped = function() return opts.equipped or false end,
        getAttachedSlot = function() return opts.attachedSlot or -1 end,
        getContainer = function() return opts.container end,
    }
end

local function makeContainer(items, cap, typeName, isPlayerInv, playerMock)
    local list = items
    local parent = nil
    if isPlayerInv then parent = playerMock end
    return {
        _isPlayer = isPlayerInv or false,
        getItems = function()
            return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
        end,
        getItemWithID = function(self, id)
            for _, it in ipairs(list) do
                if it:getID() == id then return it end
            end
            return nil
        end,
        getCapacity = function() return cap or 6 end,
        getType = function() return typeName or "crate" end,
        getParent = function() return parent end,
        getContainingItem = function() return nil end,
        isInCharacterInventory = function() return isPlayerInv or false end,
    }
end

local function makePlayer(invItems)
    local player = { _isPlayer = true }
    local inv = makeContainer(invItems, 6, "crate", true, player)
    player._inv = inv
    player.getInventory = function() return inv end
    player.getPrimaryHandItem = function() return nil end
    player.getSecondaryHandItem = function() return nil end
    player.getSquare = function() return nil end
    player.getUsername = function() return "tester" end
    player.removeFromHands = function() end
    player.getRole = function() return nil end
    player.getAccessLevel = function() return "player" end
    return player
end

-- helper: chama um REQUEST_MOVE via o handler do servidor e devolve o que foi enviado
local function doMove(player, args)
    GridContainer.instances = {}
    local sent = {}
    -- sendServerCommand tem 2 formas: (module, cmd, args) e (player, module, cmd, args)
    _G.sendServerCommand = function(a1, a2, a3, a4)
        if type(a1) == "string" then
            table.insert(sent, { cmd = a2, args = a3 })
        else
            table.insert(sent, { cmd = a3, args = a4 })
        end
    end
    onClientCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.REQUEST_MOVE, player, args)
    return sent
end

-- helper: chama um REQUEST_REORDER (lote) via o handler do servidor
local function doReorder(player, moves, ref)
    GridContainer.instances = {}
    local sent = {}
    _G.sendServerCommand = function(a1, a2, a3, a4)
        if type(a1) == "string" then
            table.insert(sent, { cmd = a2, args = a3 })
        else
            table.insert(sent, { cmd = a3, args = a4 })
        end
    end
    onClientCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.REQUEST_REORDER, player, {
        ref = ref or { type = "player" },
        gridContainer = "sig-test",
        manual = true,
        moves = moves,
    })
    return sent
end

-- ─── Teste 1: buildContainerRef — inventário do jogador ─────────────────────
do
    local p = makePlayer({})
    local ref = GridProtocol.buildContainerRef(p:getInventory())
    H.ok(ref and ref.type == "player", "inventário do player -> ref tipo player [" .. tostring(ref and ref.type) .. "]")
end

-- ─── Teste 2: buildContainerRef — container de ITEM (bolsa) ─────────────────
do
    local bagItem = { getID = function() return 77 end }
    local bagInv = { getContainingItem = function() return bagItem end }
    local ref = GridProtocol.buildContainerRef(bagInv)
    H.ok(ref and ref.type == "item" and ref.itemId == 77, "bolsa -> ref tipo item [" .. tostring(ref and ref.type) .. "]")
end

-- ─── Teste 3: isAdmin — nega jogador normal ─────────────────────────────────
do
    local p = { getRole = function() return nil end, getAccessLevel = function() return "player" end }
    H.ok(GridServerNetwork.isAdmin(p) == false, "player normal NÃO é admin")
end

-- ─── Teste 4: isAdmin — aceita accessLevel admin ────────────────────────────
do
    local p = { getRole = function() return nil end, getAccessLevel = function() return "admin" end }
    H.ok(GridServerNetwork.isAdmin(p) == true, "accessLevel admin é admin")
end

-- ─── Teste 5: isAdmin — aceita role com admin power (B42 nativo) ────────────
do
    local role = { hasAdminPower = function() return true end }
    local p = { getRole = function() return role end, getAccessLevel = function() return "player" end }
    H.ok(GridServerNetwork.isAdmin(p) == true, "role com hasAdminPower() é admin")
end

-- ─── Teste 5b: isAdmin — NÃO existe Capability.Admin no B42; role sem admin
-- power nem nome admin não é admin mesmo com hasCapability genérica. ─────────
do
    _G.Capability = { AddItem = "AddItem" }
    local role = { hasCapability = function(self, cap) return cap == "AddItem" end }
    local p = { getRole = function() return role end, getAccessLevel = function() return "player" end }
    H.ok(GridServerNetwork.isAdmin(p) == false, "role só com AddItem (sem admin power) NÃO é admin")
    _G.Capability = nil
end

-- ─── Teste 6: REQUEST_MOVE — posição VÁLIDA grava no modData ───────────────
do
    local item = makeItem("it1", "Base.A", 0.1, nil, nil)
    local player = makePlayer({ item })
    local sent = doMove(player, { itemId = "it1", ref = { type = "player" }, x = 2, y = 1, rotated = false })
    local md = item:getModData()
    H.ok(md.gridX == 2 and md.gridY == 1, "modData gravado (2,1) [(" .. tostring(md.gridX) .. "," .. tostring(md.gridY) .. ")]")
    local syncSent = false
    for _, s in ipairs(sent) do
        if s.cmd == GridProtocol.COMMANDS.SYNC_ITEM then syncSent = true end
    end
    H.ok(syncSent, "SYNC_ITEM broadcastado")
end

-- ─── Teste 7: REQUEST_MOVE — COLISÃO → invalid + ERROR ──────────────────────
do
    local a = makeItem("a", "Base.A", 2.0, 1, 1) -- pesado (não empilha)
    local b = makeItem("b", "Base.B", 2.0, nil, nil)
    local player = makePlayer({ a, b })
    local sent = doMove(player, { itemId = "b", ref = { type = "player" }, x = 1, y = 1, rotated = false })
    local errSent = false
    local syncSent = false
    for _, s in ipairs(sent) do
        if s.cmd == GridProtocol.COMMANDS.ERROR then errSent = true end
        if s.cmd == GridProtocol.COMMANDS.SYNC_ITEM then syncSent = true end
    end
    H.ok(errSent, "colisão -> ERROR enviado")
    H.ok(syncSent == false, "colisão -> NÃO broadcasta posição")
end

-- ─── Teste 8: REQUEST_MOVE — EMPILHÁVEL compatível na mesma célula é ok ─────
do
    local a = makeItem("a", "Base.Same", 0.1, 1, 1)
    local b = makeItem("b", "Base.Same", 0.1, nil, nil)
    local player = makePlayer({ a, b })
    local sent = doMove(player, { itemId = "b", ref = { type = "player" }, x = 1, y = 1, rotated = false })
    local okSync = false
    for _, s in ipairs(sent) do
        if s.cmd == GridProtocol.COMMANDS.SYNC_ITEM then okSync = true end
    end
    H.ok(okSync, "empilhar compatível -> ok (SYNC_ITEM)")
end

-- ─── Teste 9: REQUEST_MOVE — item não encontrado → notfound (sem broadcast) ─
do
    local player = makePlayer({})
    local sent = doMove(player, { itemId = "ghost", ref = { type = "player" }, x = 1, y = 1, rotated = false })
    H.ok(#sent == 0, "item inexistente -> sem broadcast (vai pra fila pending) [n=" .. #sent .. "]")
end

-- ─── Teste 10: REQUEST_MOVE — item EQUIPADO → rejeitado (sem aplicar posição) ─
do
    local item = makeItem("weapon", "Base.W", 2.0, nil, nil, false, { equipped = true })
    local player = makePlayer({ item })
    local sent = doMove(player, { itemId = "weapon", ref = { type = "player" }, x = 1, y = 1, rotated = false })
    local syncSent = false
    for _, s in ipairs(sent) do
        if s.cmd == GridProtocol.COMMANDS.SYNC_ITEM then syncSent = true end
    end
    H.ok(syncSent == false, "item equipado -> NÃO aplica posição (sem SYNC_ITEM)")
end

-- ─── Teste 11: REQUEST_MOVE — CLEAR limpa o modData ─────────────────────────
do
    local item = makeItem("c1", "Base.C", 0.1, 3, 3)
    local player = makePlayer({ item })
    local sent = doMove(player, { itemId = "c1", ref = { type = "player" }, clear = true })
    local md = item:getModData()
    H.ok(md.gridX == nil and md.gridY == nil, "clear -> modData limpo [(" .. tostring(md.gridX) .. "," .. tostring(md.gridY) .. ")]")
end

-- ─── Teste 12: REQ_OVERRIDES — não-admin é ignorado (fail-closed) ───────────
do
    GridDevTool.Overrides = {}
    local player = makePlayer({})
    local replaced = false
    GridDevTool.replaceOverrides = function(self, ov) replaced = true; self.Overrides = ov end
    onClientCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.REQ_OVERRIDES, player, { overrides = { x = 1 } })
    H.ok(replaced == false, "não-admin NÃO altera overrides (fail-closed)")
end

-- ─── Teste 13: REQ_OVERRIDES — admin altera ─────────────────────────────────
do
    GridDevTool.Overrides = {}
    local player = makePlayer({})
    player.getAccessLevel = function() return "admin" end
    local replaced = false
    GridDevTool.replaceOverrides = function(self, ov) replaced = true; self.Overrides = ov end
    onClientCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.REQ_OVERRIDES, player, { overrides = { x = 1 } })
    H.ok(replaced == true, "admin altera overrides")
end

-- ─── Teste 14: CLEAR_HAND — tira o item da mão no servidor ─────────────────
do
    local heldItem = makeItem("h1", "Base.H", 0.5, nil, nil)
    local player = makePlayer({ heldItem })
    player.getPrimaryHandItem = function() return heldItem end
    local removed = false
    player.removeFromHands = function(self, it) removed = (it == heldItem) end

    onClientCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.CLEAR_HAND, player, { itemId = "h1" })
    H.ok(removed, "CLEAR_HAND removeu o item da mão do servidor")
end

-- ─── Teste 15: CLEAR_HAND — item que não está na mão → nada ────────────────
do
    local player = makePlayer({})
    local removed = false
    player.removeFromHands = function() removed = true end

    onClientCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.CLEAR_HAND, player, { itemId = "nao_ta_ai" })
    H.ok(removed == false, "CLEAR_HAND sem item na mão -> no-op")
end

-- ─── Teste 16: cliente SYNC_ITEM — eco do PRÓPRIO envio É aplicado ─────────
-- (fix do "loot não atualiza no render": o OnServerCommand não ignora o sender)
do
    local md = { gridX = nil, gridY = nil }
    local item = {
        getID = function() return "x1" end,
        getModData = function() return md end,
        getContainer = function() return nil end,
    }
    local ogFind = GridClientNetwork.findItem
    GridClientNetwork.findItem = function() return item end

    _G.isClient = function() return true end
    _G.getPlayer = function() return { getUsername = function() return "tester" end, getPlayerNum = function() return 0 end } end

    -- SYNC_ITEM com sender == próprio jogador (eco) — o handler NÃO pode ignorar
    onServerCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.SYNC_ITEM, {
        itemId = "x1", x = 4, y = 2, rotated = false, sender = "tester",
    })
    H.ok(md.gridX == 4 and md.gridY == 2,
        "eco do próprio envio é aplicado (4,2) [(" .. tostring(md.gridX) .. "," .. tostring(md.gridY) .. ")]")

    -- ERROR reverte a posição
    onServerCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.ERROR, { itemId = "x1" })
    H.ok(md.gridX == nil and md.gridY == nil, "ERROR reverte a posição")

    GridClientNetwork.findItem = ogFind
    _G.isClient = nil
    _G.getPlayer = nil
end

-- ─── Teste 17: compatibilidade do formato ANTIGO do GridOverrides.ini ───────
-- Formato antigo guardava cols/rows no fullType PURO ("Base.X"). O formato novo
-- usa "item:Base.X" pro grid. Se a chave prefixada EXISTE mas só com w/h (sem
-- cols/rows), o fallback pro "Base.X" precisa MESMO ASSIM rodar (antes ficava
-- bloqueado e o grid calibrado era ignorado — bug que quebrou jogadores com
-- arquivo antigo).
do
    -- Limpa e injeta os dois formatos misturados (caso real do jogador).
    GridDevTool.Overrides = {
        ["Base.ToolRoll_Leather"] = { w = 2, h = 1, cols = 6, rows = 2, maxStack = 1000 },
        -- chave prefixada EXISTE mas sem cols/rows (legado intermediário):
        ["item:Base.ToolRoll_Leather"] = { w = 1, h = 1, maxStack = 1000 },
    }

    -- Container de item (bolsa) cujo item é o ToolRoll_Leather.
    local bagItem = { getFullType = function() return "Base.ToolRoll_Leather" end }
    local bagInv = {
        getContainingItem = function() return bagItem end,
        getParent = function() return nil end,
        getType = function() return "Bag" end,
        getCapacity = function() return 12 end,
    }

    local w, h = GridContainer.getGridSize(bagInv)
    H.ok(w == 6 and h == 2,
        "grid legado: chave prefixada sem cols/rows NÃO bloqueia fallback do Base.X (6x2) [("
        .. tostring(w) .. "x" .. tostring(h) .. ")]")

    -- Formato novo puro (só prefixada com cols/rows) continua ganhando.
    GridDevTool.Overrides = {
        ["item:Base.ToolRoll_Leather"] = { cols = 8, rows = 3 },
    }
    w, h = GridContainer.getGridSize(bagInv)
    H.ok(w == 8 and h == 3,
        "grid formato novo: chave prefixada com cols/rows prevalece (8x3) [("
        .. tostring(w) .. "x" .. tostring(h) .. ")]")

    GridDevTool.Overrides = {}
end

-- ─── Teste 18: DEBOUNCE do SYNC_ITEM no cliente ─────────────────────────────
-- OTIMIZAÇÃO: N mensagens no MESMO instante (consolidação de pilha, vários
-- jogadores looteando o mesmo container) acumulam num lote e fazem UM
-- refresh() por janela de 50ms — antes era 1 remap O(n*W*H) POR mensagem.
-- A persistência (modData) continua IMEDIATA: só o re-layout é adiado.
do
    local clock = 0
    _G.getTimestampMs = function() return clock end
    _G.isClient = function() return true end
    _G.getPlayer = function() return { getPlayerNum = function() return 0 end } end
    _G.getPlayerInventory = function() return nil end
    _G.getPlayerLoot = function() return nil end
    _G.getPlayerHotbar = function() return nil end
    _G.getSpecificPlayer = function() return nil end

    local container = makeContainer({}, 12, "Bag")
    local refreshCount = 0
    local ogRefresh = GridContainer.refresh
    GridContainer.refresh = function(self, ...)
        refreshCount = refreshCount + 1
        return ogRefresh(self, ...)
    end

    local md = { gridX = nil, gridY = nil }
    local ogFind = GridClientNetwork.findItem
    GridClientNetwork.findItem = function()
        return { getModData = function() return md end, getContainer = function() return container end }
    end

    -- 3 SYNC_ITEMs no MESMO instante (clock parado)
    for i = 1, 3 do
        onServerCommand(GridProtocol.MODULE, GridProtocol.COMMANDS.SYNC_ITEM, {
            itemId = "d" .. i, x = i, y = 1, rotated = false,
        })
    end
    H.ok(refreshCount == 0, "3 SYNC_ITEMs no instante -> 0 refresh (debounce) [n=" .. refreshCount .. "]")
    H.ok(md.gridX == 3 and md.gridY == 1,
        "persistência IMEDIATA: modData aplicado sem esperar o flush [("
        .. tostring(md.gridX) .. "," .. tostring(md.gridY) .. ")]")

    -- Força o flush do lote -> UM refresh() só
    GridClientNetwork.flushPendingRefreshes()
    H.ok(refreshCount == 1, "lote de 3 mensagens -> 1 refresh() [n=" .. refreshCount .. "]")

    GridClientNetwork.findItem = ogFind
    GridContainer.refresh = ogRefresh
    _G.getTimestampMs = function() return 0 end
    _G.isClient = nil
    _G.getPlayer = nil
    _G.getPlayerInventory = nil
    _G.getPlayerLoot = nil
end

-- ─── Teste 19: markGridChanged — reorder no MESMO grid toca o pane ──────────
-- O reorder não muda o hash de itens (só modData) e em SP não tem eco do
-- servidor → NADA dispararia o refresh. O markGridChanged (chamado no
-- performGridReorder) deve rodar gc:refresh() e marcar gridRefreshDirty no
-- pane que renderiza o container (caminho do OverflowGridRender snapshot).
do
    local clock = 1000
    _G.getTimestampMs = function() return clock end
    _G.isClient = function() return true end
    _G.getPlayer = function() return { getPlayerNum = function() return 0 end } end

    local container = makeContainer({}, 12, "Bag")
    local refreshCount = 0
    local ogRefresh = GridContainer.refresh
    GridContainer.refresh = function(self, ...)
        refreshCount = refreshCount + 1
        return ogRefresh(self, ...)
    end

    local dirty = false
    local pane = {
        gridContainerUis = { { inventoryContainer = container } },
    }
    _G.getPlayerInventory = function()
        return { inventoryPane = pane }
    end
    _G.getPlayerLoot = function() return nil end

    GridClientNetwork.markGridChanged(container, 0)
    GridClientNetwork.flushPendingRefreshes()
    H.ok(refreshCount == 1, "markGridChanged -> 1 gc:refresh() [n=" .. refreshCount .. "]")
    H.ok(pane.gridRefreshDirty == true, "markGridChanged marcou o pane (gridRefreshDirty)")

    GridContainer.refresh = ogRefresh
    _G.getTimestampMs = function() return 0 end
    _G.isClient = nil
    _G.getPlayer = nil
    _G.getPlayerInventory = nil
    _G.getPlayerLoot = nil
end

-- ─── Teste 20: REORDER em lote (swap) — servidor rejeita sem o movedSet ────
-- O cliente valida o drag INTEIRO com movedSet (A→célula de B é ok: B vai sair).
-- Mas o servidor recebe UM REQUEST_MOVE por item e valida CADA um contra o
-- modData ATUAL (B ainda na posição antiga) → REJEITA o primeiro → ERROR →
-- clearItemPosition → item volta pra posição anterior. Reproduz o bug do MP.
do
    local a = makeItem("a", "Base.ReorderSwapA", 0.1, 1, 1)
    local b = makeItem("b", "Base.ReorderSwapB", 0.1, 2, 1)
    local player = makePlayer({ a, b })

    -- O que o cliente envia ao reorderar A→(2,1) e B→(1,1) (swap):
    -- dois REQUEST_MOVEs separados (performGridReorder envia um por item).
    local sent1 = doMove(player, { itemId = "a", ref = { type = "player" }, x = 2, y = 1, rotated = false })
    local sent2 = doMove(player, { itemId = "b", ref = { type = "player" }, x = 1, y = 1, rotated = false })

    local errA, errB = false, false
    for _, s in ipairs(sent1) do
        if s.cmd == GridProtocol.COMMANDS.ERROR then errA = true end
    end
    for _, s in ipairs(sent2) do
        if s.cmd == GridProtocol.COMMANDS.ERROR then errB = true end
    end
    H.ok(errA and errB,
        "REPRO: swap de 2 itens -> servidor rejeita os 2 (ERROR) [errA=" .. tostring(errA) .. ", errB=" .. tostring(errB) .. "]")
end

-- ─── Teste 21: REQUEST_REORDER em lote — swap aplicado all-or-nothing ───────
-- O fix do bug: o cliente envia TODOS os alvos num comando. O servidor valida o
-- lote junto (movedSet = itens do lote ignoram as posições antigas) e aplica
-- tudo. Swap A↔B: A→(2,1) era inválido isoladamente (B ainda lá) mas no lote
-- é válido porque B vai sair.
do
    local a = makeItem("a", "Base.ReorderSwapA", 0.1, 1, 1)
    local b = makeItem("b", "Base.ReorderSwapB", 0.1, 2, 1)
    local player = makePlayer({ a, b })

    local sent = doReorder(player, {
        { itemId = "a", x = 2, y = 1, rotated = false },
        { itemId = "b", x = 1, y = 1, rotated = false },
    })

    local err, ok = false, 0
    for _, s in ipairs(sent) do
        if s.cmd == GridProtocol.COMMANDS.ERROR then err = true end
        if s.cmd == GridProtocol.COMMANDS.SYNC_ITEM then ok = ok + 1 end
    end
    H.ok(not err and ok == 2,
        "swap em lote -> aplicado (2 SYNC_ITEM, 0 ERROR) [err=" .. tostring(err) .. ", ok=" .. ok .. "]")
    H.ok(a:getModData().gridX == 2 and a:getModData().gridY == 1,
        "lote: a aplicado em (2,1) [" .. tostring(a:getModData().gridX) .. "," .. tostring(a:getModData().gridY) .. "]")
    H.ok(b:getModData().gridX == 1 and b:getModData().gridY == 1,
        "lote: b aplicado em (1,1) [" .. tostring(b:getModData().gridX) .. "," .. tostring(b:getModData().gridY) .. "]")
    H.ok(a:getModData().gridManual == true,
        "lote: gridManual true persistido [" .. tostring(a:getModData().gridManual) .. "]")
end

-- ─── Teste 22: REQUEST_REORDER em lote — colisão real rejeita TUDO ──────────
-- Se UM alvo do lote colide com um item que NÃO vai sair, o lote INTEIRO é
-- rejeitado (ERROR pra cada item) e NADA é gravado.
do
    local a = makeItem("a", "Base.ReorderSwapA", 0.1, 1, 1)
    local b = makeItem("b", "Base.ReorderSwapB", 0.1, 2, 1)
    local c = makeItem("c", "Base.ReorderSwapC", 0.1, 3, 1)
    local player = makePlayer({ a, b, c })

    -- Lote tenta: a→(3,1) colidindo com c (que NÃO sai) e b→(1,1) (ok isolado).
    local sent = doReorder(player, {
        { itemId = "a", x = 3, y = 1, rotated = false },
        { itemId = "b", x = 1, y = 1, rotated = false },
    })

    local errs, syncs = 0, 0
    for _, s in ipairs(sent) do
        if s.cmd == GridProtocol.COMMANDS.ERROR then errs = errs + 1 end
        if s.cmd == GridProtocol.COMMANDS.SYNC_ITEM then syncs = syncs + 1 end
    end
    H.ok(errs == 2 and syncs == 0,
        "lote com colisão real -> ERROR nos 2 itens, nada aplicado [errs=" .. errs .. ", syncs=" .. syncs .. "]")
    H.ok(a:getModData().gridX == 1 and b:getModData().gridX == 2,
        "lote rejeitado: posições originais preservadas [a=" .. tostring(a:getModData().gridX) .. ", b=" .. tostring(b:getModData().gridX) .. "]")
end

-- ─── Teste 23: REQUEST_REORDER em lote — item do lote ainda em trânsito ─────
-- Se algum item do lote não foi encontrado (transfer não terminou), o lote
-- INTEIRO entra na fila de pendências e é reenviado depois.
do
    local a = makeItem("a", "Base.ReorderSwapA", 0.1, 1, 1)
    local b = makeItem("b", "Base.ReorderSwapB", 0.1, 2, 1)
    local player = makePlayer({ a })

    local sent = doReorder(player, {
        { itemId = "a", x = 2, y = 1, rotated = false },
        { itemId = "b", x = 1, y = 1, rotated = false },
    })

    -- Nada foi aplicado nem rejeitado: "b" não existe (notfound → fila).
    local syncs, errs = 0, 0
    for _, s in ipairs(sent) do
        if s.cmd == GridProtocol.COMMANDS.ERROR then errs = errs + 1 end
        if s.cmd == GridProtocol.COMMANDS.SYNC_ITEM then syncs = syncs + 1 end
    end
    H.ok(syncs == 0 and errs == 0,
        "lote com item em trânsito -> nem SYNC nem ERROR (vai pra fila) [syncs=" .. syncs .. ", errs=" .. errs .. "]")
end

-- ─── Teste 24: cliente envia REQUEST_REORDER em lote (sendReorder) ──────────
-- O fix no cliente: em vez de N REQUEST_MOVE (um por item), o performGridReorder
-- envia UM comando de lote com todos os alvos (o servidor valida junto).
do
    local a = makeItem("a", "Base.ReorderSwapA", 0.1, 1, 1)
    local b = makeItem("b", "Base.ReorderSwapB", 0.1, 2, 1)
    local player = makePlayer({ a, b })
    local container = player:getInventory()

    local sentCmd = nil
    _G.isClient = function() return true end
    _G.getPlayer = function() return { getPlayerNum = function() return 0 end } end
    _G.sendClientCommand = function(player, module, cmd, args) sentCmd = { module = module, cmd = cmd, args = args } end

    local targets = {
        { item = { id = "a", rotated = false, itemObj = a }, tx = 2, ty = 1, ew = 1, eh = 1 },
        { item = { id = "b", rotated = false, itemObj = b }, tx = 1, ty = 1, ew = 1, eh = 1 },
    }
    GridClientNetwork.sendReorder(container, targets, "sig-test")

    H.ok(sentCmd and sentCmd.module == GridProtocol.MODULE
        and sentCmd.cmd == GridProtocol.COMMANDS.REQUEST_REORDER,
        "sendReorder envia REQUEST_REORDER no módulo certo ["
        .. tostring(sentCmd and sentCmd.cmd) .. "]")
    H.ok(sentCmd and sentCmd.args and #sentCmd.args.moves == 2,
        "lote contém os 2 alvos [" .. tostring(sentCmd and sentCmd.args and #sentCmd.args.moves) .. "]")
    H.ok(sentCmd and sentCmd.args.moves[1].itemId == "a"
        and sentCmd.args.moves[1].x == 2 and sentCmd.args.moves[1].y == 1,
        "alvo 1 = a→(2,1) [" .. tostring(sentCmd and sentCmd.args.moves[1].itemId) .. "]")
    H.ok(sentCmd and sentCmd.args.moves[2].itemId == "b"
        and sentCmd.args.moves[2].x == 1 and sentCmd.args.moves[2].y == 1,
        "alvo 2 = b→(1,1) [" .. tostring(sentCmd and sentCmd.args.moves[2].itemId) .. "]")
    H.ok(sentCmd and sentCmd.args.manual == true and sentCmd.args.gridContainer == "sig-test",
        "lote carrega manual=true e assinatura do container")

    _G.isClient = nil
    _G.getPlayer = nil
    _G.sendClientCommand = nil
end

-- ─── Teste 25: buildContainerRef/resolveContainerRef de VEÍCULO ─────────────
-- O container de um veículo (porta-malas, luva, bancos) é de uma PARTE
-- (VehiclePart). O vanilla (ISTransferAction) resolve com:
--   container:getParent() é o BaseVehicle; container:getType() é o id da parte;
--   vehicle:getPartById(containerType):getItemContainer().
do
    -- mock do instanceof: reconhece BaseVehicle (além de IsoPlayer)
    local origInstanceof = _G.instanceof
    _G.instanceof = function(a, b)
        if a and a._isVehicle then return b == "BaseVehicle" end
        if a and a._isPlayer then return b == "IsoPlayer" end
        return false
    end

    -- parte com container (ex.: luva); o container É o getItemContainer da parte
    local gloveInv = makeContainer({}, 5, "GloveBox")
    local part = {
        getId = function() return "GloveBox" end,
        getItemContainer = function() return gloveInv end,
    }

    -- veículo
    local vehicle = {
        _isVehicle = true,
        getId = function() return 999 end,
        getPartById = function(_, id)
            if id == "GloveBox" then return part end
            return nil
        end,
    }

    -- o container de veículo no jogo é o próprio itemContainer da parte, e o
    -- getParent() dele é o BaseVehicle
    gloveInv.getParent = function() return vehicle end

    -- buildContainerRef deve produzir vehicleId + containerType
    local ref = GridProtocol.buildContainerRef(gloveInv)
    H.ok(ref and ref.type == "vehicle" and ref.vehicleId == 999 and ref.containerType == "GloveBox",
        "buildContainerRef veículo -> type/vehicleId/containerType ["
        .. tostring(ref and ref.type) .. "/" .. tostring(ref and ref.vehicleId) .. "/"
        .. tostring(ref and ref.containerType) .. "]")

    -- resolveContainerRef deve retornar o itemContainer da parte via getPartById
    _G.getVehicleById = function(id) if id == 999 then return vehicle end return nil end
    _G.getVehicleByKeyId = function() return nil end
    _G.getCell = function() return nil end
    local resolved = GridProtocol.resolveContainerRef(ref, nil)
    H.ok(resolved == gloveInv,
        "resolveContainerRef veículo -> getPartById(getType()):getItemContainer() ["
        .. tostring(resolved == gloveInv) .. "]")

    _G.getVehicleById = nil
    _G.getVehicleByKeyId = nil
    _G.instanceof = origInstanceof
end

-- ─── Teste 26: buildContainerRef/resolveContainerRef de BOLSA ───────────────
-- Uma bolsa pode estar: no inventário do jogador, no chão, em um armário ou em
-- outra bolsa. O ref da bolsa (type="item") carrega o containerRef do PAI
-- (ref.parent) pra o servidor resolver ONDE a bolsa está e achá-la por itemId.
do
    local origInstanceof = _G.instanceof
    _G.instanceof = function(a, b)
        if a and a._isPlayer then return b == "IsoPlayer" end
        if a and a._isObject then return b == "IsoObject" end
        return false
    end

    -- bolsa com inventário próprio (getInventory) e que vive num container pai
    local bagItem = {
        getID = function() return 500 end,
        getInventory = function() return nil end, -- setado abaixo
        getContainer = function() return nil end, -- setado por cenário
    }
    local bagInv = makeContainer({}, 5, "Bag")
    bagInv.getContainingItem = function() return bagItem end
    bagItem.getInventory = function() return bagInv end

    -- cenário 1: bolsa no inventário do JOGADOR (pai = player)
    do
        local player = makePlayer({ bagItem })
        bagItem.getContainer = function() return player:getInventory() end
        local ref = GridProtocol.buildContainerRef(bagInv)
        H.ok(ref and ref.type == "item" and ref.parent and ref.parent.type == "player",
            "buildContainerRef bolsa no inventário -> parent player ["
            .. tostring(ref and ref.type) .. "/" .. tostring(ref and ref.parent and ref.parent.type) .. "]")
        local resolved = GridProtocol.resolveContainerRef(ref, player)
        H.ok(resolved == bagInv,
            "resolveContainerRef bolsa no inventário -> getInventory() da bolsa ["
            .. tostring(resolved == bagInv) .. "]")
    end

    -- cenário 2: bolsa dentro de um ARMÁRIO (pai = object no mundo)
    do
        -- armário: um IsoObject com getContainer() no square
        local crateInv = makeContainer({ bagItem }, 20, "Crate")
        local crateObj = {
            _isObject = true,
            getContainer = function() return crateInv end,
            getSquare = function() return nil end, -- setado abaixo
        }
        crateInv.getParent = function() return crateObj end
        local square = {
            getObjects = function()
                return { size = function() return 1 end, get = function(_, i) return crateObj end }
            end,
            getX = function() return 10 end, getY = function() return 20 end, getZ = function() return 0 end,
        }
        crateObj.getSquare = function() return square end
        bagItem.getContainer = function() return crateInv end

        _G.getCell = function() return { getGridSquare = function(self, x, y, z)
            if x == 10 and y == 20 and z == 0 then return square end return nil end } end

        local ref = GridProtocol.buildContainerRef(bagInv)
        H.ok(ref and ref.type == "item" and ref.parent and ref.parent.type == "object"
            and ref.parent.x == 10,
            "buildContainerRef bolsa em armário -> parent object ["
            .. tostring(ref and ref.parent and ref.parent.type) .. "]")

        local resolved = GridProtocol.resolveContainerRef(ref, nil)
        H.ok(resolved == bagInv,
            "resolveContainerRef bolsa em armário -> getInventory() da bolsa ["
            .. tostring(resolved == bagInv) .. "]")

        _G.getCell = function() return { getGridSquare = function() return nil end } end
    end

    -- cenário 3: bolsa dentro de OUTRA bolsa (pai = item)
    do
        local outerItem = {
            getID = function() return 600 end,
            getInventory = function() return nil end, -- setado abaixo
            getContainer = function() return nil end,
        }
        local outerInv = makeContainer({ bagItem }, 20, "BigBag")
        outerInv.getContainingItem = function() return outerItem end
        outerItem.getInventory = function() return outerInv end
        local player = makePlayer({ outerItem })
        bagItem.getContainer = function() return outerInv end
        outerItem.getContainer = function() return player:getInventory() end

        local ref = GridProtocol.buildContainerRef(bagInv)
        H.ok(ref and ref.type == "item" and ref.parent and ref.parent.type == "item"
            and ref.parent.parent and ref.parent.parent.type == "player",
            "buildContainerRef bolsa em bolsa -> parent aninhado ["
            .. tostring(ref and ref.parent and ref.parent.type) .. "/"
            .. tostring(ref and ref.parent and ref.parent.parent and ref.parent.parent.type) .. "]")
        local resolved = GridProtocol.resolveContainerRef(ref, player)
        H.ok(resolved == bagInv,
            "resolveContainerRef bolsa em bolsa -> getInventory() da bolsa ["
            .. tostring(resolved == bagInv) .. "]")
    end

    _G.instanceof = origInstanceof
end

-- ─── Teste 27: buildOccupancy ignora itens EQUIPADOS (não barram reorder) ──
-- O cliente não mostra itens equipados no grid do inventário; o servidor precisa
-- do mesmo filtro na ocupação autoritativa — senão um item pego e depois equipado
-- continua barrando a célula na validação de reorder/placement.
do
    -- item equipado com posição salva (1,1)
    local equipped = makeItem("eq", "Base.Shirt", 0.1, 1, 1, false, { equipped = true })
    -- item normal com posição salva (2,1)
    local normal = makeItem("n1", "Base.Can", 0.1, 2, 1)
    local container = makeContainer({ equipped, normal }, 6, "crate")

    local grid = require("DataModel/GridCore").new(6, 6)
    GridContainer.buildOccupancy(container, grid)

    H.ok(grid.items["eq"] == nil,
        "buildOccupancy NÃO insere item equipado na ocupação ["
        .. tostring(grid.items["eq"] ~= nil) .. "]")
    H.ok(grid.items["n1"] ~= nil,
        "buildOccupancy insere item normal na ocupação ["
        .. tostring(grid.items["n1"] ~= nil) .. "]")

    -- a célula (1,1) do item equipado deve estar LIVRE pra um novo placement
    local cell = grid.cells[1] and grid.cells[1][1]
    H.ok(cell == nil,
        "célula do item equipado fica livre na ocupação [cell=" .. tostring(cell) .. "]")
end

-- ─── Teste 28: buildOccupancy ignora itens ANEXADOS/HOTBAR (cinto/costas) ──
-- Itens na hotbar (getAttachedSlot() ~= -1) não são isEquipped(), mas também
-- não devem ocupar espaço no grid do inventário — senão viram "espaço fantasma"
-- que barra reorder no servidor.
do
    -- item anexado (hotbar/cinto/costas) com posição salva (1,1)
    local attached = makeItem("at", "Base.Knife", 0.1, 1, 1, false, { attachedSlot = 2 })
    -- item normal com posição salva (2,1)
    local normal = makeItem("n2", "Base.Can", 0.1, 2, 1)
    local container = makeContainer({ attached, normal }, 6, "crate")

    local grid = require("DataModel/GridCore").new(6, 6)
    GridContainer.buildOccupancy(container, grid)

    H.ok(grid.items["at"] == nil,
        "buildOccupancy NÃO insere item anexado/hotbar na ocupação ["
        .. tostring(grid.items["at"] ~= nil) .. "]")
    H.ok(grid.items["n2"] ~= nil,
        "buildOccupancy insere item normal na ocupação (com anexado) ["
        .. tostring(grid.items["n2"] ~= nil) .. "]")
    local cell = grid.cells[1] and grid.cells[1][1]
    H.ok(cell == nil,
        "célula do item anexado fica livre na ocupação [cell=" .. tostring(cell) .. "]")
end

-- ─── Teste 29: REQUEST_MOVE com sourceRef — servidor acha item na ORIGEM ────
-- Quando o item ainda está na origem em trânsito (transferência não completou),
-- ele não está nem no inventário do jogador nem no container de DESTINO (ref).
-- O sourceRef (origem) permite ao servidor encontrá-lo e aplicar a posição de
-- imediato — sem isso ia pra fila de pendências e o item chegava ao destino sem
-- posição (auto-fit em 1,1, deslocando o item existente).
do
    -- armário (origem) contendo o item alvo
    local item = makeItem("srcItem", "Base.Can", 0.1, 1, 1)
    local crateInv = makeContainer({ item }, 20, "Crate")
    local crateObj = {
        _isObject = true,
        getContainer = function() return crateInv end,
        getSquare = function() return nil end,
    }
    crateInv.getParent = function() return crateObj end
    item.getContainer = function() return crateInv end
    local square = {
        getObjects = function() return { size = function() return 1 end, get = function() return crateObj end } end,
        getX = function() return 5 end, getY = function() return 6 end, getZ = function() return 0 end,
    }
    crateObj.getSquare = function() return square end

    local player = makePlayer({}) -- inventário vazio (item NÃO está nele)

    -- sourceRef = object que resolve o armário (origem)
    local sourceRef = { type = "object", x = 5, y = 6, z = 0, objIndex = 0 }

    _G.getCell = function() return { getGridSquare = function(self, x, y, z)
        if x == 5 and y == 6 and z == 0 then return square end return nil end } end
    _G.instanceof = function(a, b)
        if a and a._isObject then return b == "IsoObject" end
        if a and a._isPlayer then return b == "IsoPlayer" end
        return false
    end

    local sent = doMove(player, {
        itemId = "srcItem",
        ref = { type = "player" },      -- destino = inventário do jogador
        sourceRef = sourceRef,          -- origem = armário
        x = 2, y = 1, rotated = false,
        gridContainer = "sig-player",
        manual = true,
    })

    local sync = false
    for _, s in ipairs(sent) do
        if s.cmd == GridProtocol.COMMANDS.SYNC_ITEM then sync = true end
    end
    H.ok(sync,
        "REQUEST_MOVE com sourceRef acha item na origem e aplica (SYNC_ITEM) ["
        .. tostring(sync) .. "]")
    H.ok(item:getModData().gridX == 2 and item:getModData().gridY == 1,
        "posição (2,1) gravada no item encontrado via sourceRef ["
        .. tostring(item:getModData().gridX) .. "," .. tostring(item:getModData().gridY) .. "]")

    _G.getCell = function() return { getGridSquare = function() return nil end } end
    _G.instanceof = function(a, b) return (a and a._isPlayer) and b == "IsoPlayer" or false end
end

H.finish()
