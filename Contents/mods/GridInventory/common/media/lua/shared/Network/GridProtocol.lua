--- GridProtocol.lua
--- Define os nomes dos comandos de rede e as chaves de ModData.
--- Usado tanto pelo Cliente quanto pelo Servidor.

local GridProtocol = {}

GridProtocol.MODULE = "GridInventory"

GridProtocol.COMMANDS = {
    REQUEST_MOVE = "ReqMove",      -- Cliente pede para mover item
    SYNC_CONTAINER = "SyncCont",   -- Servidor força atualização do container
    ERROR = "ErrorMsg"             -- Servidor avisa cliente que a matemática falhou (cheat/desync)
}

-- Chaves para salvar coisas no banco de dados do jogo
GridProtocol.MODDATA_KEYS = {
    GLOBAL_WORLD_GRIDS = "GridInventory_WorldGrids" -- Guarda as posições de baús no mapa
}

return GridProtocol
