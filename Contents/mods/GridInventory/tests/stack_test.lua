-- stack_test.lua — STACKING no GridCore.
-- Regra: compatKey igual + mesmo retângulo (x/y/w/h/rotated) = pilha.
-- Cobre: empilhar, remover membro, promover líder, bloqueio de não-empilháveis,
-- findFreeSpace com/sem compatKey, rotação, ghost compatível, limite de unidades.

local H = require("harness")
H.setName("stack_test")

local GridCore = require("DataModel/GridCore")
getTimeInMillis = function() return 0 end

local AMMO = "stack:Base.Bullets9mm"
local AMMO2 = "stack:Base.ShotgunShells"  -- compatível consigo mesmo, incompatível com AMMO

local g = GridCore.new(6, 6)

-- ─── Teste 1: colocar 3 munições compatíveis na MESMA célula (pilha) ─────────
do
    H.ok(g:insertItem("b1", 1, 1, 1, 1, false, nil, AMMO), "b1 colocado")
    H.ok(g:insertItem("b2", 1, 1, 1, 1, false, nil, AMMO), "b2 empilha sobre b1")
    H.ok(g:insertItem("b3", 1, 1, 1, 1, false, nil, AMMO), "b3 empilha sobre b1")
    H.ok(g:getStackSize("b1") == 3, "pilha b1 tem 3 [size=" .. g:getStackSize("b1") .. "]")
    H.ok(g.cells[1][1] == "b1", "célula (1,1) aponta pro líder b1")
    H.ok(g:getStackMembers("b1")[2] ~= nil, "getStackMembers retorna membros")
    -- Célula deve "caber" de novo (compatível)
    H.ok(g:canPlaceItem("b4", 1, 1, 1, 1, nil, AMMO) == true, "cabe mais um compatível")
    H.ok(g:canPlaceItem("b5", 1, 1, 1, 1, nil, AMMO2) == false, "munição diferente NÃO cabe")
    -- Não-empilhável não cabe em cima da pilha
    H.ok(g:canPlaceItem("knife", 1, 1, 1, 1) == false, "item não-empilhável bloqueado pela pilha")
end

-- ─── Teste 2: remover um MEMBRO mantém o líder ────────────────────────────────
do
    H.ok(g:removeItem("b2") == true, "b2 (membro) removido")
    H.ok(g:getStackSize("b1") == 2, "pilha b1 agora tem 2")
    H.ok(g.cells[1][1] == "b1", "célula continua apontando pro líder")
    H.ok(g.items["b2"] == nil, "b2 saiu do registro de itens")
end

-- ─── Teste 3: remover o LÍDER promove um membro ───────────────────────────────
do
    H.ok(g:removeItem("b1") == true, "líder b1 removido")
    local remaining = nil
    for id in pairs(g.items) do remaining = id end
    H.ok(remaining ~= nil, "sobrou um item na pilha")
    if remaining then
        H.ok(g.items[remaining].stackMemberOf == nil, "promovido virou líder (stackMemberOf nil)")
        H.ok(g.cells[1][1] == remaining, "célula agora aponta pro novo líder")
        H.ok(g:getStackSize(remaining) == 1, "pilha de 1 item")
    end
    g.items = {}
    g.cells = {}
    for x = 1, 6 do g.cells[x] = {} end
    g.stacks = {}
end

-- ─── Teste 4: não-empilháveis bloqueiam pilha ─────────────────────────────────
do
    g:insertItem("knife", 2, 2, 1, 1)
    H.ok(g:canPlaceItem("ammoX", 2, 2, 1, 1, nil, AMMO) == false, "célula ocupada por item normal bloqueia ammo")
    H.ok(g:insertItem("ammoX", 2, 3, 1, 1, false, nil, AMMO), "ammo pode ir numa célula livre")
end

-- ─── Teste 5: findFreeSpace com compatKey acha a pilha compatível ────────────
do
    g.items = {}
    g.cells = {}
    for x = 1, 6 do g.cells[x] = {} end
    g.stacks = {}
    g:insertItem("ammoX", 1, 1, 1, 1, false, nil, AMMO)
    local fx, fy = g:findFreeSpace("ammoY", 1, 1, AMMO)
    H.ok(fx == 1 and fy == 1, "findFreeSpace com compatKey acha a pilha (1,1) [" .. tostring(fx) .. "," .. tostring(fy) .. "]")
    g:insertItem("ammoY", fx, fy, 1, 1, false, nil, AMMO)
    H.ok(g:getStackSize("ammoX") == 2, "ammoY empilhou em ammoX")
end

-- ─── Teste 6: findFreeSpace SEM compatKey NÃO entra na pilha ──────────────────
do
    local fx, fy = g:findFreeSpace("other", 1, 1)
    H.ok(not (fx == 1 and fy == 1), "sem compatKey, findFreeSpace ignora a pilha de ammo [(" .. tostring(fx) .. "," .. tostring(fy) .. ")]")
end

-- ─── Teste 7: rotacionado — pilha exige mesmo retângulo ───────────────────────
do
    g:insertItem("long1", 4, 1, 2, 1, false, nil, "stack:X")
    -- mesmo retângulo mas rotacionado (1x2) → NÃO empilha sobre (2x1)
    H.ok(g:canPlaceItem("long2", 4, 1, 2, 1, nil, "stack:X", true) == false,
        "retângulo igual mas rotação diferente não empilha")
    -- retângulo igual e mesma rotação → empilha
    H.ok(g:canPlaceItem("long2", 4, 1, 2, 1, nil, "stack:X", false) == true,
        "retângulo+rotação iguais empilham")
end

-- ─── Teste 8: ghost de pilha compatível não bloqueia ──────────────────────────
do
    g:addGhostItem("ghostAmmo", nil, 1, 5, 1, 1, false, AMMO)
    H.ok(g:canPlaceItem("realAmmo", 1, 5, 1, 1, nil, AMMO) == true, "ghost compatível não bloqueia pilha")
    H.ok(g:canPlaceItem("realOther", 1, 5, 1, 1, nil, AMMO2) == false, "ghost incompatível bloqueia")
end

-- ─── Teste 9: limite de UNIDADES da pilha (maxStack) ─────────────────────────
do
    local g2 = GridCore.new(6, 6)
    local si = { limit = 50, units = 5 }  -- 50 unidades máx, 5 por item → 10 itens
    H.ok(g2:insertItem("m1", 1, 1, 1, 1, false, nil, "stack:M", si), "m1 no topo")
    for i = 2, 10 do
        H.ok(g2:insertItem("m" .. i, 1, 1, 1, 1, false, nil, "stack:M", si), "m" .. i .. " empilha")
    end
    H.ok(g2:getStackSize("m1") == 10, "10 itens na pilha [size=" .. g2:getStackSize("m1") .. "]")
    H.ok(g2:getPileUnits("m1") == 50, "50 unidades na pilha [units=" .. g2:getPileUnits("m1") .. "]")
    -- 11º item (5 unidades) ultrapassaria 55 > 50 → NÃO empilha
    H.ok(g2:canPlaceItem("m11", 1, 1, 1, 1, nil, "stack:M", false, si) == false,
        "pilha cheia (50/50) bloqueia novo membro")
    H.ok(g2:insertItem("m11", 1, 1, 1, 1, false, nil, "stack:M", si) == false,
        "insertItem respeita o limite")
    -- findFreeSpace com compatKey NÃO aponta pra pilha cheia
    local fx, fy = g2:findFreeSpace("m12", 1, 1, "stack:M", si)
    H.ok(not (fx == 1 and fy == 1), "findFreeSpace não retorna pilha cheia [(" .. tostring(fx) .. "," .. tostring(fy) .. ")]")
    -- findCompatibleStack respeita o limite
    local cx = g2:findCompatibleStack("m13", 1, 1, "stack:M", si)
    H.ok(cx == nil, "findCompatibleStack não acha pilha cheia")
    -- sem stackInfo → sem limite (pilha infinita)
    H.ok(g2:canPlaceItem("m99", 1, 1, 1, 1, nil, "stack:M", false) == true, "sem limite = pilha infinita")
end

-- ─── Teste 10: stackable "em pé" (1x2 rotacionado) — sem célula livre, mas ──
-- pilha compatível do MESMO retângulo existe → findFreeSpace acha (fix do
-- duplo clique não-1x1)
do
    local g2 = GridCore.new(4, 4)
    local si = { limit = 100, units = 5 }
    -- pilha ROTACIONADA 1x2 em (1,1)
    g2:insertItem("p1", 1, 1, 1, 2, true, nil, "stack:L", si)
    g2:insertItem("p2", 1, 1, 1, 2, true, nil, "stack:L", si)
    -- ocupa o resto pra não sobrar célula livre 2x1 nem 1x2
    for x = 1, 4 do
        for y = 1, 4 do
            if not (x == 1 and y == 1) then
                g2:insertItem("o" .. x .. "_" .. y, x, y, 1, 1, false, nil, nil)
            end
        end
    end

    -- SEM compatKey (bug antigo): não acha nada → "Out of Space"
    local fx0, fy0 = g2:findFreeSpace("new", 2, 1)
    H.ok(fx0 == nil, "sem compatKey não acha espaço (grid cheio)")

    -- COM compatKey (fix): o item rotacionado (1x2) acha a pilha em (1,1)
    local fx, fy = g2:findFreeSpace("new", 1, 2, "stack:L", si, true)
    H.ok(fx == 1 and fy == 1, "rotacionado (1x2) acha a pilha em (1,1) [" .. tostring(fx) .. "," .. tostring(fy) .. "]")
    H.ok(g2:canPlaceItem("new", fx, fy, 1, 2, nil, "stack:L", true, si) == true, "cabe na pilha em pé")
    H.ok(g2:insertItem("new", fx, fy, 1, 2, true, nil, "stack:L", si) == true, "insere na pilha em pé")
    H.ok(g2:getStackSize("p1") == 3, "pilha agora tem 3 [size=" .. g2:getStackSize("p1") .. "]")
end

-- ─── Teste 11: mover PILHA INTEIRA com SOBREPOSIÇÃO na origem ───────────────
-- Arrastar uma pilha de 1x2 de (2,1) pra (2,2) sobrepõe a origem (membro ainda
-- lá) — o ignoreSet (itens em movimento) não pode deixar o alvo colidir com o
-- próprio membro (bug do "phantom block" ao mover stack 2ª vez).
do
    local g = GridCore.new(6, 6)
    local si = { limit = 100, units = 5 }
    g:insertItem("a", 2, 1, 1, 2, false, nil, "stack:L", si)
    g:insertItem("b", 2, 1, 1, 2, false, nil, "stack:L", si)

    local itemsData = {
        { id = "a", originalW = 1, originalH = 2, grabOffsetX = 0, grabOffsetY = 0, rotated = false, compatKey = "stack:L", stackInfo = si },
        { id = "b", originalW = 1, originalH = 2, grabOffsetX = 0, grabOffsetY = 0, rotated = false, compatKey = "stack:L", stackInfo = si },
    }
    local movedSet = {}
    for _, d in ipairs(itemsData) do movedSet[d.id] = true end

    local allCanPlace = true
    local targets = {}
    for _, d in ipairs(itemsData) do
        -- drop em (2,2): sobrepõe a origem (2,1)-(2,2)
        if not g:canPlaceItem(d.id, 2, 2, d.originalW, d.originalH, d.id, d.compatKey, d.rotated, d.stackInfo, movedSet) then
            allCanPlace = false
            break
        end
        table.insert(targets, d)
    end
    H.ok(allCanPlace, "pilha inteira pode sobrepor a própria origem (phantom block fix)")

    for _, d in ipairs(targets) do
        H.ok(g:insertItem(d.id, 2, 2, d.originalW, d.originalH, d.rotated, nil, d.compatKey, d.stackInfo, movedSet), "insert " .. d.id)
    end
    H.ok(g:getStackSize("a") == 2, "pilha continua com 2 no novo spot [size=" .. g:getStackSize("a") .. "]")
    H.ok(g.cells[2][2] == "a" or g.cells[2][2] == "b", "célula (2,2) tem a pilha")

    -- ignoreSet NÃO pode liberar um item que NÃO está em movimento
    g:insertItem("block", 4, 1, 1, 1)
    local okBlock = g:canPlaceItem("x", 4, 1, 1, 1, "x", nil, false, nil, { ["y"] = true })
    H.ok(okBlock == false, "item fora do ignoreSet continua bloqueando")
end

-- ─── Teste 12: pilha com 3+ itens move INTACTA (promoção de líder) ──────────
-- O removeItem promovia um novo líder mas NÃO atualizava o stackMemberOf dos
-- membros restantes (ficavam apontando pro líder antigo) — pilha com 3+ quebrava
-- ao mover (membros órfãos, itens sobrepostos, count sumindo).
do
    local g = GridCore.new(6, 6)
    local si = { limit = 100, units = 1 }
    g:insertItem("a", 2, 1, 1, 2, false, nil, "stack:L", si)
    g:insertItem("b", 2, 1, 1, 2, false, nil, "stack:L", si)
    g:insertItem("c", 2, 1, 1, 2, false, nil, "stack:L", si)
    g:insertItem("d", 2, 1, 1, 2, false, nil, "stack:L", si)

    -- remove o líder (promove) e confere que os membros restantes apontam pro
    -- NOVO líder (sem referência órfã pro líder removido)
    g:removeItem("a")
    local leader = nil
    for id, d in pairs(g.items) do
        if not d.stackMemberOf then leader = id end
    end
    H.ok(leader ~= nil, "removeItem promove um novo líder")
    if leader then
        local orphans = 0
        for id, d in pairs(g.items) do
            if d.stackMemberOf == "a" then orphans = orphans + 1 end
        end
        H.ok(orphans == 0, "nenhum membro aponta pro líder removido (a) [orphans=" .. orphans .. "]")
        H.ok(g:getStackSize(leader) == 3, "pilha promovida tem 3 [size=" .. g:getStackSize(leader) .. "]")
    end

    -- re-monta pilha de 4 e move inteira com ignoreSet (drop no mesmo grid)
    local g2 = GridCore.new(6, 6)
    g2:insertItem("a", 2, 1, 1, 2, false, nil, "stack:L", si)
    g2:insertItem("b", 2, 1, 1, 2, false, nil, "stack:L", si)
    g2:insertItem("c", 2, 1, 1, 2, false, nil, "stack:L", si)
    g2:insertItem("d", 2, 1, 1, 2, false, nil, "stack:L", si)
    local movedSet = { a = true, b = true, c = true, d = true }
    for _, id in ipairs({ "a", "b", "c", "d" }) do
        H.ok(g2:insertItem(id, 4, 1, 1, 2, false, nil, "stack:L", si, movedSet), "move " .. id .. " (pilha inteira)")
    end
    H.ok(g2:getStackSize("a") == 4, "pilha de 4 moveu inteira [size=" .. g2:getStackSize("a") .. "]")
    local allAtTarget = true
    for id, d in pairs(g2.items) do
        if d.x ~= 4 or d.y ~= 1 then allAtTarget = false end
    end
    H.ok(allAtTarget, "todos os 4 membros no novo spot (4,1)")
end

-- ─── Teste 13: mover pilha inteira — REMOVE-ALL-FIRST em qualquer ordem ─────
-- O drop do mesmo grid remove TODOS os membros antes de reinserir. Com a ordem
-- arbitrária do pairs (membro antes do líder), a sobreposição quebrava pilhas
-- com 3+ (promoção da origem sobrescrevia células do alvo). Testa todas as
-- permutações da ordem de inserção.
do
    local function movePileOrder(ids, n)
        local g = GridCore.new(6, 6)
        local si = { limit = 100, units = 1 }
        g:insertItem("a", 2, 1, 1, 2, false, nil, "stack:L", si)
        for i = 2, n do
            local id = string.char(string.byte("a") + i - 1)
            g:insertItem(id, 2, 1, 1, 2, false, nil, "stack:L", si)
        end
        local movedSet = {}
        for _, id in ipairs(ids) do movedSet[id] = true end
        -- remove-all-first (como o drop)
        for _, id in ipairs(ids) do g:removeItem(id) end
        for _, id in ipairs(ids) do
            if not g:insertItem(id, 2, 2, 1, 2, false, nil, "stack:L", si, movedSet) then
                return false, "insert " .. id .. " falhou"
            end
        end
        local leader = nil
        for id, d in pairs(g.items) do
            if not d.stackMemberOf then leader = id end
        end
        if not leader then return false, "sem líder" end
        local size = g:getStackSize(leader)
        if size ~= n then return false, "size=" .. size .. " esperado " .. n end
        -- todos no mesmo spot
        for id, d in pairs(g.items) do
            if d.x ~= 2 or d.y ~= 2 then return false, id .. " fora do spot" end
        end
        return true, "ok"
    end

    local ids = { "a", "b", "c", "d" }
    -- todas as permutações de 4 itens
    local function perms(t, k)
        if k == #t then
            local ok, err = movePileOrder(t, 4)
            if not ok then return false, err, table.concat(t, ",") end
            return true, nil, nil
        end
        for i = k, #t do
            t[k], t[i] = t[i], t[k]
            local ok, err, which = perms(t, k + 1)
            if not ok then return ok, err, which end
            t[k], t[i] = t[i], t[k]
        end
        return true
    end
    local ok, err, which = perms({ "a", "b", "c", "d" }, 1)
    H.ok(ok, "todas as 24 permutações movem a pilha de 4 intacta" .. (which and (" (falhou: " .. which .. ")") or ""))
end

-- ─── Teste 14: findFreeSpace é GHOST-AWARE (base do ghost no multi-drag) ───
-- No multi-drag cada item ganha um ghost; o próximo item NÃO pode colidir com
-- o ghost (se espaça), mas pode EMPILHAR em ghost compatível (mesmo retângulo).
do
    local g = GridCore.new(6, 6)
    local si = { limit = 10, units = 1 }
    -- ghost de item 1 em (2,2)
    g:addGhostItem("ghost1", nil, 2, 2, 1, 1, false, "stack:A", si)

    -- ghost INCOMPATÍVEL bloqueia a MESMA célula (não empilha)
    H.ok(g:canPlaceItem("bad", 2, 2, 1, 1, nil, "stack:B", false, si) == false,
        "ghost incompatível bloqueia a célula (2,2)")
    -- ghost COMPATÍVEL permite empilhar na MESMA célula (preview de stack)
    H.ok(g:canPlaceItem("good", 2, 2, 1, 1, nil, "stack:A", false, si) == true,
        "ghost compatível permite empilhar em (2,2)")
    H.ok(g:insertItem("good", 2, 2, 1, 1, false, nil, "stack:A", si), "insertItem empilha sobre o ghost compatível")
    H.ok(g.items["good"] ~= nil, "item empilhado no preview entrou no grid")
    -- findFreeSpace de um item incompatível NÃO cai na célula do ghost
    local fx, fy = g:findFreeSpace("realX", 1, 1)
    H.ok(fx == 1 and fy == 1, "findFreeSpace incompatível vai pra célula livre (1,1) [(" .. tostring(fx) .. "," .. tostring(fy) .. ")]")
end

-- ─── Teste 15: cache de getPileUnits (stacks[leader].units) ─────────────────
-- O getPileUnits é O(1) lendo o cache incremental; verifica que o cache
-- permanece consistente após: empilhar, remover membro, remover LÍDER com
-- promoção, e relocatePile (que remove tudo e re-empilha no alvo).
do
    local g = GridCore.new(6, 6)
    local si = { limit = 100, units = 5 }

    -- líder a + membros b,c → units = 5*4 = 20
    H.ok(g:insertItem("a", 1, 1, 1, 1, false, nil, "stack:C", si), "a líder")
    H.ok(g:insertItem("b", 1, 1, 1, 1, false, nil, "stack:C", si), "b membro")
    H.ok(g:insertItem("c", 1, 1, 1, 1, false, nil, "stack:C", si), "c membro")
    H.ok(g:getPileUnits("a") == 15, "cache: 3 itens x 5 = 15 units [units=" .. g:getPileUnits("a") .. "]")

    -- remove membro c → 2 itens x 5 = 10
    g:removeItem("c")
    H.ok(g:getPileUnits("a") == 10, "após remover membro: 10 units [units=" .. g:getPileUnits("a") .. "]")

    -- remove o LÍDER a → promove b como novo líder (b+c... na verdade só b
    -- restou como membro; c saiu). Pilha = { b } → 5 units.
    g:removeItem("a")
    local leader = nil
    for id, d in pairs(g.items) do
        if not d.stackMemberOf then leader = id end
    end
    H.ok(leader == "b", "promoção: b virou líder [leader=" .. tostring(leader) .. "]")
    H.ok(g:getPileUnits("b") == 5, "após promoção: 1 item x 5 = 5 units [units=" .. g:getPileUnits("b") .. "]")

    -- relocatePile: b (líder, sem membros) é absorvido por x de outra célula.
    -- b em (1,1); x em (3,1) com 2 itens (x,y). b absorvido → 3 itens x 5.
    g:insertItem("x", 3, 1, 1, 1, false, nil, "stack:C", si)
    g:insertItem("y", 3, 1, 1, 1, false, nil, "stack:C", si)
    local moved = g:relocatePile("b", "x")
    H.ok(moved ~= nil, "relocatePile b→x ok")
    H.ok(g:getPileUnits("x") == 15, "após relocatePile: 3 itens x 5 = 15 units [units=" .. g:getPileUnits("x") .. "]")

    -- item SOLO (sem pilha) também reporta units via stackInfo
    g:insertItem("solo", 5, 1, 1, 1, false, nil, "stack:D", si)
    H.ok(g:getPileUnits("solo") == 5, "item solo = 5 units [units=" .. g:getPileUnits("solo") .. "]")

    -- item sem stackInfo → 0 units
    g:insertItem("noSI", 1, 5, 1, 1, false, nil)
    H.ok(g:getPileUnits("noSI") == 0, "item sem stackInfo = 0 units [units=" .. g:getPileUnits("noSI") .. "]")
end

H.finish()
