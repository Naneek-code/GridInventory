--- GridClientNetwork.lua
--- Lida com os envios do cliente e escuta as respostas do servidor.

local GridProtocol = require("Network/GridProtocol")

local GridClientNetwork = {}

-- ============================================================================
-- THE DISCORD GOLDEN DISCOVERY (B42.20 Hidden Event)
-- Isso salva a nossa vida para sincronizar baús e carros no multiplayer
-- ============================================================================
if Events and Events.OnReceiveGlobalModData then
    Events.OnReceiveGlobalModData.Add(function(tag, data)
        -- Atualiza o registro global do cliente silenciosamente
        ModData.add(tag, data)
        
        -- Se for a nossa tag de grids de mundo, nós disparamos um evento customizado
        -- para avisar a Interface Gráfica que ela precisa desenhar a tela novamente!
        if tag == GridProtocol.MODDATA_KEYS.GLOBAL_WORLD_GRIDS then
            triggerEvent("OnGridInventoryWorldSync")
        end
    end)
end

--- Pede permissão e validação matemática para o servidor
function GridClientNetwork.RequestItemMove(containerId, itemId, x, y, rotated)
    local player = getPlayer()
    if not player then return end

    local args = {
        container = containerId,
        item = itemId,
        x = x,
        y = y,
        rotated = rotated
    }

    sendClientCommand(player, GridProtocol.MODULE, GridProtocol.COMMANDS.REQUEST_MOVE, args)
end

--- Recebe as broncas ou confirmações do Servidor
local function OnServerCommand(module, command, args)
    if module ~= GridProtocol.MODULE then return end

    if command == GridProtocol.COMMANDS.ERROR then
        -- Exemplo: Alguém pegou o item 1 milissegundo antes de você (Race Condition)
        -- O servidor negou seu movimento.
        player = getPlayer()
        if player then
            player:Say("Ops... Desync! Movimento negado pelo Servidor.")
            triggerEvent("OnGridInventoryWorldSync") -- Força a UI a reverter pra realidade do server
        end
    end
end

Events.OnServerCommand.Add(OnServerCommand)

return GridClientNetwork
