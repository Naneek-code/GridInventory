-- harness.lua
-- Infraestrutura mínima de teste pro GridInventory (Lua 5.1.5).
-- Cada suite é um arquivo *_test.lua separado; o run_tests.sh roda cada um
-- num processo Lua novo (contadores independentes).
--
-- Uso:
--   local H = require("harness")
--   H.ok(cond, "label")
--   ... testes ...
--   H.finish()   -- imprime "X/Y testes passaram" e sai com código de erro

local M = {}

-- Base do mod (onde estão common/ e 42.x/). Definido pelo run_tests.sh via env.
M.base = os.getenv("GRID_MOD_BASE")
    or "/home/montesi/Zomboid/Workshop/GridInventory/Contents/mods/GridInventory"

-- package.path pras pastas shared do mod (DataModel, Algorithm, Network, DevTool).
package.path = M.base .. "/common/media/lua/shared/?.lua;"
    .. M.base .. "/common/media/lua/shared/DataModel/?.lua;"
    .. M.base .. "/common/media/lua/shared/Algorithm/?.lua;"
    .. M.base .. "/common/media/lua/shared/Network/?.lua;"
    .. M.base .. "/common/media/lua/shared/DevTool/?.lua;"
    .. M.base .. "/42.20/media/lua/shared/?.lua;"
    .. package.path

-- Contadores da suite atual.
local passed, failed = 0, 0
local suiteName = "?"

function M.setName(name)
    suiteName = name
end

function M.ok(cond, label)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FALHOU: " .. label)
    end
end

-- Imprime o resumo e sai com código de erro se algo falhou.
function M.finish()
    print(("%s: %s/%s testes passaram"):format(suiteName, passed, passed + failed))
    os.exit(failed == 0 and 0 or 1)
end

return M
