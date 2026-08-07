--- GridCore_UnitTests.lua
--- Bateria de testes de sanidade da matemática do nosso grid.
--- Roda uma vez quando o jogo inicia e cospe os resultados no console.txt!

local GridCore = require("DataModel/GridCore")

local function printTest(name, passed)
    local status = passed and "[PASS]" or "[FAIL]"
    print("GridInventory Test: " .. status .. " " .. name)
end

local function RunGridCoreTests()
    print("--- INICIANDO TESTES DO GRIDINVENTORY ---")

    local grid = GridCore.new(5, 5) -- Criando mochila de 5x5
    
    -- Teste 1: Limites (Out of Bounds)
    local canPlaceOutside = grid:canPlaceItem("item1", 5, 5, 2, 2)
    printTest("Itens não podem vazar pra fora do grid", canPlaceOutside == false)

    -- Teste 2: Inserção Limpa
    local inserted = grid:insertItem("Machete_1", 1, 1, 1, 3)
    printTest("Inserir item válido 1x3 em (1,1)", inserted == true)

    -- Teste 3: Colisão Simples
    local colidiu = grid:canPlaceItem("Pistol_1", 1, 2, 2, 2)
    printTest("Pistola 2x2 deve colidir com o Machete em (1,2)", colidiu == false)

    -- Teste 4: Busca de Espaço (Auto-Position)
    local freeX, freeY = grid:findFreeSpace("Apple_1", 1, 1)
    printTest("Primeiro espaço livre para maçã (1x1) deve ser em (2,1)", freeX == 2 and freeY == 1)

    -- Teste 5: Remoção e liberação de espaço
    grid:removeItem("Machete_1")
    local colidiuDepoisRemocao = grid:canPlaceItem("Pistol_1", 1, 2, 2, 2)
    printTest("Após remover o Machete, a pistola não colide mais", colidiuDepoisRemocao == true)

    print("--- FIM DOS TESTES DO GRIDINVENTORY ---")
end

Events.OnGameBoot.Add(RunGridCoreTests)
