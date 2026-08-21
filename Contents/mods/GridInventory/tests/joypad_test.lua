-- joypad_test.lua
-- Navegação do cursor virtual do joypad: findNeighbor (multi-grid), boundary,
-- switchFocus (LB/RB inv<->loot) e handleDir na borda dos grids.
--
-- Simula o layout REAL do flexbox:
--   * Painel do jogador (RTL): grids da DIREITA pra esquerda.
--     container ativo (inv principal, 3x4) fica à direita; a bolsa à esquerda.
--   * Painel de loot (LTR): grids da ESQUERDA pra direita.
--
-- Os stubs do GridRender imitam os campos usados pelo GridJoypad:
--   gridCore, inventoryContainer, gridIndex, baseX/baseY, width/height,
--   cellSize, gridPadding, headerH, getIsVisible, parent (pane).
local H = require("harness")
H.setName("joypad_test")

local joypadPath = H.base .. "/42.20/media/lua/client/System/GridJoypad.lua"
local GJP = assert(loadfile(joypadPath))()

-- ---------------------------------------------------------------------------
-- Stubs do ambiente PZ
-- ---------------------------------------------------------------------------
local invPage = { onCharacter = true }
local lootPage = { onCharacter = false }
invPage.getX = function() return 0 end
lootPage.getX = function() return 640 end

local invPane = {
    inventoryPage = invPage,
    inventory = "player-inv",
    gridContainerUis = {},
}
local lootPane = {
    inventoryPage = lootPage,
    inventory = "loot-inv",
    gridContainerUis = {},
}
invPage.inventoryPane = invPane
lootPage.inventoryPane = lootPane

local focusTarget = nil
function _G.setJoypadFocus(playerNum, target)
    focusTarget = target
end
function _G.getFocusForPlayer(playerNum)
    return focusTarget
end
function _G.getPlayerInventory(playerNum)
    return invPage
end
function _G.getPlayerLoot(playerNum)
    return lootPage
end
function _G.getSpecificPlayer(playerNum)
    return { isAsleep = function() return false end }
end

-- Stub do selectNextContainer vanilla: cicla os containers do painel e seta
-- pane.inventory (o que o refreshContainer usa pra nascer o grid ativo).
local invBackpacks = { "player-inv", "backpack" }
local lootBackpacks = { "loot-inv", "loot-bag" }
local function nextOf(list, cur)
    for i, v in ipairs(list) do
        if v == cur then
            return list[i % #list + 1]
        end
    end
    return list[1]
end
function invPage:selectNextContainer()
    invPane.inventory = nextOf(invBackpacks, invPane.inventory)
end
function lootPage:selectNextContainer()
    lootPane.inventory = nextOf(lootBackpacks, lootPane.inventory)
end
-- Stub do selectButtonForContainer vanilla: seleciona o container (no nav).
function invPage:selectButtonForContainer(container)
    invPane.inventory = container
end
function lootPage:selectButtonForContainer(container)
    lootPane.inventory = container
end

-- Cria um GridRender falso.
local function makeGrid(name, container, cols, rows, x, y)
    local cell = 40
    local pad = 10
    local header = 28
    local grid = {
        name = name,
        playerNum = 0,
        gridCore = { width = cols, height = rows },
        inventoryContainer = container,
        gridIndex = 1,
        baseX = x,
        baseY = y,
        width = cols * cell + pad * 2,
        height = rows * cell + pad * 2 + header,
        cellSize = cell,
        gridPadding = pad,
        headerH = header,
        _visible = true,
    }
    function grid:getX() return self.baseX end
    function grid:getY() return self.baseY end
    function grid:getAbsoluteX() return self.baseX or 0 end
    function grid:getAbsoluteY() return self.baseY or 0 end
    function grid:getIsVisible() return self._visible end
    function grid:getWidth() return self.width end
    function grid:getHeight() return self.height end
    return grid
end

-- O addChild vanilla (ISUIElement) seta grid.parent = pane; o findNeighbor
-- resolve o painel por aí. Simula isso ao registrar o grid no pane.
local function addGridToPane(pane, grid)
    grid.parent = pane
    table.insert(pane.gridContainerUis, grid)
end

local function resetPanes()
    invPane.gridContainerUis = {}
    lootPane.gridContainerUis = {}
    focusTarget = nil
    GJP.cursors = {}
    GJP.navs = {}
end

-- ---------------------------------------------------------------------------
-- findNeighbor: painel do JOGADOR (RTL) — inv principal (3x4) à direita, bolsa
-- à esquerda, mesmo yGap vertical. É o cenário do "cursor cego" do usuário.
-- ---------------------------------------------------------------------------
resetPanes()
local playerInvGrid = makeGrid("player-inv", "player-inv", 3, 4, 500, 15)   -- baseX
local backpackGrid  = makeGrid("backpack",  "backpack",  5, 4, 305, 15)    -- mesma altura p/ alinhar centros na vertical
addGridToPane(invPane, playerInvGrid)
addGridToPane(invPane, backpackGrid)

-- Flexbox do jogador (RTL): paneWidth=640, xMargin=15, xGap=15.
-- playerInvGrid: baseX = 640-15-140 = 485; backpack: curX = 485-15 = 470; baseX = 470-220 = 250
playerInvGrid.baseX = 485
backpackGrid.baseX = 250

-- A partir do inv principal (à direita), pra ESQUERDA acha a bolsa.
H.ok(GJP.findNeighbor(playerInvGrid, -1, 0) == backpackGrid, "findNeighbor(-1,0) do inv principal acha a bolsa")
-- Da bolsa (à esquerda), pra DIREITA acha o inv principal.
H.ok(GJP.findNeighbor(backpackGrid, 1, 0) == playerInvGrid, "findNeighbor(1,0) da bolsa acha o inv principal")
-- Pra direita do inv principal (nada além dele): nil.
H.ok(GJP.findNeighbor(playerInvGrid, 1, 0) == nil, "findNeighbor(1,0) do inv principal = nil (borda do painel)")
-- Pra esquerda da bolsa: nil.
H.ok(GJP.findNeighbor(backpackGrid, -1, 0) == nil, "findNeighbor(-1,0) da bolsa = nil (borda do painel)")
-- Vertical (mesma linha): nem acima nem abaixo (centros alinhados => ddy=0).
H.ok(GJP.findNeighbor(playerInvGrid, 0, 1) == nil, "findNeighbor(0,1) inv principal = nil (mesma linha)")
H.ok(GJP.findNeighbor(playerInvGrid, 0, -1) == nil, "findNeighbor(0,-1) inv principal = nil (mesma linha)")

-- Grid marcado como oculto (flag Lua joypadHidden) não é candidato a vizinho.
backpackGrid.joypadHidden = true
H.ok(GJP.findNeighbor(playerInvGrid, -1, 0) == nil, "findNeighbor ignora grid oculto")
backpackGrid.joypadHidden = nil

-- FALLBACK: grid EMPILHADO na vertical com o MESMO centro no eixo dominante
-- (ddx=0 indo pra direita) é alcançado mesmo sem candidato estrito — o floor
-- que nasce logo abaixo do grid do container (mesma largura) não cai mais no
-- switchFocus pro outro painel.
resetPanes()
local stackCorpse = makeGrid("corpse", "corpse-inv", 4, 3, 15, 15)
local stackFloor  = makeGrid("floor",  "floor",     4, 3, 15, 198)
addGridToPane(lootPane, stackCorpse)
addGridToPane(lootPane, stackFloor)
H.ok(GJP.findNeighbor(stackCorpse, 1, 0) == stackFloor, "findNeighbor(1,0) alcança o floor empilhado abaixo (fallback)")
H.ok(GJP.findNeighbor(stackCorpse, -1, 0) == stackFloor, "findNeighbor(-1,0) alcança o floor empilhado abaixo (fallback)")
H.ok(GJP.findNeighbor(stackCorpse, 0, 1) == stackFloor, "findNeighbor(0,1) acha o floor empilhado (estrito)")
-- Mas um grid que ficou ATRÁS não é alcançado (preserva alternar inv<->loot).
resetPanes()
local backGrid = makeGrid("back", "back", 4, 3, 15, 15)
local rightGrid = makeGrid("right", "right", 4, 3, 500, 15)
addGridToPane(invPane, backGrid)
addGridToPane(invPane, rightGrid)
H.ok(GJP.findNeighbor(rightGrid, 1, 0) == nil, "findNeighbor(1,0) não pula pra um grid ATRÁS (esquerda)")
H.ok(GJP.findNeighbor(backGrid, -1, 0) == nil, "findNeighbor(-1,0) não pula pra um grid ATRÁS (direita)")

-- ---------------------------------------------------------------------------
-- findNeighbor multi-LINHA (flexbox wrap): a bolsa "quebrou" pra baixo do inv
-- principal (cenário do cursor cego do usuário — grid vizinho em outra linha).
-- Painel do jogador RTL: inv principal (3x4) à direita, bolsa embaixo, à
-- esquerda (baseX menor, baseY maior).
-- ---------------------------------------------------------------------------
resetPanes()
local wrapPlayerInv = makeGrid("player-inv", "player-inv", 3, 4, 485, 15)
local wrapBackpack  = makeGrid("backpack",  "backpack",  5, 3, 250, 260)
addGridToPane(invPane, wrapPlayerInv)
addGridToPane(invPane, wrapBackpack)

-- Da borda de BAIXO do inv principal, desce pra bolsa (que está na linha de baixo).
H.ok(GJP.findNeighbor(wrapPlayerInv, 0, 1) == wrapBackpack, "findNeighbor(0,1) acha bolsa na linha de baixo (wrap)")
-- Da bolsa, SOBE pro inv principal.
H.ok(GJP.findNeighbor(wrapBackpack, 0, -1) == wrapPlayerInv, "findNeighbor(0,-1) da bolsa acha o inv principal (wrap)")
-- Horizontal entre linhas diferentes: a bolsa está "atrás" do inv na horizontal
-- (centros não alinhados) — deixa o vertical resolver.
H.ok(GJP.findNeighbor(wrapPlayerInv, -1, 0) == wrapBackpack, "findNeighbor(-1,0) continua achando a bolsa (esquerda+baixo)")
H.ok(GJP.findNeighbor(wrapBackpack, 1, 0) == wrapPlayerInv, "findNeighbor(1,0) da bolsa acha o inv principal (direita+cima)")

-- ---------------------------------------------------------------------------
-- findNeighbor: painel LOOT (LTR) — floor + container em colunas diferentes.
-- ---------------------------------------------------------------------------
resetPanes()
local floorGrid  = makeGrid("floor", "floor", 6, 4, 15, 15)     -- esquerda
local lootGrid   = makeGrid("loot",  "loot-inv", 4, 3, 405, 15) -- direita
addGridToPane(lootPane, floorGrid)
addGridToPane(lootPane, lootGrid)
-- paneWidth=640: floor baseX=15 (largura 260) => ocupa até 275; loot curX=290; baseX=290
floorGrid.baseX = 15
lootGrid.baseX = 290

H.ok(GJP.findNeighbor(floorGrid, 1, 0) == lootGrid, "findNeighbor(1,0) floor acha o loot (LTR)")
H.ok(GJP.findNeighbor(lootGrid, -1, 0) == floorGrid, "findNeighbor(-1,0) loot acha o floor (LTR)")

-- ---------------------------------------------------------------------------
-- boundary + handleDir: cursor chega na borda do inv principal e salta pra
-- bolsa (horizontal); depois na borda externa do painel vai pro loot.
-- ---------------------------------------------------------------------------
resetPanes()
addGridToPane(invPane, playerInvGrid)
addGridToPane(invPane, backpackGrid)
playerInvGrid.baseX = 485
backpackGrid.baseX = 250

-- Cursor começa no inv principal, célula (1,1).
GJP.cursors[0] = {
    container = "player-inv", gridIndex = 1, grid = playerInvGrid,
    col = 1, row = 1
}
-- Move pra esquerda da borda: salta pra bolsa, entrando pela ÚLTIMA coluna dela.
local ok = GJP.handleDir(0, invPage, -1, 0)
local cur = GJP.cursors[0]
H.ok(ok, "handleDir(-1,0) na borda do inv principal retorna true")
H.ok(cur.grid == backpackGrid, "cursor foi re-ancorado na bolsa")
H.ok(cur.container == "backpack", "cursor.container = bolsa")
H.ok(cur.col == backpackGrid.gridCore.width, "cursor entrou na última coluna da bolsa")
H.ok(cur.row >= 1 and cur.row <= backpackGrid.gridCore.height, "cursor.row dentro da bolsa")

-- Da borda ESQUERDA da bolsa (não há grid mais à esquerda) e o painel é o inv
-- (à direita na tela => toX > fromX?): o switchFocus pro LOOT vem do boundary
-- passo 2 (página == inv => outro = loot).
resetPanes()
addGridToPane(invPane, playerInvGrid)
addGridToPane(invPane, backpackGrid)
playerInvGrid.baseX = 485
backpackGrid.baseX = 250
GJP.cursors[0] = {
    container = "backpack", gridIndex = 1, grid = backpackGrid,
    col = 1, row = 1
}
ok = GJP.handleDir(0, invPage, -1, 0)
H.ok(ok, "handleDir(-1,0) na borda esquerda da bolsa = switchFocus pro loot")
H.ok(focusTarget == lootPage, "switchFocus direciona pro loot quando saí pela esquerda do inv")

-- ---------------------------------------------------------------------------
-- switchFocus (LB/RB): foco direto pro painel alvo com cursor em (1,1).
-- ---------------------------------------------------------------------------
resetPanes()
addGridToPane(invPane, playerInvGrid)
addGridToPane(invPane, backpackGrid)
addGridToPane(lootPane, floorGrid)
addGridToPane(lootPane, lootGrid)
playerInvGrid.baseX = 485
backpackGrid.baseX = 250
floorGrid.baseX = 15
lootGrid.baseX = 290

-- LB: inv. Cursor ancorado no grid do container ativo do inv (player-inv).
GJP.cursors[0] = {
    container = "player-inv", gridIndex = 1, grid = playerInvGrid,
    col = 2, row = 3
}
GJP.switchFocus(0, lootPage, invPage, true)
cur = GJP.cursors[0]
H.ok(focusTarget == invPage, "switchFocus foca o inv")
H.ok(cur.grid == playerInvGrid, "switchFocus ancora no grid do container ativo do inv")
H.ok(cur.col == 1 and cur.row == 1, "switchFocus LB (home) posiciona cursor em (1,1)")

-- RB: loot. Cursor ancorado no grid do container ativo do loot (loot-inv).
GJP.cursors[0] = {
    container = "loot-inv", gridIndex = 1, grid = lootGrid,
    col = 2, row = 3
}
GJP.switchFocus(0, invPage, lootPage, true)
cur = GJP.cursors[0]
H.ok(focusTarget == lootPage, "switchFocus foca o loot")
H.ok(cur.grid == lootGrid, "switchFocus ancora no grid do container ativo do loot")
H.ok(cur.col == 1 and cur.row == 1, "switchFocus RB (home) posiciona cursor em (1,1)")

-- switchFocus SEM home (borda): entra pelo lado de entrada, não em (1,1).
GJP.cursors[0] = {
    container = "player-inv", gridIndex = 1, grid = playerInvGrid,
    col = 2, row = 3
}
GJP.switchFocus(0, invPage, lootPage)
cur = GJP.cursors[0]
H.ok(cur.grid == lootGrid, "switchFocus (borda) ancora no grid do container ativo do loot")
H.ok(cur.col == 1, "switchFocus (borda) entra pela coluna 1 (loot à direita do inv)")

GJP.cursors[0] = {
    container = "loot-inv", gridIndex = 1, grid = lootGrid,
    col = 2, row = 3
}
GJP.switchFocus(0, lootPage, invPage)
cur = GJP.cursors[0]
H.ok(cur.grid == playerInvGrid, "switchFocus (borda) ancora no grid do container ativo do inv")
H.ok(cur.col == playerInvGrid.gridCore.width, "switchFocus (borda) entra pela última coluna (inv à esquerda do loot)")

-- ---------------------------------------------------------------------------
-- FOOTPRINT: o cursor sobre um item pula pra BORDA do footprint na direção
-- (um item 6x1 cruza de UMA vez, em vez de 6 toques célula a célula).
-- ---------------------------------------------------------------------------
resetPanes()
local fpGrid = makeGrid("fp", "fp", 8, 4, 15, 15)
local fpCells = {}
for c = 2, 7 do
    fpCells[c] = fpCells[c] or {}
    fpCells[c][1] = "big1"
end
for r = 1, 3 do
    fpCells[1] = fpCells[1] or {}
    fpCells[1][r] = "tall1"
end
fpGrid.gridCore.cells = fpCells
fpGrid.gridCore.items = {
    big1 = { x = 2, y = 1, w = 6, h = 1, itemObj = {} },
    tall1 = { x = 1, y = 1, w = 1, h = 3, itemObj = {} },
}
addGridToPane(lootPane, fpGrid)
GJP.cursors[0] = {
    container = "fp", gridIndex = 1, grid = fpGrid,
    col = 2, row = 1
}
-- 6x1: da célula inicial, direita salta direto pra col 8 (x+w).
local fpOk = GJP.handleDir(0, lootPage, 1, 0)
cur = GJP.cursors[0]
H.ok(fpOk, "handleDir(1,0) sobre footprint retorna true")
H.ok(cur.col == 8, "footprint 6x1: direita salta pra borda (col x+w=8) em 1 toque")
-- Do interior, esquerda salta pra x-1.
GJP.cursors[0].col = 4
GJP.cursors[0].row = 1
GJP.handleDir(0, lootPage, -1, 0)
cur = GJP.cursors[0]
H.ok(cur.col == 1, "footprint 6x1: do interior, esquerda salta pra x-1")
-- Vertical num item 1x3: de cima, baixo salta pra y+h.
GJP.cursors[0] = {
    container = "fp", gridIndex = 1, grid = fpGrid,
    col = 1, row = 1
}
GJP.handleDir(0, lootPage, 0, 1)
cur = GJP.cursors[0]
H.ok(cur.row == 4, "footprint 1x3: baixo salta pra borda (row y+h=4)")
-- Fora de item (célula vazia): sem footprint pra saltar — move célula a célula
-- (cell-to-cell, sem snap).
GJP.cursors[0] = {
    container = "fp", gridIndex = 1, grid = fpGrid,
    col = 1, row = 4
}
GJP.handleDir(0, lootPage, 1, 0)
cur = GJP.cursors[0]
H.ok(cur.col == 2, "fora de item: move 1 célula (cell-to-cell, sem snap)")

-- ---------------------------------------------------------------------------
-- RENDER NÃO PODE SEQUESTRAR O CURSOR (isCursorOn com preserve):
-- o render do painel OPOSTO chamava resolveCursor (com fallback pro container
-- ATIVO) e "jogava o cursor de volta pro 1,1 do container selecionado" quando
-- ele estava num grid NÃO-ativo (mochila/chão). O render agora só re-acha o
-- MESMO grid; nunca força o container ativo.
-- ---------------------------------------------------------------------------
resetPanes()
addGridToPane(invPane, playerInvGrid)
addGridToPane(invPane, backpackGrid)
addGridToPane(lootPane, floorGrid)
addGridToPane(lootPane, lootGrid)
playerInvGrid.baseX = 485
backpackGrid.baseX = 250
floorGrid.baseX = 15
lootGrid.baseX = 290
invPane.inventory = "player-inv"
lootPane.inventory = "loot-inv"
focusTarget = invPage

-- Cursor na MOCHILA (grid não-ativo do inv), foco no inv.
GJP.cursors[0] = {
    container = "backpack", gridIndex = 1, grid = backpackGrid,
    col = 3, row = 2
}
-- O render do PAINEL DE LOOT (grid do chão e do loot) roda todo frame:
H.ok(GJP.isCursorOn(floorGrid) == false, "isCursorOn no grid do outro painel = false")
H.ok(GJP.isCursorOn(lootGrid) == false, "isCursorOn no loot = false (foco no inv)")
cur = GJP.cursors[0]
H.ok(cur.grid == backpackGrid and cur.col == 3 and cur.row == 2,
    "render do outro painel NÃO sequestra o cursor da mochila")
-- E o render do MESMO painel continua certo:
H.ok(GJP.isCursorOn(backpackGrid) == true, "isCursorOn na mochila (foco inv) = true")
H.ok(GJP.isCursorOn(playerInvGrid) == false, "isCursorOn no grid do container ativo = false (cursor na mochila)")

-- isCursorVisible: usado pelo tooltip pra suprimir o tooltip do mouse quando o
-- cursor virtual está ativo no painel focado.
focusTarget = invPage
H.ok(GJP.isCursorVisible(0) == true, "isCursorVisible: cursor na mochila com foco no inv = true")
focusTarget = lootPage
H.ok(GJP.isCursorVisible(0) == false, "isCursorVisible: cursor no inv mas foco no loot = false")
GJP.cursors = {}
H.ok(GJP.isCursorVisible(0) == false, "isCursorVisible: sem cursor = false")

-- Caso contrário: cursor no LOOT (ativo), foco no loot; render do INV não rouba.
focusTarget = lootPage
GJP.cursors[0] = {
    container = "loot-inv", gridIndex = 1, grid = lootGrid,
    col = 2, row = 1
}
H.ok(GJP.isCursorOn(playerInvGrid) == false, "isCursorOn no inv = false (foco no loot)")
cur = GJP.cursors[0]
H.ok(cur.grid == lootGrid and cur.col == 2, "render do inv NÃO sequestra o cursor do loot")

-- ---------------------------------------------------------------------------
-- shoulderCycle (re-press do LB/RB): fora do painel alvo troca o foco; JÁ no
-- painel alvo cicla pro próximo container e re-ancora o cursor nele. Fix do
-- "RB/LB travado" — o re-press não fica mais preso re-anchorando o cursor em
-- (1,1) do MESMO container, e o cursor consegue alcançar as outras grids.
-- ---------------------------------------------------------------------------
resetPanes()
local lootBagGrid = makeGrid("loot-bag", "loot-bag", 2, 2, 15, 260)
addGridToPane(invPane, playerInvGrid)
addGridToPane(invPane, backpackGrid)
addGridToPane(lootPane, floorGrid)
addGridToPane(lootPane, lootGrid)
addGridToPane(lootPane, lootBagGrid)
playerInvGrid.baseX = 485
backpackGrid.baseX = 250
floorGrid.baseX = 15
lootGrid.baseX = 290
lootBagGrid.baseX = 15
invPane.inventory = "player-inv"
lootPane.inventory = "loot-inv"

-- Fora do painel alvo: LB (de loot) troca o foco pro inv, cursor em (1,1).
GJP.cursors[0] = {
    container = "loot-inv", gridIndex = 1, grid = lootGrid,
    col = 2, row = 3
}
GJP.shoulderCycle(0, lootPage, invPage)
cur = GJP.cursors[0]
H.ok(focusTarget == invPage, "shoulderCycle (fora) LB troca o foco pro inv")
H.ok(cur.grid == playerInvGrid and cur.col == 1 and cur.row == 1, "shoulderCycle (fora) ancora em (1,1) do inv")

-- Já no painel alvo: re-press do RB no loot cicla pro próximo container e
-- re-ancora o cursor em (1,1) dele (não fica preso em (1,1) do mesmo grid).
focusTarget = lootPage
GJP.cursors[0] = {
    container = "loot-inv", gridIndex = 1, grid = lootGrid,
    col = 2, row = 3
}
GJP.shoulderCycle(0, lootPage, lootPage)
cur = GJP.cursors[0]
H.ok(focusTarget == lootPage, "shoulderCycle (re-press) mantém o foco no loot")
H.ok(cur.grid == lootBagGrid and cur.col == 1 and cur.row == 1, "shoulderCycle (re-press) cicla pro próximo container e ancora em (1,1)")

-- Re-press do RB de novo: volta pro primeiro container do loot.
GJP.shoulderCycle(0, lootPage, lootPage)
cur = GJP.cursors[0]
H.ok(cur.grid == lootGrid and cur.col == 1 and cur.row == 1, "shoulderCycle (re-press 2) volta pro primeiro container do loot")

-- Já no painel alvo no inv: re-press do LB cicla de player-inv pra bolsa.
focusTarget = invPage
GJP.cursors[0] = {
    container = "player-inv", gridIndex = 1, grid = playerInvGrid,
    col = 2, row = 3
}
GJP.shoulderCycle(0, invPage, invPage)
cur = GJP.cursors[0]
H.ok(focusTarget == invPage, "shoulderCycle (re-press) no inv mantém o foco no inv")
H.ok(cur.grid == backpackGrid and cur.col == 1 and cur.row == 1, "shoulderCycle (re-press) no inv cicla pra bolsa em (1,1)")

-- Fora do painel alvo no sentido oposto: RB (de inv) troca o foco pro loot.
GJP.shoulderCycle(0, invPage, lootPage)
cur = GJP.cursors[0]
H.ok(focusTarget == lootPage, "shoulderCycle (fora) RB troca o foco pro loot")
H.ok(cur.grid == lootGrid and cur.col == 1 and cur.row == 1, "shoulderCycle (fora) ancora em (1,1) do loot")

-- ---------------------------------------------------------------------------
-- MODO NAVEGAÇÃO (RB segurado): stubs de tempo e joypad pro pollNav.
-- ---------------------------------------------------------------------------
local fakeNow = 0
function _G.getTimestampMs()
    return fakeNow
end
local rbHeld = false
local lbHeld = false
_G.JoypadButton = {
    RightBump = { isDown = function() return rbHeld end },
    LeftBump  = { isDown = function() return lbHeld end },
}
function _G.getJoypadData(playerNum)
    return { id = 1 }
end

resetPanes()
addGridToPane(invPane, playerInvGrid)
addGridToPane(invPane, backpackGrid)
playerInvGrid.baseX = 485
backpackGrid.baseX = 250
GJP.cursors[0] = {
    container = "player-inv", gridIndex = 1, grid = playerInvGrid,
    col = 1, row = 1
}
focusTarget = invPage -- o painel precisa ter foco pro pollNav gerenciar o modo

-- RB segurado < 250ms: modo NÃO ativa (é o tap que troca inv<->loot).
fakeNow = 0
rbHeld = true
GJP.pollNav(0, invPage)
H.ok(not GJP.isNavActive(0), "pollNav: RB segurado <250ms não ativa o modo")
-- >250ms: ativa (RB = loot, então o foco vai pro loot).
fakeNow = 300
GJP.pollNav(0, invPage)
H.ok(GJP.isNavActive(0), "pollNav: RB segurado >=250ms ativa o modo")
H.ok(focusTarget == lootPage, "pollNav: hold do RB força o foco pro loot (RB = loot)")
-- Soltou o RB: confirma posição e encerra (o foco agora está no loot).
rbHeld = false
fakeNow = 500
GJP.pollNav(0, lootPage)
H.ok(not GJP.isNavActive(0), "pollNav: soltar o RB encerra o modo (posição confirmada)")
-- RB solto desde o início: nada acontece.
GJP.pollNav(0, lootPage)
H.ok(not GJP.isNavActive(0), "pollNav: RB solto mantém o modo desativado")

-- ---------------------------------------------------------------------------
-- TAP vs HOLD (fix do "segurar RB pra navegar já troca/cicla o container"):
-- o tap (apertar/soltar rápido, < NAV_HOLD_MS) roda a ação de troca/ciclo no
-- SOLTAR; o hold (>= NAV_HOLD_MS) ativa o modo navegação no painel atual e o
-- release NÃO roda a ação.
-- ---------------------------------------------------------------------------
resetPanes()
addGridToPane(invPane, playerInvGrid)
addGridToPane(invPane, backpackGrid)
addGridToPane(lootPane, floorGrid)
addGridToPane(lootPane, lootGrid)
addGridToPane(lootPane, lootBagGrid)
playerInvGrid.baseX = 485
backpackGrid.baseX = 250
floorGrid.baseX = 15
lootGrid.baseX = 290
lootBagGrid.baseX = 15
invPane.inventory = "player-inv"
lootPane.inventory = "loot-inv"

-- TAP do RB no inv: soltar rápido dispara o switch pro loot (no release).
focusTarget = invPage
GJP.cursors[0] = {
    container = "player-inv", gridIndex = 1, grid = playerInvGrid,
    col = 2, row = 2
}
rbHeld, lbHeld = true, false
fakeNow = 0
GJP.pollNav(0, invPage) -- aperto: pending="RB", nada ainda
H.ok(not GJP.isNavActive(0) and focusTarget == invPage, "tap RB: durante o aperto não troca nem ativa o modo")
rbHeld = false
fakeNow = 10
GJP.pollNav(0, invPage) -- release rápido: roda o switch pro loot
H.ok(focusTarget == lootPage, "tap RB: no soltar, switch pro loot")
H.ok(not GJP.isNavActive(0), "tap RB: não ativa o modo")

-- HOLD do RB no inv: segura >=250ms ativa o nav; como RB = LOOT, o foco vai
-- pro loot (switchFocus home) e o release NÃO roda a ação de tap.
focusTarget = invPage
rbHeld = true
fakeNow = 100
GJP.pollNav(0, invPage)
fakeNow = 400
GJP.pollNav(0, invPage)
H.ok(GJP.isNavActive(0), "hold RB: segurar >=250ms ativa o modo")
H.ok(focusTarget == lootPage, "hold RB: força o foco pro LOOT (RB = loot)")
rbHeld = false
fakeNow = 500
GJP.pollNav(0, lootPage) -- foco agora no loot: o release é detectado aqui
H.ok(not GJP.isNavActive(0), "hold RB: release encerra o modo")
H.ok(focusTarget == lootPage, "hold RB: release NÃO roda a ação de tap (sem switch de novo)")

-- HOLD do LB no inv: LB = INV, já está no inv — sem troca de foco.
focusTarget = invPage
lbHeld = true
fakeNow = 600
GJP.pollNav(0, invPage)
fakeNow = 900
GJP.pollNav(0, invPage)
H.ok(GJP.isNavActive(0), "hold LB: segurar LB >=250ms ativa o modo")
H.ok(focusTarget == invPage, "hold LB no inv: foco permanece no inv (LB = inv)")
lbHeld = false
fakeNow = 1000
GJP.pollNav(0, invPage)
H.ok(not GJP.isNavActive(0), "hold LB: release encerra o modo sem tap")

-- HOLD do LB no LOOT: LB = INV, força o foco pro inv.
focusTarget = lootPage
lbHeld = true
fakeNow = 1100
GJP.pollNav(0, lootPage)
fakeNow = 1400
GJP.pollNav(0, lootPage)
H.ok(GJP.isNavActive(0), "hold LB no loot: ativa o modo")
H.ok(focusTarget == invPage, "hold LB no loot: força o foco pro INV (LB = inv)")
lbHeld = false
fakeNow = 1500
GJP.pollNav(0, invPage) -- foco agora no inv: o release é detectado aqui
H.ok(not GJP.isNavActive(0), "hold LB no loot: release encerra o modo sem tap")

-- TAP do LB no loot: soltar rápido troca o foco pro inv.
focusTarget = lootPage
lbHeld = true
fakeNow = 1600
GJP.pollNav(0, lootPage)
lbHeld = false
fakeNow = 1610
GJP.pollNav(0, lootPage)
H.ok(focusTarget == invPage, "tap LB no loot: soltar troca o foco pro inv")

-- ---------------------------------------------------------------------------
-- navDir: D-pad durante o modo navegação.
-- ---------------------------------------------------------------------------
resetPanes()
addGridToPane(invPane, playerInvGrid)
addGridToPane(invPane, backpackGrid)
addGridToPane(lootPane, floorGrid)
addGridToPane(lootPane, lootGrid)
playerInvGrid.baseX = 485
backpackGrid.baseX = 250
floorGrid.baseX = 15
lootGrid.baseX = 290

-- Ativa o modo direto (sem passar pelo timing do pollNav).
GJP.navFor(0).active = true
invPane.inventory = "player-inv"

-- Esquerda na borda do inv principal: salta pra bolsa (vizinho do painel).
GJP.cursors[0] = {
    container = "player-inv", gridIndex = 1, grid = playerInvGrid,
    col = 1, row = 1
}
local okNav = GJP.navDir(0, invPage, -1, 0)
cur = GJP.cursors[0]
H.ok(okNav, "navDir(-1,0) na borda do inv principal retorna true")
H.ok(cur.grid == backpackGrid, "navDir salta pra bolsa (vizinho esquerdo)")
H.ok(cur.col == 1 and cur.row == 1, "nav posiciona o cursor em (1,1) do grid alvo")
H.ok(focusTarget == nil, "navDir dentro do painel NÃO troca o foco")
H.ok(invPane.inventory == "backpack", "nav torna a bolsa o container SELECIONADO")

-- Esquerda na borda ESQUERDA da bolsa: sem vizinho no painel -> painel oposto
-- (loot), SEM wrap. Entra em (1,1) do container ativo do loot (nav).
GJP.cursors[0] = {
    container = "backpack", gridIndex = 1, grid = backpackGrid,
    col = 1, row = 1
}
okNav = GJP.navDir(0, invPage, -1, 0)
cur = GJP.cursors[0]
H.ok(okNav, "navDir(-1,0) na borda esquerda da bolsa retorna true")
H.ok(focusTarget == lootPage, "navDir sem vizinho horizontal troca pro painel oposto (loot)")
H.ok(cur.grid == lootGrid and cur.col == 1 and cur.row == 1, "nav cruzando painel entra em (1,1) do loot")

-- Cima na borda de CIMA de um grid SEM vizinho acima: NO-WRAP (modo nav não
-- dá wrap vertical — o cursor simplesmente não se move).
GJP.navFor(0).active = true
GJP.cursors[0] = {
    container = "player-inv", gridIndex = 1, grid = playerInvGrid,
    col = 2, row = 1
}
local beforeCol, beforeRow = GJP.cursors[0].col, GJP.cursors[0].row
okNav = GJP.navDir(0, invPage, 0, -1)
cur = GJP.cursors[0]
H.ok(not okNav, "navDir(0,-1) sem vizinho acima retorna false (sem wrap)")
H.ok(cur.col == beforeCol and cur.row == beforeRow, "navDir vertical sem vizinho não move o cursor")

-- Baixo na borda de BAIXO: o grid vizinho NA LINHA DE BAIXO existe (wrap do
-- flexbox) -> salta pra bolsa mesmo em outra linha.
GJP.cursors[0] = {
    container = "player-inv", gridIndex = 1, grid = playerInvGrid,
    col = 2, row = 1
}
-- A bolsa precisa estar na linha de baixo pra testar (flexbox wrap).
GJP.cursors[0].grid.baseY = 15
backpackGrid.baseY = 260
H.ok(GJP.findNeighbor(playerInvGrid, 0, 1) == backpackGrid,
    "navDir: pré-condição — bolsa na linha de baixo é vizinho de baixo")
okNav = GJP.navDir(0, invPage, 0, 1)
cur = GJP.cursors[0]
H.ok(okNav, "navDir(0,1) com vizinho na linha de baixo retorna true")
H.ok(cur.grid == backpackGrid, "navDir desce pra bolsa na linha de baixo")
H.ok(cur.col == 1 and cur.row == 1, "nav desce pro grid e posiciona em (1,1)")

-- ---------------------------------------------------------------------------
-- navTargets: alvos do overlay por direção.
-- ---------------------------------------------------------------------------
resetPanes()
addGridToPane(invPane, playerInvGrid)
addGridToPane(invPane, backpackGrid)
addGridToPane(lootPane, floorGrid)
addGridToPane(lootPane, lootGrid)
playerInvGrid.baseX = 485
backpackGrid.baseX = 250
floorGrid.baseX = 15
lootGrid.baseX = 290
playerInvGrid.baseY = 15
backpackGrid.baseY = 15
floorGrid.baseY = 15
lootGrid.baseY = 15

GJP.cursors[0] = {
    container = "player-inv", gridIndex = 1, grid = playerInvGrid,
    col = 1, row = 1
}
local targets = GJP.navTargets(0, invPage)
H.ok(targets and targets.left == backpackGrid, "navTargets: left = bolsa (vizinho)")
H.ok(targets and targets.right == lootGrid, "navTargets: right = loot (painel oposto, grid ativo)")
H.ok(targets and targets.up == nil, "navTargets: up sem vizinho = nil (sem wrap)")
H.ok(targets and targets.down == nil, "navTargets: down sem vizinho = nil (sem wrap)")

-- Da bolsa: esquerda sem vizinho no painel -> painel oposto (loot).
GJP.cursors[0] = {
    container = "backpack", gridIndex = 1, grid = backpackGrid,
    col = 1, row = 1
}
targets = GJP.navTargets(0, invPage)
H.ok(targets and targets.left == lootGrid, "navTargets: left da bolsa = loot (painel oposto)")
H.ok(targets and targets.right == playerInvGrid, "navTargets: right da bolsa = inv principal (vizinho)")

-- ---------------------------------------------------------------------------
-- PAPERDOLL (LB+RB segurados): entra no modo de navegação por slots, D-pad
-- navega entre eles e LB/RB saem (LB -> INV, RB -> LOOT).
-- ---------------------------------------------------------------------------
local function makePdSlot(col, idx, name)
    local s = {
        name = name, _pdCol = col, _pdIndex = idx,
        _visible = true, joySelected = false,
        _x = 0, _y = 0,
    }
    function s:getIsVisible() return self._visible end
    function s:getWidth() return 50 end
    function s:getHeight() return 50 end
    function s:getX() return self._x end
    function s:getY() return self._y end
    function s:setX(v) self._x = v end
    function s:setY(v) self._y = v end
    function s:getAbsoluteX() return 100 end
    function s:getAbsoluteY() return 100 end
    return s
end
local pdSlots = {}
for i = 1, 5 do
    table.insert(pdSlots, makePdSlot("left", i, "left" .. i))
end
for i = 1, 5 do
    table.insert(pdSlots, makePdSlot("right", i, "right" .. i))
end
table.insert(pdSlots, makePdSlot("bag", 1, "bag"))
table.insert(pdSlots, makePdSlot("overflow", 1, "overflow"))
table.insert(pdSlots, makePdSlot("primary", 1, "primary"))
table.insert(pdSlots, makePdSlot("secondary", 1, "secondary"))
local twoHandSlot = makePdSlot("twohand", 1, "twohand")
twoHandSlot._visible = false
table.insert(pdSlots, twoHandSlot)
local function pdGet(col, idx)
    for _, s in ipairs(pdSlots) do
        if s._pdCol == col and (s._pdIndex or 1) == idx then return s end
    end
end
-- Posições das mãos (pro "mais próximo no X" com a hotbar).
pdGet("primary", 1)._x = 80
pdGet("secondary", 1)._x = 200
-- Hotbar: duas linhas, agrupadas por getY e ordenadas por getX.
local hb1 = makePdSlot("hotbar", 0, "hb1")
hb1._x, hb1._y = 100, 300
local hb2 = makePdSlot("hotbar", 0, "hb2")
hb2._x, hb2._y = 170, 300
local hb3 = makePdSlot("hotbar", 0, "hb3")
hb3._x, hb3._y = 120, 380
local hb4 = makePdSlot("hotbar", 0, "hb4")
hb4._x, hb4._y = 190, 380
local avatarDropZone = {
    _pdCol = "avatar", _pdIndex = 1, _visible = true, joySelected = false,
    _x = 140, _w = 200,
}
function avatarDropZone:getIsVisible() return self._visible end
function avatarDropZone:getX() return self._x end
function avatarDropZone:getWidth() return self._w end
local pdWin = { playerNum = 0, slots = pdSlots, hotbarUis = { hb1, hb2, hb3, hb4 },
    avatarDropZone = avatarDropZone, _visible = true }
function pdWin:getIsVisible() return self._visible end
_G.GridInventory_PaperDollWindow = { [0] = pdWin }

-- Entrada via LB+RB (pollNav detecta os dois juntos).
resetPanes()
focusTarget = invPage
GJP.pds = {}
GJP.navs = {}
rbHeld, lbHeld = true, true
fakeNow = 0
GJP.pollNav(0, invPage)
H.ok(GJP.isPaperdollActive(0), "pollNav: LB+RB juntos ativa o modo PaperDoll")
H.ok(GJP.pdSelectedSlot(0) == pdGet("left", 1), "entra selecionando o left[1]")
-- Solta os dois: o modo permanece (não sai, não roda tap).
rbHeld, lbHeld = false, false
fakeNow = 10
GJP.pollNav(0, invPage)
H.ok(GJP.isPaperdollActive(0), "soltar LB+RB mantém o modo PaperDoll")

-- isCursorOn esconde o cursor das grids durante o PaperDoll.
GJP.cursors[0] = {
    container = "player-inv", gridIndex = 1, grid = playerInvGrid,
    col = 1, row = 1
}
H.ok(GJP.isCursorOn(playerInvGrid) == false, "cursor das grids escondido no modo PaperDoll")

-- Navegação (pdDir): o AVATAR fica no centro — left[i] -> avatar -> right[i].
H.ok(GJP.pdDir(0, 1, 0), "pdDir direita move")
H.ok(GJP.pdSelectedSlot(0) == avatarDropZone, "left[1] -> avatar (centro)")
H.ok(GJP.pdDir(0, 1, 0), "avatar -> direita")
H.ok(GJP.pdSelectedSlot(0) == pdGet("right", 3), "avatar -> right[3] (meio)")
H.ok(not GJP.pdDir(0, 1, 0), "borda direita do right[3]: não move")
H.ok(GJP.pdDir(0, 0, 1), "pdDir baixo move")
H.ok(GJP.pdSelectedSlot(0) == pdGet("right", 4), "right[3] -> right[4]")
H.ok(GJP.pdDir(0, 0, -1), "pdDir cima move")
H.ok(GJP.pdSelectedSlot(0) == pdGet("right", 3), "right[4] -> right[3]")
H.ok(GJP.pdDir(0, -1, 0), "pdDir esquerda move")
H.ok(GJP.pdSelectedSlot(0) == avatarDropZone, "right[3] -> avatar (centro)")
H.ok(GJP.pdDir(0, -1, 0), "avatar -> esquerda")
H.ok(GJP.pdSelectedSlot(0) == pdGet("left", 3), "avatar -> left[3]")
H.ok(not GJP.pdDir(0, -1, 0), "borda esquerda do left[3]: não move")
-- Caminho até a bag (left[5] -> bag), bag -> avatar -> right (volta ao centro),
-- e overflow -> avatar.
GJP.pds[0].slot = pdGet("left", 5)
H.ok(GJP.pdDir(0, 0, 1), "left[5] -> bag (baixo)")
H.ok(GJP.pdSelectedSlot(0) == pdGet("bag", 1), "left[5] -> bag")
H.ok(GJP.pdDir(0, 1, 0), "bag -> avatar (direita)")
H.ok(GJP.pdSelectedSlot(0) == avatarDropZone, "bag -> avatar")
H.ok(GJP.pdDir(0, 1, 0), "avatar -> right (direita)")
H.ok(GJP.pdSelectedSlot(0) == pdGet("right", 3), "avatar -> right[3]")
H.ok(GJP.pdDir(0, 0, 1), "right[3] -> right[4] (baixo)")
H.ok(GJP.pdSelectedSlot(0) == pdGet("right", 4), "right[3] -> right[4]")
H.ok(GJP.pdDir(0, 0, 1), "right[4] -> right[5] (baixo)")
H.ok(GJP.pdSelectedSlot(0) == pdGet("right", 5), "right[4] -> right[5]")
H.ok(GJP.pdDir(0, 0, 1), "right[5] -> overflow (baixo)")
H.ok(GJP.pdSelectedSlot(0) == pdGet("overflow", 1), "right[5] -> overflow")
H.ok(GJP.pdDir(0, -1, 0), "overflow -> avatar (esquerda)")
H.ok(GJP.pdSelectedSlot(0) == avatarDropZone, "overflow -> avatar")
H.ok(GJP.pdDir(0, 0, 1), "avatar -> primary (baixo)")
H.ok(GJP.pdSelectedSlot(0) == pdGet("primary", 1), "avatar -> primary")

-- Alvos do overlay (pdTarget) sem mover a seleção.
GJP.pds[0].slot = pdGet("left", 3)
H.ok(GJP.pdTarget(0, 1, 0) == avatarDropZone, "pdTarget direita do left[3] = avatar (centro)")
H.ok(GJP.pdTarget(0, -1, 0) == nil, "pdTarget esquerda do left[3] = nil (borda)")
H.ok(GJP.pdTarget(0, 0, 1) == pdGet("left", 4), "pdTarget baixo do left[3] = left[4]")
H.ok(GJP.pdSelectedSlot(0) == pdGet("left", 3), "pdTarget não move a seleção")

-- AVATAR (retângulo de eat/read/drink/pill): alvo navegável no centro do
-- paperdoll, entre as colunas left/right. Dele desce pro hotbar.
GJP.pds[0].slot = pdGet("left", 3)
H.ok(GJP.pdDir(0, 1, 0), "left[3] -> avatar (direita)")
H.ok(GJP.pdSelectedSlot(0) == avatarDropZone, "left[3] -> avatar")
H.ok(GJP.pdDir(0, -1, 0), "avatar -> left (esquerda)")
H.ok(GJP.pdSelectedSlot(0) == pdGet("left", 3), "avatar -> left[3]")
H.ok(GJP.pdDir(0, 1, 0), "left[3] -> avatar de novo")
H.ok(GJP.pdSelectedSlot(0) == avatarDropZone, "avatar de novo")
H.ok(GJP.pdDir(0, 1, 0), "avatar -> right (direita)")
H.ok(GJP.pdSelectedSlot(0) == pdGet("right", 3), "avatar -> right[3]")

-- Navegação até a HOTBAR (debaixo das mãos).
GJP.pds[0].slot = pdGet("secondary", 1) -- centro X = 225
H.ok(GJP.pdDir(0, 0, 1), "secondary desce pra hotbar")
H.ok(GJP.pdSelectedSlot(0) == hb2, "secondary -> hb2 (mais próximo na 1ª linha)")
H.ok(GJP.pdDir(0, -1, 0), "hotbar esquerda move")
H.ok(GJP.pdSelectedSlot(0) == hb1, "hb2 -> hb1")
H.ok(GJP.pdDir(0, 0, 1), "hotbar desce de linha")
H.ok(GJP.pdSelectedSlot(0) == hb3, "hb1 -> hb3 (mesma coluna, 2ª linha)")
H.ok(GJP.pdDir(0, 1, 0), "hotbar direita move")
H.ok(GJP.pdSelectedSlot(0) == hb4, "hb3 -> hb4")
H.ok(not GJP.pdDir(0, 1, 0), "borda direita da hotbar: não move")
H.ok(not GJP.pdDir(0, 0, 1), "borda inferior da hotbar: não move")
H.ok(GJP.pdDir(0, 0, -1), "hotbar sobe de linha")
H.ok(GJP.pdSelectedSlot(0) == hb2, "hb4 -> hb2 (mesma coluna, 1ª linha)")
-- Sobe da 1ª linha da hotbar pras mãos (mais próximo no X).
GJP.pds[0].slot = hb1 -- centro X = 125
H.ok(GJP.pdDir(0, 0, -1), "hb1 sobe pro primaryHand")
H.ok(GJP.pdSelectedSlot(0) == pdGet("primary", 1), "hb1 -> primary")
GJP.pds[0].slot = hb2 -- centro X = 195
H.ok(GJP.pdDir(0, 0, -1), "hb2 sobe pro primaryHand")
H.ok(GJP.pdSelectedSlot(0) == pdGet("primary", 1), "hb2 -> primary")

-- Saída via pollNav (release): com os DOIS bumpers soltos (pdArmed), segura LB
-- sozinho e solta -> sai pro INV, sem disparar tap/ciclo depois.
focusTarget = invPage
GJP.pds[0].slot = pdGet("left", 3)
lbHeld, rbHeld = false, false
fakeNow = 1980
GJP.pollNav(0, invPage) -- ambos soltos: arma a saída (pdArmed)
lbHeld, rbHeld = true, false
fakeNow = 2000
GJP.pollNav(0, invPage) -- LB sozinho no PaperDoll: aguarda o release
H.ok(GJP.isPaperdollActive(0), "LB segurado no PaperDoll: ainda não saiu (release)")
lbHeld = false
fakeNow = 2010
GJP.pollNav(0, invPage) -- release: sai pro INV
H.ok(not GJP.isPaperdollActive(0), "soltar LB sai do modo PaperDoll")
H.ok(focusTarget == invPage, "sair pelo LB volta o foco pro INV")
H.ok(pdGet("left", 3).joySelected == false, "limpa o destaque do slot ao sair")
-- O release que saiu NÃO deve disparar um tap de LB (sem ciclar o inv).
fakeNow = 2020
GJP.pollNav(0, invPage)
H.ok(focusTarget == invPage, "release da saída não dispara tap/ciclo")

-- Sair por um bumper sozinho SEM armar (pdArmed) NÃO sai — soltar o combo de
-- entrada em sequência não pode fechar o paperdoll na hora.
GJP.enterPaperdoll(0)
lbHeld, rbHeld = true, false
fakeNow = 2040
GJP.pollNav(0, invPage)
lbHeld = false
fakeNow = 2050
GJP.pollNav(0, invPage)
H.ok(GJP.isPaperdollActive(0), "release do combo de entrada (sem armar) NÃO sai")
GJP.exitPaperdoll(0, invPage, "inv")

-- Saída via pollNav (release): segura RB sozinho e solta -> sai pro LOOT.
focusTarget = invPage
GJP.enterPaperdoll(0)
lbHeld, rbHeld = false, false
fakeNow = 2060
GJP.pollNav(0, invPage) -- arma a saída
rbHeld, lbHeld = true, false
fakeNow = 2100
GJP.pollNav(0, invPage)
rbHeld = false
fakeNow = 2110
GJP.pollNav(0, invPage)
H.ok(not GJP.isPaperdollActive(0), "soltar RB sai do modo PaperDoll")
H.ok(focusTarget == lootPage, "sair pelo RB volta o foco pro LOOT")

-- Saída direta (função) também funciona: LB -> INV.
focusTarget = lootPage
GJP.enterPaperdoll(0)
GJP.exitPaperdoll(0, invPage, "inv")
H.ok(not GJP.isPaperdollActive(0), "exitPaperdoll(inv) sai do modo")
H.ok(focusTarget == invPage, "exitPaperdoll(inv) volta o foco pro INV")

-- Sem janela visível: enterPaperdoll não ativa.
GJP.pds = {}
pdWin._visible = false
H.ok(not GJP.enterPaperdoll(0), "com PaperDoll oculto, LB+RB não ativa o modo")
pdWin._visible = true

-- ---------------------------------------------------------------------------
-- DRAG de joypad: A = pegar/soltar (place), B = cancelar (ou contexto), X =
-- rotaciona. Reusa GridInventory_GlobalDrag com `joypad=true` e ISMouseDrag.
-- ---------------------------------------------------------------------------
_G.JoypadState = { disableGrab = false, disableInvInteraction = false, disableYInventory = false }
_G.ISMouseDrag = {}
local dgGrid = makeGrid("dg", "dg", 6, 4, 15, 15)
local dgCells = {}
dgCells[2] = dgCells[2] or {}
dgCells[2][2] = "itemA"
dgGrid.gridCore.cells = dgCells
dgGrid.gridCore.items = { itemA = { x = 2, y = 2, w = 1, h = 1, itemObj = {} } }
local dgDropped = false
local dgHadDragState = false
function dgGrid:isLocked() return false end
function dgGrid:onMouseUp(x, y)
    dgDropped = true
    dgHadDragState = (ISMouseDrag.dragging ~= nil and #ISMouseDrag.dragging == 1)
    GridInventory_GlobalDrag = nil
    ISMouseDrag.dragging = nil
    ISMouseDrag.draggingFocus = nil
end
function dgGrid:performGridReorder(targets)
    dgDropped = true
end
dgGrid.gridCore.canPlaceItem = function() return true end
resetPanes()
GJP.drag = { active = false, playerNum = nil }
GridInventory_GlobalDrag = nil
ISMouseDrag = {}
addGridToPane(lootPane, dgGrid)
GJP.cursors[0] = {
    container = "dg", gridIndex = 1, grid = dgGrid,
    col = 2, row = 2
}

-- A pega o item (inicia o drag).
fakeNow = 30000
GJP.grab(0, lootPage)
H.ok(GJP.isDragging(0), "A inicia o drag (item preso no cursor)")
H.ok(GridInventory_GlobalDrag ~= nil and GridInventory_GlobalDrag.joypad == true, "GlobalDrag com joypad=true")
H.ok(GridInventory_GlobalDrag.sourceGrid == dgGrid, "sourceGrid = grid do item")
H.ok(ISMouseDrag.dragging == nil, "grab NÃO seta ISMouseDrag (senão o vanilla autocoloca no frame seguinte)")

-- Double-fire do A no MESMO instante NÃO solta (guarda anti double-fire).
fakeNow = 30010
GJP.grab(0, lootPage)
H.ok(GJP.isDragging(0), "double-fire do A no mesmo instante não solta o item")
H.ok(not dgDropped, "double-fire do A não chama place")

-- X rotaciona o item arrastado.
GJP.rotate(0, lootPage)
H.ok(GridInventory_GlobalDrag.itemsData[1].rotated == true, "X rotaciona o item arrastado")
GJP.rotate(0, lootPage)
H.ok(GridInventory_GlobalDrag.itemsData[1].rotated == false, "X de novo desrotaciona")

-- A solta (place) na célula do cursor — SÓ depois de o cursor ter MOVIDO
-- (hasMoved). No MESMO grid usa o reorder direto (GridReorder) → performGridReorder.
-- (No harness o GridSandboxOptions/timed não existem → cai no instantâneo.)
GJP.drag.hasMoved = true
GJP.cursors[0].col = 3
GJP.cursors[0].row = 1
fakeNow = 30300
GJP.grab(0, lootPage)
H.ok(dgDropped, "A solta o item (reorder no mesmo grid chama performGridReorder)")
H.ok(not GJP.isDragging(0), "após soltar, o drag termina")

-- Novo drag + B cancela (item volta pra origem).
dgDropped = false
GJP.cursors[0] = {
    container = "dg", gridIndex = 1, grid = dgGrid,
    col = 2, row = 2
}
fakeNow = 30400
GJP.grab(0, lootPage)
H.ok(GJP.isDragging(0), "A pega de novo")
GJP.activateB(0, lootPage)
H.ok(not GJP.isDragging(0), "B cancela o drag")
H.ok(GridInventory_GlobalDrag == nil, "B cancela limpa o GlobalDrag")
H.ok(not dgDropped, "B cancela NÃO solta o item")

-- cancelDrag direto também limpa.
fakeNow = 30500
GJP.grab(0, lootPage)
GJP.cancelDrag(0)
H.ok(not GJP.isDragging(0) and GridInventory_GlobalDrag == nil, "cancelDrag limpa o estado")

-- Grabbing em célula vazia não inicia drag.
GJP.cursors[0] = {
    container = "dg", gridIndex = 1, grid = dgGrid,
    col = 5, row = 3
}
GJP.grab(0, lootPage)
H.ok(not GJP.isDragging(0), "A em célula vazia não inicia drag")

-- ---------------------------------------------------------------------------
-- PAPERDOLL EQUIP via drag (pdActivate): com um item arrastado e o paperdoll
-- ativo, A equipa o item no slot selecionado e encerra o drag.
-- ---------------------------------------------------------------------------
local pdEquipped = nil
pdGet("left", 1).joypadEquip = function(self, itemObj)
    pdEquipped = itemObj
    return true
end
GJP.pds = {}
GJP.drag = { active = true, playerNum = 0, hasMoved = true }
GJP.enterPaperdoll(0)
GJP.pds[0].slot = pdGet("left", 1)
GridInventory_GlobalDrag = {
    itemsData = { { id = "itemA", itemObj = "HeldItem" } },
    itemsMap = { ["itemA"] = true },
    anchorId = "itemA",
    sourceGrid = dgGrid,
    joypad = true,
}
GJP.pdActivate(0)
H.ok(pdEquipped == "HeldItem", "A no slot do PaperDoll equipa o item arrastado")
H.ok(not GJP.isDragging(0), "equip encerra o drag")

-- ---------------------------------------------------------------------------
-- PILHA: A dinâmico (tap=1, tap repetido=+1, hold=todos) + Select (picker).
-- ---------------------------------------------------------------------------
local aHeld = false
_G.JoypadButton.A = { isDown = function() return aHeld end }

local stGrid = makeGrid("st", "st-inv", 4, 4, 15, 15)
local stCells = {}
stCells[2] = stCells[2] or {}
stCells[2][2] = "stackL"
stGrid.gridCore.cells = stCells
stGrid.gridCore.items = {
    stackL = { x = 2, y = 2, w = 1, h = 1, itemObj = {} },
    stackM1 = { x = 2, y = 2, w = 1, h = 1, itemObj = {} },
    stackM2 = { x = 2, y = 2, w = 1, h = 1, itemObj = {} },
}
stGrid.gridCore.getStackSize = function(self, id) return 3 end
stGrid.gridCore.getStackMembers = function(self, id)
    if id == "stackL" then return { "stackL", "stackM1", "stackM2" } end
    return { id }
end
function stGrid:isLocked() return false end
resetPanes()
addGridToPane(lootPane, stGrid)
GJP.cursors[0] = { container = "st-inv", gridIndex = 1, grid = stGrid, col = 2, row = 2 }
GJP.drag = { active = false, playerNum = nil }
GJP.aPress = { active = false, playerNum = nil }
GJP.picker = { playerNum = nil }
GridInventory_GlobalDrag = nil

-- A numa pilha NÃO pega na hora: registra o aPress (aguarda tap/hold).
fakeNow = 40000
aHeld = true
GJP.grab(0, lootPage)
H.ok(not GJP.isDragging(0), "A numa pilha não inicia o drag imediatamente")
H.ok(GJP.aPress.active == true, "A numa pilha registra o aPress (aguarda tap/hold)")

-- TAP: solta o A antes de 300ms → pega 1 membro (preserva o líder).
fakeNow = 40050
aHeld = false
GJP.pollA(0, lootPage)
H.ok(GJP.isDragging(0), "tap do A na pilha pega 1 item (inicia o drag)")
H.ok(GridInventory_GlobalDrag ~= nil and #GridInventory_GlobalDrag.itemsData == 1,
    "drag do tap tem exatamente 1 item ["
    .. tostring(GridInventory_GlobalDrag and #GridInventory_GlobalDrag.itemsData) .. "]")
H.ok(GridInventory_GlobalDrag.itemsMap["stackM1"] == true, "tap pega um MEMBRO (não o líder)")

-- +1: A (tap) de novo sobre a MESMA pilha acumula outro membro (NÃO o líder).
fakeNow = 40400
aHeld = true
GJP.grab(0, lootPage)
H.ok(GJP.aPress.active == true and GJP.aPress.mode == "add",
    "A com peel ativo registra o press (mode=add)")
fakeNow = 40450
aHeld = false
GJP.pollA(0, lootPage)
H.ok(GridInventory_GlobalDrag ~= nil and #GridInventory_GlobalDrag.itemsData == 2,
    "A de novo na mesma pilha acumula +1 ["
    .. tostring(GridInventory_GlobalDrag and #GridInventory_GlobalDrag.itemsData) .. "]")
H.ok(GridInventory_GlobalDrag.itemsMap["stackM2"] == true, "+1 pega outro MEMBRO (stackM2)")
H.ok(GridInventory_GlobalDrag.itemsMap["stackL"] ~= true, "+1 NÃO pega o líder (grid não some)")

-- HOLD com peel ativo (+2 já levantados): segura A → pega o RESTANTE (o líder).
fakeNow = 40500
aHeld = true
GJP.grab(0, lootPage)
fakeNow = 40850
GJP.pollA(0, lootPage)
H.ok(GridInventory_GlobalDrag ~= nil and #GridInventory_GlobalDrag.itemsData == 3,
    "hold com peel ativo pega o restante da pilha (3 itens) ["
    .. tostring(GridInventory_GlobalDrag and #GridInventory_GlobalDrag.itemsData) .. "]")
H.ok(GridInventory_GlobalDrag.itemsMap["stackL"] == true, "hold do restante inclui o líder")

-- HOLD: cancelar, segurar A >= 300ms → pega a pilha inteira.
GJP.cancelDrag(0)
GJP.aPress = { active = false, playerNum = nil }
GridInventory_GlobalDrag = nil
fakeNow = 41000
aHeld = true
GJP.grab(0, lootPage)
fakeNow = 41350
GJP.pollA(0, lootPage)
H.ok(GJP.isDragging(0) and GridInventory_GlobalDrag and #GridInventory_GlobalDrag.itemsData == 3,
    "hold do A pega a pilha inteira (3 itens)")
GJP.cancelDrag(0)

-- SELECT (Back): abre o stack picker sobre a pilha do cursor (posição da
-- célula do cursor VIRTUAL, não do mouse).
local pickerCall = nil
_G.GridInventory_openStackPicker = function(pn, grid, leaderId, viaJoypad, joyX, joyY)
    pickerCall = { pn = pn, leaderId = leaderId, viaJoypad = viaJoypad, joyX = joyX, joyY = joyY }
    _G.GridInventory_StackPicker = {
        [pn] = { getIsVisible = function() return true end, stackMode = {}, close = function() end },
    }
end
GJP.aPress = { active = false, playerNum = nil }
local opened = GJP.openStackPicker(0, lootPage)
H.ok(opened == true, "Select abre o stack picker sobre a pilha")
H.ok(pickerCall ~= nil and pickerCall.leaderId == "stackL" and pickerCall.viaJoypad == true,
    "openStackPicker passa o líder e viaJoypad=true")
H.ok(pickerCall ~= nil and pickerCall.joyX ~= nil and pickerCall.joyY ~= nil,
    "openStackPicker passa a posição do cursor virtual (joyX/joyY)")
H.ok(GJP.isPickerActive(0), "isPickerActive = true após abrir pelo controle")
GJP.closePicker(0)
H.ok(not GJP.isPickerActive(0), "closePicker desativa o picker")

H.finish()
