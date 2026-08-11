-- drop_preview_test.lua — lógica do preview de drop do GridRender:drawDropPreview().
--
-- O preview pinta as células que o item ocuparia se soltar no cursor:
--   verde  = canPlaceItem no alvo → drop válido EXATAMENTE ali;
--   vermelho = inválido no cursor → o drop real auto-encaixa no 1º espaço livre
--   (contorno verde via findFreeSpace) — SÓ em outro grid;
--   vermelho SEM snap = mesmo grid (drop estrito, nada acontece) ou grid cheio.
--
-- O cálculo de alvo (dropCol/dropRow - grabOffset) e a decisão valid/snap são
-- espelhados AQUI de forma idêntica ao código do GridRender para dar cobertura
-- de regressão sem precisar do ambiente UI do jogo.

local H = require("harness")
H.setName("drop_preview_test")

local GridCore = require("DataModel/GridCore")

local COMPAT = "stack:Base.Twine"

-- Decisão do preview — CÓPIA literal do GridRender:drawDropPreview().
-- sourceGrid = grid de origem do drag (mesmo do drop real); o snap só é
-- sugerido quando o drop vai PARA OUTRO grid.
local function previewDecision(grid, sourceGrid, id, dropCol, dropRow, grabOffsetX, grabOffsetY, w, h, rotated, compatKey, stackInfo, ignoreSet)
    local targetX = dropCol - (grabOffsetX or 0)
    local targetY = dropRow - (grabOffsetY or 0)
    if targetX < 1 then targetX = 1 end
    if targetY < 1 then targetY = 1 end
    local valid = grid:canPlaceItem(id, targetX, targetY, w, h, nil, compatKey, rotated or false, stackInfo, ignoreSet)
    local snapX, snapY
    if not valid and sourceGrid ~= grid then
        snapX, snapY = grid:findFreeSpace(id, w, h, compatKey, stackInfo, rotated or false)
    end
    return valid, snapX, snapY, targetX, targetY
end

-- ─── Caso 1: célula livre sob o cursor → verde (valid=true, sem snap) ────────
do
    local g = GridCore.new(6, 6)
    local valid, snapX, snapY = previewDecision(g, g, "i1", 3, 3, 0, 0, 1, 1, false, nil, nil, nil)
    H.ok(valid, "1: célula livre no cursor é drop válido (verde)")
    H.ok(snapX == nil and snapY == nil, "1: sem snap quando já é válido")
end

-- ─── Caso 2: OUTRO grid, alvo ocupado com espaço → vermelho + snap (contorno) ─
do
    local g = GridCore.new(6, 6)
    local src = GridCore.new(2, 2)
    g:insertItem("occ", 3, 3, 1, 1, false, nil, nil)
    local valid, snapX, snapY = previewDecision(g, src, "i1", 3, 3, 0, 0, 1, 1, false, nil, nil, nil)
    H.ok(not valid, "2: célula ocupada é drop inválido (vermelho)")
    H.ok(snapX ~= nil and snapY ~= nil, "2: outro grid + espaço → contorno de snap")
end

-- ─── Caso 3: MESMO grid, alvo inválido → vermelho SEM snap (nada acontece) ────
do
    local g = GridCore.new(6, 6)
    g:insertItem("occ", 3, 3, 1, 1, false, nil, nil)
    local valid, snapX, snapY = previewDecision(g, g, "i1", 3, 3, 0, 0, 1, 1, false, nil, nil, nil)
    H.ok(not valid, "3: mesmo grid, alvo ocupado é inválido (vermelho)")
    H.ok(snapX == nil and snapY == nil, "3: mesmo grid é estrito → sem contorno de snap")
end

-- ─── Caso 4: grid cheio → vermelho SEM snap (drop falharia) ──────────────────
do
    local g = GridCore.new(2, 2)
    local src = GridCore.new(2, 2)
    for x = 1, 2 do
        for y = 1, 2 do
            g:insertItem("occ" .. x .. y, x, y, 1, 1, false, nil, nil)
        end
    end
    local valid, snapX, snapY = previewDecision(g, src, "i1", 1, 1, 0, 0, 2, 1, false, nil, nil, nil)
    H.ok(not valid, "4: grid cheio é inválido (vermelho)")
    H.ok(snapX == nil and snapY == nil, "4: sem espaço → sem snap")
end

-- ─── Caso 5: grabOffset desloca o alvo (item 2x1 segurado pelo canto) ────────
do
    local g = GridCore.new(6, 6)
    local valid, snapX, snapY, tx, ty = previewDecision(g, g, "i1", 4, 3, 1, 0, 2, 1, false, nil, nil, nil)
    H.ok(valid, "5: drop válido com offset")
    H.ok(tx == 3 and ty == 3, "5: alvo = dropCol - grabOffsetX [tx=" .. tx .. "]")
end

-- ─── Caso 6: snap respeita pilha compatível (empilha, não procura célula) ────
do
    local g = GridCore.new(6, 6)
    local src = GridCore.new(2, 2)
    g:insertItem("leader", 1, 1, 1, 1, false, nil, COMPAT)
    local valid, snapX, snapY = previewDecision(g, src, "i2", 1, 1, 0, 0, 1, 1, false, COMPAT, { limit = 100, units = 1 }, nil)
    H.ok(valid, "6: pilha compatível no cursor é drop válido (verde, empilha)")
    H.ok(snapX == nil, "6: sem snap ao empilhar")
end

-- ─── Caso 7: ignoreSet ignora itens em movimento (arrasto dentro do grid) ────
do
    local g = GridCore.new(6, 6)
    g:insertItem("drag1", 2, 2, 1, 1, false, nil, nil)
    -- item sendo arrastado ainda está no grid: com ignoreSet, o alvo sobre a
    -- posição de origem é considerado livre (drop no MESMO lugar).
    local ignoreSet = { ["drag1"] = true }
    local valid = g:canPlaceItem("drag1", 2, 2, 1, 1, nil, nil, false, nil, ignoreSet)
    H.ok(valid, "7: ignoreSet libera a célula do próprio item em movimento")
end

-- ─── Caso 8: canFitItems — grid vazio cabe unidade grande ───────────────────
do
    local g = GridCore.new(4, 4)
    local fits = g:canFitItems({ { id = "i1", w = 2, h = 2 } })
    H.ok(fits == true, "8: área total cabe no grid vazio")
end

-- ─── Caso 9: canFitItems — grid cheio não cabe nada ─────────────────────────
do
    local g = GridCore.new(2, 2)
    for x = 1, 2 do
        for y = 1, 2 do
            g:insertItem("occ" .. x .. y, x, y, 1, 1, false, nil, nil)
        end
    end
    local fits = g:canFitItems({ { id = "i1", w = 1, h = 1 } })
    H.ok(fits == false, "9: grid cheio → não cabe (vermelho)")
end

-- ─── Caso 10: movedSet libera células de itens saindo (drop no mesmo grid) ──
do
    local g = GridCore.new(2, 2)
    g:insertItem("a", 1, 1, 1, 1, false, nil, nil)
    g:insertItem("b", 2, 2, 1, 1, false, nil, nil)
    local fits = g:canFitItems({ { id = "i1", w = 1, h = 1 } }, { a = true })
    H.ok(fits == true, "10: célula do item saindo conta como livre")
end

-- ─── Caso 11: unidade empilhável usa pilha compatível (sem célula nova) ──────
do
    local g = GridCore.new(1, 2)
    g:insertItem("leader", 1, 1, 1, 1, false, nil, COMPAT)
    g:insertItem("blocker", 1, 2, 1, 1, false, nil, nil)
    local fits = g:canFitItems({ { id = "i2", w = 1, h = 1, compatKey = COMPAT, stackInfo = { limit = 100, units = 1 } } })
    H.ok(fits == true, "11: empilha na compatível mesmo sem célula livre")
end

-- ─── Caso 12: área necessária maior que o livre → não cabe ──────────────────
do
    local g = GridCore.new(3, 1)
    g:insertItem("occ1", 1, 1, 1, 1, false, nil, nil)
    local fits = g:canFitItems({ { id = "i1", w = 2, h = 1 }, { id = "i2", w = 2, h = 1 } })
    H.ok(fits == false, "12: área somada passa do espaço livre")
end

-- ─── Caso 13: duas unidades sem compat somam área ────────────────────────────
do
    local g = GridCore.new(4, 1)
    local fits = g:canFitItems({ { id = "i1", w = 1, h = 1 }, { id = "i2", w = 2, h = 1 } })
    H.ok(fits == true, "13: área somada cabe")
end

H.finish()
