--- GridProfiler.lua (CLIENT)
--- Instrumentação leve de performance. Contadores acumulados por janela de
--- tempo (não por frame) e impressos no console a cada REPORT_MS quando ligado.
--- O toggle é via console: GridProfilerToggle()  /  GridProfilerOn()/Off().
---
--- Como medir ANTES/DEPOIS sem mudar o gameplay:
---   1) abra o inventário, fique parado sobre a mesma cena;
---   2) rode GridProfilerOn() e anote os números;
---   3) aplique a otimização, repita a cena idêntica e compare.
---
--- Contadores:
---   sandbox    — chamadas a GridSandboxOptions.* (cada uma = pcall + getOptionByName Java)
---   refresh    — chamadas a GridContainer:refresh() (remap completo O(n*W*H))
---   pageUpdate — corpo do ISInventoryPage:update executado (1 = 1 frame de layout)
---   gridRender — grids que rodaram render() no frame
---   items      — itens desenhados no frame
---   drawCalls  — operações de desenho (mesh + gradiente + border + badge + status)
---   syncItems  — SYNC_ITEM recebidos no cliente (MP)
---   reflows    — re-layouts disparados por SYNC_ITEM (antes: 1 por mensagem)

GridInventory_Profiler = GridInventory_Profiler or {}
local P = GridInventory_Profiler

P.enabled = false
P.counters = {
    sandbox = 0, refresh = 0, pageUpdate = 0, gridRender = 0,
    items = 0, drawCalls = 0, syncItems = 0, reflows = 0,
}

local lastReport = 0
local lastReset = 0

--- Conta um evento (incrementa o contador).
---@param kind string
function P.count(kind)
    if not P.enabled then return end
    P.counters[kind] = (P.counters[kind] or 0) + 1
end

--- Soma N operações de desenho de uma vez (evita chamar count() por draw).
---@param n number
function P.addDraw(n)
    if not P.enabled then return end
    P.counters.drawCalls = P.counters.drawCalls + n
end

--- Marca o início de um render de grid.
---@param gridW number
---@param gridH number
function P.renderGrid(gridW, gridH)
    if not P.enabled then return end
    P.counters.gridRender = P.counters.gridRender + 1
    P.counters.drawCalls = P.counters.drawCalls + (gridW * gridH)
end

local function resetCounters()
    P.counters.sandbox = 0
    P.counters.refresh = 0
    P.counters.pageUpdate = 0
    P.counters.gridRender = 0
    P.counters.items = 0
    P.counters.drawCalls = 0
    P.counters.syncItems = 0
    P.counters.reflows = 0
end

--- OnTick do profiling: reporta a cada REPORT_MS e zera a janela.
function P.OnTick()
    if not P.enabled then return end
    local now = getTimestampMs and getTimestampMs() or 0
    if now - lastReset >= P.reportMs then
        lastReset = now
        local dt = math.max(1, now - lastReport)
        local c = P.counters
        print(string.format(
            "[GridProfiler] %.1fs — sandbox %.0f/s | refresh %.1f/s | pageUpdate %.0f/s | "
            .. "grids %.0f/s | items %.0f/s | drawCalls %.0f/s | sync %.0f/s | reflows %.0f/s",
            dt / 1000,
            c.sandbox * 1000 / dt, c.refresh * 1000 / dt, c.pageUpdate * 1000 / dt,
            c.gridRender * 1000 / dt, c.items * 1000 / dt, c.drawCalls * 1000 / dt,
            c.syncItems * 1000 / dt, c.reflows * 1000 / dt))
        lastReport = now
        resetCounters()
    end
end

P.reportMs = 2000

function P.On()
    P.enabled = true
    lastReport = getTimestampMs and getTimestampMs() or 0
    lastReset = lastReport
    print("[GridProfiler] ligado (reporta a cada " .. tostring(P.reportMs) .. "ms)")
end

function P.Off()
    P.enabled = false
    print("[GridProfiler] desligado")
end

function P.Toggle()
    if P.enabled then P.Off() else P.On() end
end

-- Global de console (auto-loader idempotente).
_G.GridProfilerToggle = P.Toggle
_G.GridProfilerOn = P.On
_G.GridProfilerOff = P.Off

-- Registro único do OnTick.
if not P.registered then
    P.registered = true
    Events.OnTick.Add(P.OnTick)
end

return P
