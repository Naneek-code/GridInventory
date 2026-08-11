-- drop_preview_test.lua — lógica do preview de drop do GridRender:drawDropPreview().
--
-- O preview pinta as células que o item ocuparia se soltar no cursor:
--   verde  = canPlaceItem no alvo → drop válido EXATAMENTE ali;
--   vermelho = inválido no cursor (drop real auto-encaixa no 1º espaço livre,
--   indicado com um contorno verde via findFreeSpace);
--   vermelho SEM snap = grid cheio (drop falharia).
--
-- O cálculo de alvo (dropCol/dropRow - grabOffset) e a decisão valid/snap são
-- espelhados AQUI de forma idêntica ao código do GridRender para dar cobertura
-- de regressão sem precisar do ambiente UI do jogo.

local H = require("harness")
H.setName("drop_preview_test")

local GridCore = require("DataModel/GridCore")

local COMPAT = "stack:Base.Twine"

-- Decisão do preview — CÓPIA literal do GridRender:drawDropPreview().
local function previewDecision(grid, id, dropCol, dropRow, grabOffsetX, grabOffsetY, w, h, rotated, compatKey, stackInfo, ignoreSet)
    local targetX = dropCol - (grabOffsetX or 0)
    local targetY = dropRow - (grabOffsetY or 0)
    if targetX < 1 then targetX = 1 end
    if targetY < 1 then targetY = 1 end
    local valid = grid:canPlaceItem(id, targetX, targetY, w, h, nil, compatKey, rotated or false, stackInfo, ignoreSet)
    local snapX, snapY
    if not valid then
        snapX, snapY = grid:findFreeSpace(id, w, h, compatKey, stackInfo, rotated or false)
    end
    return valid, snapX, snapY, targetX, targetY
end

-- ─── Caso 1: célula livre sob o cursor → verde (valid=true, sem snap) ────────
do
    local g = GridCore.new(6, 6)
    local valid, snapX, snapY = previewDecision(g, "i1", 3, 3, 0, 0, 1, 1, false, nil, nil, nil)
    H.ok(valid, "1: célula livre no cursor é drop válido (verde)")
    H.ok(snapX == nil and snapY == nil, "1: sem snap quando já é válido")
end

-- ─── Caso 2: alvo ocupado, mas grid tem espaço → vermelho + snap (contorno) ──
do
    local g = GridCore.new(6, 6)
    g:insertItem("occ", 3, 3, 1, 1, false, nil, nil)
    local valid, snapX, snapY = previewDecision(g, "i1", 3, 3, 0, 0, 1, 1, false, nil, nil, nil)
    H.ok(not valid, "2: célula ocupada é drop inválido (vermelho)")
    H.ok(snapX ~= nil and snapY ~= nil, "2: existe espaço livre → contorno de snap")
end

-- ─── Caso 3: grid cheio → vermelho SEM snap (drop falharia) ──────────────────
do
    local g = GridCore.new(2, 2)
    for x = 1, 2 do
        for y = 1, 2 do
            g:insertItem("occ" .. x .. y, x, y, 1, 1, false, nil, nil)
        end
    end
    local valid, snapX, snapY = previewDecision(g, "i1", 1, 1, 0, 0, 2, 1, false, nil, nil, nil)
    H.ok(not valid, "3: grid cheio é inválido (vermelho)")
    H.ok(snapX == nil and snapY == nil, "3: sem espaço → sem snap")
end

-- ─── Caso 4: grabOffset desloca o alvo (item 2x1 segurado pelo canto) ────────
do
    local g = GridCore.new(6, 6)
    local valid, snapX, snapY, tx, ty = previewDecision(g, "i1", 4, 3, 1, 0, 2, 1, false, nil, nil, nil)
    H.ok(valid, "4: drop válido com offset")
    H.ok(tx == 3 and ty == 3, "4: alvo = dropCol - grabOffsetX [tx=" .. tx .. "]")
end

-- ─── Caso 5: snap respeita pilha compatível (empilha, não procura célula) ────
do
    local g = GridCore.new(6, 6)
    g:insertItem("leader", 1, 1, 1, 1, false, nil, COMPAT)
    local valid, snapX, snapY = previewDecision(g, "i2", 1, 1, 0, 0, 1, 1, false, COMPAT, { limit = 100, units = 1 }, nil)
    H.ok(valid, "5: pilha compatível no cursor é drop válido (verde, empilha)")
    H.ok(snapX == nil, "5: sem snap ao empilhar")
end

-- ─── Caso 6: ignoreSet ignora itens em movimento (arrasto dentro do grid) ────
do
    local g = GridCore.new(6, 6)
    g:insertItem("drag1", 2, 2, 1, 1, false, nil, nil)
    -- item sendo arrastado ainda está no grid: com ignoreSet, o alvo sobre a
    -- posição de origem é considerado livre (drop no MESMO lugar).
    local ignoreSet = { ["drag1"] = true }
    local valid = g:canPlaceItem("drag1", 2, 2, 1, 1, nil, nil, false, nil, ignoreSet)
    H.ok(valid, "6: ignoreSet libera a célula do próprio item em movimento")
end

H.finish()
