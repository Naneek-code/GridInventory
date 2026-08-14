-- reorder_action_test.lua — reorder dentro do MESMO grid.
-- Cobre:
--   * GridSandboxOptions.isReorderTimed() (leitura da option, 1-based).
--   * GridReorder.computeTargets (cálculo/validação de alvos + movedSet).
--   * GridReorder.isNoOp (drop na própria posição = sem movimento).
--   * GridReorder.apply (revalidação + remove/insere all-or-nothing).

local H = require("harness")
H.setName("reorder_action_test")

local GridSandboxOptions = require("GridSandboxOptions")
local GridReorder = require("Algorithm/GridReorder")
local GridCore = require("DataModel/GridCore")

-- ── Helpers ─────────────────────────────────────────────────────────────────
-- itemsData como o GridInventory_GlobalDrag cria (id, footprints, grab offsets,
-- compatKey/stackInfo do item arrastado).
local function dragData(id, w, h, rotated, grabX, grabY, compatKey)
    return {
        id = id,
        originalW = w,
        originalH = h,
        rotated = rotated or false,
        grabOffsetX = grabX or 0,
        grabOffsetY = grabY or 0,
        compatKey = compatKey,
        stackInfo = nil,
        itemObj = nil,
    }
end

local function freshGrid(w, h)
    return GridCore.new(w or 6, h or 6)
end

-- ─── isReorderTimed: sandbox option ─────────────────────────────────────────
do
    _G.getSandboxOptions = nil
    H.ok(GridSandboxOptions.isReorderTimed() == true, "sem sandbox -> timed=true")

    GridSandboxOptions.invalidateCache()
    _G.getSandboxOptions = function()
        return { getOptionByName = function() return { getValue = function() return 1 end } end }
    end
    H.ok(GridSandboxOptions.isReorderTimed() == true, "sandbox value=1 -> timed=true")

    GridSandboxOptions.invalidateCache()
    _G.getSandboxOptions = function()
        return { getOptionByName = function() return { getValue = function() return 2 end } end }
    end
    H.ok(GridSandboxOptions.isReorderTimed() == false, "sandbox value=2 -> timed=false")

    GridSandboxOptions.invalidateCache()
    _G.getSandboxOptions = function()
        return { getOptionByName = function() error("boom") end }
    end
    H.ok(GridSandboxOptions.isReorderTimed() == true, "getOptionByName falhando -> fallback true")
    _G.getSandboxOptions = nil
end

-- ─── isReorderMoveWhileWalking: sandbox option (default LIGADA) ──────────────
do
    GridSandboxOptions.invalidateCache()
    _G.getSandboxOptions = nil
    H.ok(GridSandboxOptions.isReorderMoveWhileWalking() == true, "sem sandbox -> pode andar=true (default ligada)")

    GridSandboxOptions.invalidateCache()
    _G.getSandboxOptions = function()
        return { getOptionByName = function() return { getValue = function() return true end } end }
    end
    H.ok(GridSandboxOptions.isReorderMoveWhileWalking() == true, "sandbox value=true -> pode andar")

    GridSandboxOptions.invalidateCache()
    _G.getSandboxOptions = function()
        return { getOptionByName = function() return { getValue = function() return false end } end }
    end
    H.ok(GridSandboxOptions.isReorderMoveWhileWalking() == false, "sandbox value=false -> parado")

    GridSandboxOptions.invalidateCache()
    _G.getSandboxOptions = function()
        return { getOptionByName = function() error("boom") end }
    end
    H.ok(GridSandboxOptions.isReorderMoveWhileWalking() == true, "getOptionByName falhando -> fallback true")
    _G.getSandboxOptions = nil
end

-- ─── computeTargets: item único ─────────────────────────────────────────────
do
    local g = freshGrid()
    g:insertItem("a", 1, 1, 1, 1)
    local targets = GridReorder.computeTargets(g, { dragData("a", 1, 1) }, 3, 1)
    H.ok(targets ~= nil, "drop livre computa alvo")
    if targets then
        H.ok(targets[1].tx == 3 and targets[1].ty == 1,
            "a -> (3,1) [tx=" .. tostring(targets[1].tx) .. " ty=" .. tostring(targets[1].ty) .. "]")
        H.ok(targets[1].ew == 1 and targets[1].eh == 1, "footprint 1x1")
    end

    -- grab offset desloca o alvo (mouse pega no meio do item)
    local targets2 = GridReorder.computeTargets(g, { dragData("a", 2, 2, false, 1, 1) }, 3, 3)
    H.ok(targets2 ~= nil, "drop com grab offset computa")
    if targets2 then
        H.ok(targets2[1].tx == 2 and targets2[1].ty == 2,
            "grabOffset (1,1) -> (2,2) [tx=" .. tostring(targets2[1].tx) .. "]")
    end

    -- clamp negativo
    local targets3 = GridReorder.computeTargets(g, { dragData("a", 1, 1, false, 5, 5) }, 2, 2)
    H.ok(targets3 ~= nil, "drop com alvo negativo ainda computa")
    if targets3 then
        H.ok(targets3[1].tx == 1 and targets3[1].ty == 1, "clamp pra (1,1)")
    end

    -- alvo ocupado por item fora do movedSet -> drop inválido (nil)
    g:insertItem("blocker", 3, 1, 1, 1)
    H.ok(GridReorder.computeTargets(g, { dragData("a", 1, 1) }, 3, 1) == nil,
        "alvo ocupado -> nil (drop inválido)")

    -- rotação troca footprint efetivo
    local g2 = freshGrid()
    g2:insertItem("long", 1, 1, 2, 1)
    local tRot = GridReorder.computeTargets(g2, { dragData("long", 2, 1, true) }, 4, 1)
    H.ok(tRot ~= nil, "drop rotacionado computa")
    if tRot then
        H.ok(tRot[1].ew == 1 and tRot[1].eh == 2,
            "rotated: footprint vira 1x2 [ew=" .. tostring(tRot[1].ew) .. " eh=" .. tostring(tRot[1].eh) .. "]")
    end
end

-- ─── computeTargets: pilha arrastada (movedSet) ─────────────────────────────
do
    local g = freshGrid()
    g:insertItem("leader", 1, 1, 1, 1, false, nil, "ammo")
    g:insertItem("m1", 1, 1, 1, 1, false, nil, "ammo")
    g:insertItem("m2", 1, 1, 1, 1, false, nil, "ammo")

    local itemsData = {
        dragData("leader", 1, 1, false, 0, 0, "ammo"),
        dragData("m1", 1, 1, false, 0, 0, "ammo"),
        dragData("m2", 1, 1, false, 0, 0, "ammo"),
    }
    -- drop NA origem (1,1) da pilha inteira: os membros ainda ocupam (1,1) mas
    -- vão sair juntos -> deve passar (movedSet).
    local targets, movedSet = GridReorder.computeTargets(g, itemsData, 1, 1)
    H.ok(targets ~= nil, "pilha inteira pode cair na própria origem")
    if targets then
        H.ok(#targets == 3, "3 alvos computados [n=" .. tostring(#targets) .. "]")
        H.ok(movedSet["leader"] and movedSet["m1"] and movedSet["m2"],
            "movedSet tem os 3 ids")
    end
end

-- ─── isNoOp ─────────────────────────────────────────────────────────────────
do
    local g = freshGrid()
    g:insertItem("a", 1, 1, 2, 1)

    local same = GridReorder.computeTargets(g, { dragData("a", 2, 1) }, 1, 1)
    H.ok(GridReorder.isNoOp(g, same) == true, "drop na própria posição = no-op")

    local moved = GridReorder.computeTargets(g, { dragData("a", 2, 1) }, 4, 1)
    H.ok(GridReorder.isNoOp(g, moved) == false, "drop em outra célula != no-op")

    -- rotação diferente conta como movimento
    local rot = GridReorder.computeTargets(g, { dragData("a", 2, 1, true) }, 1, 1)
    H.ok(GridReorder.isNoOp(g, rot) == false, "mudança de rotação != no-op")

    H.ok(GridReorder.isNoOp(g, nil) == true, "targets nil = no-op")
    H.ok(GridReorder.isNoOp(g, {}) == true, "targets vazio = no-op")
end

-- ─── apply: reorder simples ─────────────────────────────────────────────────
do
    local g = freshGrid()
    g:insertItem("a", 1, 1, 1, 1)
    g:insertItem("b", 1, 2, 1, 1)
    -- Drag real: a pegou na origem (1,1), b pegou (1,2) → drop em (3,3)
    -- espalha a→(3,3) e b→(3,2) (grab offset 0,1 desloca pra cima).
    local targets = GridReorder.computeTargets(g, {
        dragData("a", 1, 1, false, 0, 0), dragData("b", 1, 1, false, 0, 1),
    }, 3, 3)

    H.ok(GridReorder.apply(g, targets) == true, "apply aplica")
    H.ok(g.items["a"].x == 3 and g.items["a"].y == 3, "a foi pra (3,3)")
    H.ok(g.items["b"].x == 3 and g.items["b"].y == 2, "b foi pra (3,2)")
    H.ok(g.cells[1][1] == nil and g.cells[1][2] == nil, "origem liberada")
    H.ok(g.cells[3][3] == "a" and g.cells[3][2] == "b", "destino ocupado")
end

-- ─── apply: all-or-nothing (grid mudou entre drop e perform) ────────────────
do
    local g = freshGrid()
    g:insertItem("a", 1, 1, 1, 1)
    g:insertItem("b", 1, 2, 1, 1)
    local targets = GridReorder.computeTargets(g, {
        dragData("a", 1, 1, false, 0, 0), dragData("b", 1, 1, false, 0, 1),
    }, 3, 3)
    H.ok(targets ~= nil, "drop válido no momento do drop")

    -- ENTRE o drop e o perform, um intruso ocupou (3,2) — o destino de b.
    g:insertItem("intruder", 3, 2, 1, 1)
    H.ok(GridReorder.apply(g, targets) == false, "alvo ficou ocupado -> aborta")
    H.ok(g.items["a"].x == 1 and g.items["b"].y == 2, "nada foi movido")
    H.ok(g.cells[3][3] == nil, "célula (3,3) segue livre")
end

-- ─── apply: item sumiu do grid entre drop e perform ─────────────────────────
do
    local g = freshGrid()
    g:insertItem("a", 1, 1, 1, 1)
    local targets = GridReorder.computeTargets(g, { dragData("a", 1, 1) }, 3, 1)
    g:removeItem("a")
    H.ok(GridReorder.apply(g, targets) == false, "item removido -> aborta (sem mover)")
end

-- ─── apply: entradas inválidas ──────────────────────────────────────────────
do
    local g = freshGrid()
    H.ok(GridReorder.apply(g, {}) == false, "targets vazio -> false")
    H.ok(GridReorder.apply(g, nil) == false, "targets nil -> false")
    H.ok(GridReorder.apply(nil, { { item = {} } }) == false, "gridCore nil -> false")
end

H.finish()
