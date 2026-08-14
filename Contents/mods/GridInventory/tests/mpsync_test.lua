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

H.finish()
