--- GridServerNetwork.lua
--- O Juiz! Escuta os comandos dos clientes, calcula a matemática de grid 
--- localmente e decide se autoriza ou não. Transmite a decisão.

if not isServer() then return end

local GridProtocol = require("Network/GridProtocol")
local GridCore = require("DataModel/GridCore") -- O Servidor RODA a matemática dele mesmo!

local GridServerNetwork = {}

local function OnClientCommand(module, command, player, args)
    if module ~= GridProtocol.MODULE then return end

    if command == GridProtocol.COMMANDS.REQUEST_MOVE then
        -- TODO: Aqui instanciaremos o container verdadeiro, checaremos o peso/limites
        -- e rodaremos grid:canPlaceItem(). 
        
        -- Por enquanto, código Mock.
        local isMathValid = true 

        if isMathValid then
            -- Sucesso! Salva no banco de dados e avisa todo mundo.
            -- (Essa chamada magicamente trigará o OnReceiveGlobalModData nos clientes!)
            ModData.transmit(GridProtocol.MODDATA_KEYS.GLOBAL_WORLD_GRIDS)
        else
            -- Opa! O cliente tentou sobrepor itens (cheat, ou lag)
            sendServerCommand(player, GridProtocol.MODULE, GridProtocol.COMMANDS.ERROR, {
                msg = "Colisão detectada no Grid!"
            })
        end
    end
end

Events.OnClientCommand.Add(OnClientCommand)

return GridServerNetwork
