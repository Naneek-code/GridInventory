--- GridOverrides.lua (SHARED)
--- Camada de DADOS do DevTool: a tabela de overrides (w/h de itens, cols/rows
--- de containers) + leitura/escrita do arquivo.
--- É carregada no CLIENTE e no SERVIDOR — o servidor usa EXATAMENTE os mesmos
--- overrides na validação autoritativa (GridContainer.getGridSize/validatePlacement).
--- A UI (painel de edição) fica no arquivo CLIENT-only UI/GridDevTool.lua.

GridDevTool = GridDevTool or {}
GridDevTool.Overrides = GridDevTool.Overrides or {}

function GridDevTool.loadOverrides()
    local reader = getFileReader("GridOverrides.ini", true)
    if not reader then return end

    local currentItem = nil
    local line = reader:readLine()
    while line do
        line = line:match("^%s*(.-)%s*$") -- Lua trim
        if line:sub(1, 1) == "[" and line:sub(-1) == "]" then
            currentItem = string.sub(line, 2, -2)
            GridDevTool.Overrides[currentItem] = GridDevTool.Overrides[currentItem] or {}
        elseif currentItem and string.find(line, "=") then
            local parts = string.split(line, "=")
            if #parts == 2 then
                local k = parts[1]:match("^%s*(.-)%s*$")
                local v = parts[2]:match("^%s*(.-)%s*$")
                if v == "true" then
                    GridDevTool.Overrides[currentItem][k] = true
                elseif v == "false" then
                    GridDevTool.Overrides[currentItem][k] = false
                else
                    local n = tonumber(v)
                    if n then
                        GridDevTool.Overrides[currentItem][k] = n
                    end
                end
            end
        end
        line = reader:readLine()
    end
    reader:close()
    print("[GridDevTool] Loaded overrides from GridOverrides.ini")
end

function GridDevTool.saveOverrides()
    local writer = getFileWriter("GridOverrides.ini", true, false)
    if not writer then return end

    for itemName, data in pairs(GridDevTool.Overrides) do
        writer:write("[" .. itemName .. "]\r\n")
        if data.w then writer:write("w=" .. tostring(data.w) .. "\r\n") end
        if data.h then writer:write("h=" .. tostring(data.h) .. "\r\n") end
        if data.cols then writer:write("cols=" .. tostring(data.cols) .. "\r\n") end
        if data.rows then writer:write("rows=" .. tostring(data.rows) .. "\r\n") end
        if data.angle then writer:write("angle=" .. tostring(data.angle) .. "\r\n") end
        if data.scale then writer:write("scale=" .. tostring(data.scale) .. "\r\n") end
        if data.anchorX then writer:write("anchorX=" .. tostring(data.anchorX) .. "\r\n") end
        if data.anchorY then writer:write("anchorY=" .. tostring(data.anchorY) .. "\r\n") end
        if data.maxStack then writer:write("maxStack=" .. tostring(data.maxStack) .. "\r\n") end
        if data.stackable ~= nil then writer:write("stackable=" .. tostring(data.stackable) .. "\r\n") end
        writer:write("\r\n")
    end
    writer:close()
    print("[GridDevTool] Saved overrides to GridOverrides.ini")
end

--- Lê um override individual (seguro).
function GridDevTool.getOverride(fullType, key)
    local o = GridDevTool.Overrides[fullType]
    return o and o[key] or nil
end

local function clampInt(v, maxV)
    local n = tonumber(v)
    if not n then return nil end
    n = math.floor(n)
    if n < 1 then return nil end
    if maxV and n > maxV then return maxV end
    return n
end

--- Substitui a tabela INTEIRA de overrides (sanitizada), salva no arquivo e
--- limpa caches. Usado pelo SERVIDOR ao receber overrides do cliente (admin) e
--- pelos clientes ao aplicar o broadcast do servidor (autoridade final).
function GridDevTool.replaceOverrides(overrides)
    if type(overrides) ~= "table" then return end
    local newOverrides = {}
    for fullType, data in pairs(overrides) do
        if type(fullType) == "string" and type(data) == "table" then
            local o = {}
            local w = clampInt(data.w, 12);  if w then o.w = w end
            local h = clampInt(data.h, 24);  if h then o.h = h end
            local c = clampInt(data.cols, 20); if c then o.cols = c end
            local r = clampInt(data.rows, 40); if r then o.rows = r end
            -- angle: número (graus), sem limite de 1..N — pode ser negativo
            -- (rotação anti-horária) e não tem teto baixo. Só clamp genérico.
            local a = tonumber(data.angle)
            if a ~= nil and a ~= 0 then o.angle = a end
            -- scale: multiplicador de tamanho do sprite. Default 1.0 (min-fit
            -- puro, preserva aspecto); só persiste se != 1 e > 0. Sem teto — o
            -- usuário pode crescer até a borda do footprint.
            local sc = tonumber(data.scale)
            if sc ~= nil and sc ~= 1 and sc > 0 then o.scale = sc end
            -- anchorX/anchorY: deslocamento em pixels do sprite (negativo =
            -- pra cima/esquerda). Só persiste se != 0; clamp pra não flutuar
            -- pra fora da tela.
            local ax = tonumber(data.anchorX)
            if ax ~= nil and ax ~= 0 then o.anchorX = math.max(-200, math.min(200, ax)) end
            local ay = tonumber(data.anchorY)
            if ay ~= nil and ay ~= 0 then o.anchorY = math.max(-200, math.min(200, ay)) end
            local ms = clampInt(data.maxStack, 1000); if ms then o.maxStack = ms end
            -- stackable: só boolean puro (true = força stack, false = força não)
            if data.stackable == true then o.stackable = true
            elseif data.stackable == false then o.stackable = false end
            local hasAny = false
            for _ in pairs(o) do hasAny = true break end
            if hasAny then
                newOverrides[fullType] = o
            end
        end
    end
    GridDevTool.Overrides = newOverrides
    GridDevTool.saveOverrides()
    GridDevTool.clearCaches()
end

--- Aplica overrides sanitizados (>=1), salva no arquivo e limpa os caches
--- (GridContainer.instances + ItemFootprint) para reconstruir com os novos
--- tamanhos. Usado pelo UI e pelo servidor ao receber overrides do cliente.
--- stackable: nil = Auto (regra de peso), true = força stack, false = força não.
--- maxStack: nil = Auto (recipe de pack/unpack), número = limite fixo.
--- angle: nil = mantém o atual, número = rotação do sprite (0 remove).
--- scale: nil = mantém o atual, número = multiplicador de tamanho (1 = remove).
--- anchorX/anchorY: nil = mantém o atual, número = deslocamento do sprite em px
--- (0 remove; pode ser negativo pra cima/esquerda).
function GridDevTool.applyOverrides(fullType, w, h, cols, rows, stackable, maxStack, angle, scale, anchorX, anchorY)
    if not fullType then return end
    local o = GridDevTool.Overrides[fullType] or {}
    if w ~= nil and tonumber(w) then o.w = math.max(1, tonumber(w)) end
    if h ~= nil and tonumber(h) then o.h = math.max(1, tonumber(h)) end
    if cols ~= nil and tonumber(cols) then o.cols = math.max(1, tonumber(cols)) end
    if rows ~= nil and tonumber(rows) then o.rows = math.max(1, tonumber(rows)) end
    if stackable == true then o.stackable = true
    elseif stackable == false then o.stackable = false
    elseif stackable == nil then o.stackable = nil end
    if maxStack ~= nil and tonumber(maxStack) then o.maxStack = math.min(1000, math.max(1, math.floor(tonumber(maxStack))))
    elseif maxStack == nil then o.maxStack = nil end
    if angle ~= nil and tonumber(angle) then
        local a = tonumber(angle)
        if a == 0 then o.angle = nil else o.angle = a end
    end
    if scale ~= nil and tonumber(scale) then
        local s = tonumber(scale)
        if s == 1 or s <= 0 then o.scale = nil else o.scale = s end
    end
    if anchorX ~= nil and tonumber(anchorX) then
        local ax = tonumber(anchorX)
        if ax == 0 then o.anchorX = nil else o.anchorX = math.max(-200, math.min(200, ax)) end
    end
    if anchorY ~= nil and tonumber(anchorY) then
        local ay = tonumber(anchorY)
        if ay == 0 then o.anchorY = nil else o.anchorY = math.max(-200, math.min(200, ay)) end
    end
    GridDevTool.Overrides[fullType] = o
    GridDevTool.saveOverrides()
    GridDevTool.clearCaches()
end

--- Limpa caches pra reconstruir grids e footprints com os novos tamanhos.
function GridDevTool.clearCaches()
    local GridContainer = require("DataModel/GridContainer")
    if GridContainer then GridContainer.instances = {} end
    local ItemFootprint = require("Algorithm/ItemFootprint")
    if ItemFootprint and ItemFootprint.clearCache then ItemFootprint.clearCache() end
    local GridIconRotation = require("Algorithm/GridIconRotation")
    if GridIconRotation and GridIconRotation.clearCache then GridIconRotation.clearCache() end
end

-- Carrega os dados salvos no boot (cliente e servidor).
Events.OnGameBoot.Add(GridDevTool.loadOverrides)

return GridDevTool
