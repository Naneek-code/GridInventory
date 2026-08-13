--- ItemFootprint.lua
--- Algoritmo dinâmico para calcular o tamanho de um item (Width, Height)
--- baseado nas suas propriedades nativas da B42 (Peso, Categoria, Tipo).

local ItemFootprint = {}

-- Dicionário de overrides fixos para itens que a matemática não adivinha bem.
-- Pode ser expandido por outros mods conectando nessa tabela.
-- BASE: populado a partir do GridOverrides.ini do usuário (essência do que ele
-- ajustou manualmente). VHS: fita larga e baixa → sempre 2x1.
ItemFootprint.Overrides = {
    ["Base.CigarettePack"] = { w = 1, h = 1},
    ["Base.NormalCarMuffler"] = { w = 3, h = 4},
    ["Base.NormalCarMuffler2"] = { w = 3, h = 4},
    ["Base.EngineParts"] = { w = 3, h = 2},
    ["Base.HuntingKnife"] = { w = 3, h = 1},
    ["Base.Tarp"] = { w = 2, h = 3},
    ["Base.CarBatteryCharger"] = { w = 3, h = 2},
    ["Base.VHS_Retail"] = { w = 2, h = 1 },
    ["Base.VHS_Home"] = { w = 2, h = 1 },
    -- Cozinha: panelas e utensílios volumosos
    ["Base.Pan"] = { w = 2, h = 2 },
    ["Base.Saucepan"] = { w = 2, h = 2 },
    ["Base.SaucepanCopper"] = { w = 2, h = 2 },
    ["Base.Pot"] = { w = 2, h = 2 },
    ["Base.Kettle"] = { w = 2, h = 2 },
    ["Base.RoastingPan"] = { w = 3, h = 2 },
    ["Base.MuffinTray"] = { w = 3, h = 2 },
    ["Base.CuttingBoardPlastic"] = { w = 2, h = 2 },
    ["Base.CuttingBoardWooden"] = { w = 2, h = 2 },
    ["Base.Spatula"] = { w = 1, h = 2 },
    ["Base.Ladle"] = { w = 1, h = 2 },
    ["Base.GridlePan"] = { w = 2, h = 2 },
    ["Base.BakingPan"] = { w = 3, h = 3 },
    ["Base.BakingTray"] = { w = 3, h = 2 },
    ["Base.RollingPin"] = { w = 3, h = 2 },
    ["Base.BastingBrush"] = { w = 1, h = 2 },
    ["Base.KitchenTongs"] = { w = 1, h = 2 },
    ["Base.TinOpener"] = { w = 1, h = 2 },
    ["Base.Strainer"] = { w = 1, h = 2 },
    ["Base.OvenMitt"] = { w = 1, h = 2 },
    ["Base.Bowl"] = { w = 2, h = 1 },
    ["Base.StewBowl"] = { w = 2, h = 1 },
    ["Base.WaterDish"] = { w = 2, h = 1 },
    ["Base.Whetstone"] = { w = 2, h = 1 },
    -- Comida embalada
    ["Base.Crisps"] = { w = 1, h = 2 },
    ["Base.Crisps2"] = { w = 1, h = 2 },
    ["Base.Crisps3"] = { w = 1, h = 2 },
    ["Base.Coffee2"] = { w = 1, h = 2 },
    ["Base.Coffee"] = { w = 1, h = 2 },
    ["Base.Banana"] = { w = 1, h = 2 },
    ["Base.Milk"] = { w = 1, h = 2 },
    ["Base.MilkBottle"] = { w = 1, h = 2 },
    ["Base.PopBottle"] = { w = 1, h = 2 },
    ["Base.Cereal"] = { w = 2, h = 2 },
    ["Base.PowerBar"] = { w = 2, h = 2 },
    ["Base.Oatmeal"] = { w = 2, h = 1 },
    ["Base.Sausage"] = { w = 2, h = 1 },
    ["Base.Baloney"] = { w = 1, h = 2 },
    ["Base.Salami"] = { w = 2, h = 1 },
    ["Base.GranolaBar"] = { w = 2, h = 1 },
    ["Base.Chocolate"] = { w = 2, h = 1 },
    ["Base.MilkChocolate_Personalsized"] = { w = 1, h = 1 },
    ["Base.Icecream"] = { w = 1, h = 2 },
    ["Base.CannedCornedBeef"] = { w = 2, h = 1 },
    -- Bebidas/líquidos (garrafa alta)
    ["Base.WaterBottle"] = { w = 1, h = 2 },
    ["Base.HotWaterBottle"] = { w = 2, h = 1 },
    ["Base.CleaningLiquid2"] = { w = 1, h = 2 },
    ["Base.Vinegar2"] = { w = 1, h = 2 },
    ["Base.Bleach"] = { w = 1, h = 2 },
    ["Base.Disinfectant"] = { w = 1, h = 2 },
    ["Base.CocoaPowder"] = { w = 1, h = 2 },
    ["Base.Flour2"] = { w = 2, h = 3 },
    ["Base.PancakeMix"] = { w = 1, h = 2 },
    ["Base.Mustard"] = { w = 1, h = 2 },
    ["Base.Hotsauce"] = { w = 1, h = 2 },
    ["Base.TomatoPaste"] = { w = 1, h = 2 },
    ["Base.JamFruit"] = { w = 1, h = 1 },
    -- Bebidas alcoólicas (garrafa alta)
    ["Base.Scotch"] = { w = 1, h = 2 },
    ["Base.Gin"] = { w = 1, h = 2 },
    ["Base.Sherry"] = { w = 1, h = 2 },
    ["Base.Vermouth"] = { w = 1, h = 2 },
    ["Base.CoffeeLiquer"] = { w = 1, h = 2 },
    ["Base.Rum"] = { w = 1, h = 2 },
    ["Base.Vodka"] = { w = 1, h = 2 },
    ["Base.Curacao"] = { w = 1, h = 2 },
    ["Base.Port"] = { w = 1, h = 2 },
    -- Eletrônicos/utensílios domésticos
    ["Base.Remote"] = { w = 2, h = 1 },
    ["Base.CordlessPhone"] = { w = 1, h = 2 },
    ["Base.Headphones"] = { w = 1, h = 2 },
    ["Base.VideoGame"] = { w = 2, h = 1 },
    ["Base.CDplayer"] = { w = 2, h = 2 },
    ["Base.HairDryer"] = { w = 2, h = 2 },
    ["Base.HairIron"] = { w = 2, h = 2 },
    ["Base.RadioRed"] = { w = 3, h = 2 },
    ["Base.HandDrill"] = { w = 2, h = 2 },
    ["Base.BlowTorch"] = { w = 2, h = 2 },
    ["Base.WeldingRods"] = { w = 2, h = 2 },
    ["Base.ViseGrips"] = { w = 1, h = 2 },
    ["Base.Bellows"] = { w = 2, h = 2 },
    ["Base.Saw"] = { w = 2, h = 2 },
    ["Base.GardenSaw"] = { w = 2, h = 2 },
    ["Base.LugWrench"] = { w = 2, h = 2 },
    ["Base.LeafRake"] = { w = 2, h = 4 },
    ["Base.TirePump"] = { w = 2, h = 3 },
    ["Base.HandShovel"] = { w = 2, h = 1 },
    ["Base.Toolbox_Farming"] = { w = 3, h = 2 },
    ["Base.PencilCase"] = { w = 2, h = 1 },
    ["Base.SewingKit"] = { w = 2, h = 2 },
    -- Casa/limpeza
    ["Base.Plunger"] = { w = 2, h = 2 },
    ["Base.Mirror"] = { w = 2, h = 2 },
    ["Base.Garbagebag"] = { w = 2, h = 3, cols = 5, rows = 6 },
    ["Base.TVDinner"] = { w = 2, h = 2 },
    ["Base.HairDyeCommon"] = { w = 1, h = 2 },
    ["Base.Boxers_Hearts"] = { w = 1, h = 2 },
    ["Base.BeerEmpty"] = { w = 2, h = 1 },
    ["Base.CigarBox"] = { w = 2, h = 1, cols = 6, rows = 2 },
    ["Base.Stapler"] = { w = 2, h = 1 },
    ["Base.PaperclipBox"] = { w = 2, h = 1 },
    ["Base.Doorknob"] = { w = 1, h = 2 },
    ["Base.IDcard"] = { w = 1, h = 1 },
    ["Base.IDcard_Male"] = { w = 1, h = 1 },
    ["Base.IDcard_Female"] = { w = 1, h = 1 },
    -- Literatura/mídia
    ["Base.Phonebook"] = { w = 2, h = 2 },
    ["Base.ComicBook_Retail"] = { w = 1, h = 2 },
    ["Base.TVMagazine"] = { w = 1, h = 2 },
    ["Base.Diary1"] = { w = 1, h = 2 },
    -- Junk / casa
    ["Base.Camera"] = { w = 1, h = 2 },
    ["Base.CameraDisposable"] = { w = 1, h = 2 },
    ["Base.ToiletPaper"] = { w = 2, h = 1 },
    ["Base.BathTowel"] = { w = 1, h = 2 },
    ["Base.DishCloth"] = { w = 1, h = 2 },
    ["Base.TissueBox"] = { w = 2, h = 1 },
    ["Base.Bucket"] = { w = 2, h = 2 },
    ["Base.CheckerBoard"] = { w = 2, h = 2 },
    ["Base.ToyBear"] = { w = 2, h = 2 },
    ["Base.ToyPlane"] = { w = 2, h = 1 },
    ["Base.PokerChips"] = { w = 2, h = 1 },
    ["Base.TarotCardDeck"] = { w = 1, h = 2 },
    ["Base.TrophyBronze"] = { w = 2, h = 3 },
    ["Base.ElectronicsScrap"] = { w = 2, h = 2 },
    ["Base.IndustrialDye"] = { w = 1, h = 2 },
    ["Base.TobaccoLoose"] = { w = 2, h = 1 },
    -- Vidros
    ["Base.GlassTumbler"] = { w = 1, h = 2 },
    ["Base.GlassWine"] = { w = 1, h = 2 },
    ["Base.DrinkingGlass"] = { w = 1, h = 2 },
    ["Base.Mugl"] = { w = 1, h = 2 },
    ["Base.Fork"] = { w = 1, h = 1 },
    ["Base.Perfume"] = { w = 1, h = 2 },
    ["Base.Cologne"] = { w = 1, h = 1 },
    ["Base.Ring_Left_RingFinger_Gold"] = { w = 1, h = 1 },
    ["Base.BeerCanEmpty"] = { w = 1, h = 2 },
    -- Sementes (embalagens)
    ["Base.StrewberrieBagSeed2"] = { w = 1, h = 2 },
    ["Base.WatermelonBagSeed"] = { w = 1, h = 2 },
    ["Base.BarleyBagSeed"] = { w = 1, h = 2 },
    ["Base.CornBagSeed"] = { w = 1, h = 2 },
    ["Base.RyeBagSeed"] = { w = 1, h = 2 },
    ["Base.ChamomileBagSeed"] = { w = 1, h = 2 },
    ["Base.GardeningSprayEmpty"] = { w = 1, h = 2 },
    ["Base.Pillow"] = { w = 3, h = 2 },
    ["Base.AnimalFeedBag"] = { w = 2, h = 3 },
    -- Containers calibrados (footprint w/h + grid interno cols/rows): o grid
    -- interno nativo é o DEFAULT (GridContainer.getGridSize cai aqui quando o
    -- GridDevTool não tem override ao vivo pro item).
    ["Base.Bag_FluteCase"] = { w = 2, h = 2, cols = 6, rows = 2 },
    ["Base.Bag_ViolinCase"] = { w = 2, h = 3, cols = 6, rows = 2 },
    ["Base.Bag_FannyPackBack"] = { w = 2, h = 1, cols = 6, rows = 2 },
    ["Base.Bag_FannyPackFront"] = { w = 2, h = 1, cols = 6, rows = 2 },
    ["Base.Bag_FannyPackBack_Tarp"] = { w = 2, h = 1, cols = 6, rows = 2 },
    ["Base.Bag_FannyPackFront_Tarp"] = { w = 2, h = 1, cols = 6, rows = 2 },
    ["Base.Toolbox"] = { w = 3, h = 2, cols = 6, rows = 3 },
    ["Base.Toolbox_Mechanic"] = { w = 3, h = 2, cols = 6, rows = 3 },
    ["Base.Toolbox_Gardening"] = { w = 3, h = 2, cols = 6, rows = 3 },
    ["Base.Toolbox_Fishing"] = { w = 3, h = 2, cols = 6, rows = 3 },
    ["Base.Bag_JanitorToolbox"] = { w = 3, h = 2, cols = 6, rows = 3 },
    ["Base.Bag_TarpSlingBag"] = { w = 3, h = 2, cols = 6, rows = 4 },
    ["Base.TakeoutBox_Styrofoam"] = { w = 2, h = 1, cols = 6, rows = 2 },
    ["Base.Shoebox"] = { w = 2, h = 1, cols = 6, rows = 2 },
    ["Base.AmmoStrap_Shells"] = { w = 2, h = 1, cols = 6, rows = 2 },
    ["Base.AmmoStrap_Brown_Shells"] = { w = 2, h = 1, cols = 6, rows = 2 },
    ["Base.PencilCase_Gaming"] = { w = 2, h = 1, cols = 6, rows = 2 },
    ["Base.HolsterShoulder"] = { w = 1, h = 2, cols = 6, rows = 2 },
}

-- Cache por fullType: o resultado da FÓRMULA (sem overrides) é 100% determinado
-- pelo fullType, então só precisa ser calculado uma vez por tipo de item, não
-- uma vez por instância. Overrides NÃO são cacheados aqui de propósito, pra
-- continuar refletindo mudanças ao vivo feitas pelo GridDevTool.
local _sizeCache = {}

--- Limpa o cache de tamanhos calculados. Chame isso se os thresholds de peso
--- ou a lógica de categorias mudar em runtime (ex: hot-reload no dev).
function ItemFootprint.clearCache()
    _sizeCache = {}
end

-- Teto de segurança: mesmo um item absurdamente pesado não deve estourar a grid.
local MAX_W, MAX_H = 6, 12

local function clamp(v, maxV)
    if v > maxV then return maxV end
    return v
end

-- ─── Regras por DisplayCategory ─────────────────────────────────────────────
-- Cada categoria mapeia para uma lista ordenada por PESO ASCENDENTE:
--   { pesoMax, largura, altura } — o primeiro cujo pesoMax >= peso do item vence.
-- ESTILO: footprints COMPRIDOS (Tarkov), mas com LARGURA suficiente pra sprite
-- crescer. Footprints muito altos+estreitos (1x4) deixam a sprite minúscula e
-- esticada no grid vertical — itens "volumosos" viram 2x3/2x4. Só itens
-- genuinamente LONGOS E FINOS (vara de pescar, violão, taco, lança) mantêm 1x3.
local CATEGORY_RULES = {
    Ammo = {
        { 0.5, 1, 1 },  -- bala solta
        { 3, 1, 2 },    -- caixa de munição
        { 99, 2, 2 },   -- caixão de balas (volumoso, não 1x3)
    },
    Material = {
        { 0.3, 1, 1 },  -- parafuso, prego, scrap miúdo
        { 0.9, 1, 1 },  -- lâminas, lingotes pequenos, lona/tecido fino
        { 2.5, 2, 2 },  -- tábua, chapa, tecido/lençol/pillow (VOLUMOSO)
        { 6, 2, 3 },    -- madeira, couro grande, barras de metal
        { 99, 2, 4 },   -- viga, tronco, anvil
    },
    Tool = {
        { 0.5, 1, 1 },  -- canivete, chave de fenda
        { 2, 1, 2 },    -- martelo, serra
        { 5, 2, 3 },    -- marreta, pé de cabra (cabeça larga)
        { 99, 2, 2 },   -- furadeira, caixa de ferramentas
    },
    Electronics = {
        { 0.5, 1, 1 },  -- walkie-talkie
        { 2, 1, 2 },    -- calculadora, telefone
        { 8, 2, 2 },    -- rádio, TV pequena
        { 99, 2, 3 },   -- TV, monitor grande
    },
    Household = {
        { 0.5, 1, 1 },  -- talher, xícara
        { 1.5, 2, 2 },  -- panela, jarro (largo)
        { 99, 2, 2 },   -- frigideira grande
    },
    FirstAid = {
        { 0.2, 1, 1 },  -- pílula, comprimido
        { 99, 1, 2 },   -- bandagem, kit, pomada
    },
    Junk = {
        { 0.2, 1, 1 },  -- lixo miúdo (cola, dado, elástico)
        { 0.6, 1, 2 },  -- sucata, pente, baralho
        { 99, 2, 2 },   -- lixo volumoso (caixa de cigarro, câmera)
    },
    Memento = {
        { 0.2, 1, 1 },  -- jóia, anel
        { 99, 1, 2 },   -- item de coleção, livro de recordação
    },
    WaterContainer = {
        { 0.5, 1, 1 },  -- copo, garrafinha
        { 2, 1, 2 },    -- garrafa de água
        { 99, 2, 2 },   -- galão, balde
    },
    Camping = {
        { 0.3, 1, 1 },  -- isqueiro
        { 1.5, 1, 2 },  -- corda, barraca leve
        { 99, 2, 3 },   -- barraca grande (volumosa, não 1x4)
    },
    Cooking = {
        { 0.3, 1, 1 },  -- tempero
        { 1, 1, 2 },    -- utensílio (colher, concha)
        { 99, 2, 2 },   -- panela, frigideira (larga)
    },
    Gardening = {
        { 0.3, 1, 1 },  -- semente, muda
        { 1.5, 1, 2 },  -- enxada, pá
        { 99, 2, 3 },   -- ferramenta grande (pá larga)
    },
    Fishing = {
        { 0.5, 1, 1 },  -- isca, anzol
        { 99, 1, 3 },   -- vara de pescar (LONGA e fina → 1x3)
    },
    Instrument = {
        { 0.5, 1, 1 },  -- apito, gaita
        { 99, 1, 3 },   -- violão, flauta (LONGO e fino → 1x3)
    },
    Entertainment = {
        { 0.5, 1, 1 },  -- fita, dado
        { 99, 2, 2 },   -- jogo de tabuleiro (caixa larga)
    },
    Sports = {
        { 0.5, 1, 1 },  -- bola de tênis
        { 2, 1, 3 },    -- taco, raquete (LONGO e fino → 1x3)
        { 99, 2, 2 },   -- bola grande
    },
    VehicleMaintenance = {
        { 0.5, 1, 1 },  -- parafuso de motor
        { 1.4, 1, 2 },  -- peça pequena
        { 4.5, 2, 2 },  -- galões (PetrolCan 1.6, JerryCan 4.0) — VOLUMOSOS
        { 8, 2, 3 },    -- peça comprida
        { 99, 2, 3 },   -- bateria, pneu, tanque de gasolina
    },
    Communications = {
        { 0.3, 1, 1 },  -- earpiece, walkie de bolso
        { 1.5, 1, 2 },  -- rádio amador
        { 99, 2, 2 },   -- rádio base
    },
    Trapping = {
        { 0.3, 1, 1 },  -- isca de rato
        { 99, 1, 2 },   -- armadilha
    },
    Security = {
        { 99, 1, 1 },   -- chave
    },
    Key = {
        { 99, 1, 1 },   -- chave
    },
    Cartography = {
        { 0.5, 1, 1 },  -- mapa de bolso
        { 99, 1, 2 },   -- mapa grande
    },
    Seed = {
        { 99, 1, 1 },   -- semente
    },
}

--- Aplica a regra de uma categoria por peso. Retorna nil se não achar.
local function ruleFor(cat, weight)
    local rules = CATEGORY_RULES[cat]
    if not rules then return nil end
    for _, r in ipairs(rules) do
        if weight <= r[1] then
            return r[2], r[3]
        end
    end
    return nil
end

--- Calcula w/h a partir da fórmula (peso + categoria). NÃO considera overrides.
--- @param item InventoryItem
local function computeFormulaSize(item)
    -- ATENÇÃO: getWeight() é o peso BASE do script (fixo por tipo).
    -- getActualWeight() inclui modificadores de instância — e, para itens
    -- container, normalmente inclui o peso do CONTEÚDO, e para armas pode
    -- incluir o peso de attachments. Usar getActualWeight() aqui faria o
    -- tamanho na grid mudar conforme a mochila enche/esvazia ou a arma troca
    -- de acessório, o que quebra o layout salvo do jogador.
    -- Confirme o nome exato do método na sua build (pode variar entre
    -- patches do B42) antes de assumir que getWeight() é o certo.
    local weight = item:getWeight()
    local isWeapon = instanceof(item, "HandWeapon")
    local isClothing = instanceof(item, "Clothing")
    local isBag = instanceof(item, "InventoryContainer")
    local isFood = instanceof(item, "Food")
    local isMoveable = instanceof(item, "Moveable")
    -- Literatura/livros: mesma detecção do ItemCategory (BOOK) — instanceof
    -- Literature ou displayCategory Literature/SkillBook.
    local displayCat = item.getDisplayCategory and item:getDisplayCategory() or nil
    local isLiterature = instanceof(item, "Literature")
        or displayCat == "Literature" or displayCat == "SkillBook"

    local w, h = 1, 1

    if isWeapon then
        if item:isTwoHandWeapon() then
            -- Armas longas de duas mãos (Espingardas, Rifles, Tacos, Machados, Lanças)
            if weight >= 3.0 then
                w, h = 2, 5 -- Muito pesada (Marreta)
            elseif weight >= 2.0 then
                w, h = 2, 4 -- Escopetas, Rifles
            elseif weight >= 1.5 then
                w, h = 1, 4 -- Tacos de Baseball, Facões longos
            else
                w, h = 1, 3 -- Tacos leves, pedaços de cano
            end
        else
            -- Armas de uma mão (Pistolas, Facas, Cassetetes)
            if weight >= 1.5 then
                w, h = 1, 3 -- Pé de cabra
            elseif weight >= 0.8 then
                w, h = 2, 2 -- Revólveres pesados, Martelos
            elseif weight >= 0.3 then
                w, h = 1, 2 -- Pistolas leves, Facas médias
            else
                w, h = 1, 1 -- Canetas, Facas de manteiga
            end
        end
    elseif isBag then
        -- CONTAINER: escala pelo CAPACITY interno (mais fiel que só o peso).
        -- Chaveiro/carteira (cap 1-2) são minúsculos — antes caíam em 2x2
        -- (mínimo do branch por peso). Mochilas grandes mantêm 4x4.
        local cap = item.getInventory and item:getInventory()
            and item:getInventory():getCapacity() or nil
        if cap ~= nil then
            if cap <= 1 then
                w, h = 1, 1 -- Chaveiro, carteira, estojo minúsculo
            elseif cap <= 3 then
                w, h = 1, 2 -- Sacolinha, estojo, bolsa pequena
            elseif cap <= 6 then
                w, h = 2, 2 -- Pochetes, maletas, toolboxes
            elseif cap <= 12 then
                w, h = 2, 3 -- Mochilas médias
            else
                w, h = 3, 3 -- Mochilas grandes
            end
        elseif weight >= 2.0 then
            w, h = 4, 4 -- Mochilas Grandes (fallback sem capacity)
        elseif weight >= 1.0 then
            w, h = 3, 3 -- Mochilas Médias, Maletas
        else
            w, h = 2, 2 -- Pochetes, Sacolas plásticas
        end
    elseif isClothing then
        if weight >= 2.0 then
            w, h = 2, 3 -- Casacos pesados, Coletes Balísticos
        elseif weight >= 1.0 then
            w, h = 2, 2 -- Calças, Camisas
        else
            w, h = 1, 2 -- Luvas, Chapéus, Óculos, acessórios de roupa
        end
    elseif isFood then
        if weight >= 1.0 then
            w, h = 2, 2 -- Melancia, Repolho grande
        elseif weight >= 0.3 then
            w, h = 1, 2 -- Garrafa d'água, Comida Enlatada, Embalagem
        else
            w, h = 1, 1 -- Pílulas, Frutas pequenas, Snacks
        end
    elseif isMoveable then
        -- MÓVEIS: largura SEMPRE 6 (máximo do grid) — móveis ocupam a largura
        -- toda do grid. A altura varia com o peso: mais pesado = mais alto.
        if weight >= 20.0 then
            w, h = 6, 12 -- Sofás enormes, Geladeiras
        elseif weight >= 15.0 then
            w, h = 6, 10 -- Camas, Armários grandes
        elseif weight >= 10.0 then
            w, h = 6, 7  -- Sofás, Mesas grandes
        elseif weight >= 5.0 then
            w, h = 6, 5  -- Mesas médias, Cadeirões
        elseif weight >= 2.0 then
            w, h = 6, 3  -- Cadeiras, Caixas grandes
        else
            w, h = 6, 2  -- Decorações móveis leves
        end
    elseif isLiterature then
        -- LITERATURA (livros/revistas): NO MÁXIMO 1x2. Livros são longos e
        -- finos — 1 coluna por 2 células, nunca 2 de largura. Até revistas
        -- leves ganham 1x2 (sprite maior = grid viva).
        w, h = 1, 2
    else
        -- Regras finas por DisplayCategory (calibradas pelos pesos reais do
        -- B42). Só cai no genérico o que NÃO tem regra específica.
        local rw, rh = ruleFor(displayCat, weight)
        if rw and rh then
            w, h = rw, rh
        else
            -- Itens Gerais (Materiais, Junk, Eletrônicos sem regra própria)
            if weight >= 5.0 then
                w, h = 3, 3 -- Geradores, Pneus, Móveis
            elseif weight >= 2.0 then
                w, h = 2, 3 -- Tábuas, Chapas de metal (itens compridos)
            elseif weight >= 1.0 then
                w, h = 2, 2 -- Galão de gasolina, Caixa de ferramentas
            elseif weight >= 0.3 then
                w, h = 1, 2 -- Walkie Talkie, Livros, Fitas
            else
                w, h = 1, 1 -- Pregos, Sementes, parafusos (minúsculos)
            end
        end
    end

    return clamp(w, MAX_W), clamp(h, MAX_H)
end

---@param item InventoryItem Objeto nativo do PZ
---@return number, number width e height do item
function ItemFootprint.getSize(item)
    if not item then return 1, 1 end

    local fullType = item:getFullType()

    -- 1. Overrides sempre têm prioridade e são checados ao vivo (não cacheados),
    --    pra permitir tunar via GridDevTool sem precisar limpar cache.
    local override = ItemFootprint.Overrides[fullType]
    if GridDevTool and GridDevTool.Overrides and GridDevTool.Overrides[fullType] then
        override = GridDevTool.Overrides[fullType]
    end
    if override and override.w and override.h then
        return override.w, override.h
    end

    -- 2. Cache por tipo: a fórmula só depende do fullType (peso base + categoria
    --    são fixos por tipo de item), então calculamos uma vez só.
    local cached = _sizeCache[fullType]
    if cached then
        return cached[1], cached[2]
    end

    local w, h = computeFormulaSize(item)
    _sizeCache[fullType] = { w, h }
    return w, h
end

return ItemFootprint