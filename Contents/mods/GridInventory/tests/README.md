# GridInventory — Testes

Suites de teste unitário do GridInventory (Lua 5.1.5 — mesmo major do Kahlua
do Project Zomboid). Vivem FORA de `media/lua/`, então o jogo NÃO os carrega.

## Rodar

```bash
./run_tests.sh
```

O runner:
1. Baixa/compila o Lua 5.1.5 em `/tmp/lua-5.1.5` se não existir (o `/tmp` é
   volátil — é normal recompilar de vez em quando).
2. Faz syntax-check (`luac -p`) em TODAS as `.lua` do mod (client + shared).
3. Roda cada `*_test.lua` num processo Lua separado.

## Suites

| Suite | O que cobre | Testes |
|---|---|---|
| `stack_test` | Stacking no GridCore: empilhar/remover/promover líder, findFreeSpace com/sem compatKey, rotação, ghost compatível, limite de unidades | 70 |
| `refresh_stack_test` | `GridContainer:refresh()`: posição salva, auto-fit, empilhamento no refresh, não-empilháveis, limite de unidades, unpositioned, modData | 22 |
| `scatter_test` | Scatter (loot natural determinístico) no refresh | 15 |
| `transfer_sim_test` | Drop de stack virtual (ex.: Twine): pre-write de posições + InTransit + absorção do `checkQueueList` (ação atual = `queue[1]`, não `q.action`) | 3 |
| `drop_preview_test` | Lógica do preview de drop (`drawDropPreview` + `canFitItems`): verde/vermelho no cursor, snap no 1º espaço livre só em OUTRO grid (mesmo grid é estrito), ignoreSet de itens em movimento, checagem agregada de área do multi-drag (movedSet, pilha compatível) | 19 |
| `mpsync_test` | Rede server-mandatory: buildContainerRef, isAdmin, processMove (ok/colisão/notfound/clear/equipado), CLEAR_HAND, overrides admin-only, eco SYNC_ITEM | 19 |
| `wearhand_test` | Vestir item da mão (SP/MP): override do complete() + sanitizador (item vestido não pode estar na mão) | 26 |
| `capacity_test` | Teto de peso real (`gridCapacity`): player usa 50 (não o "confortável" 12), bolsa usa a capacidade dela | 10 |

Total: 184 testes.

## Como as suites carregam os módulos

`harness.lua` define `GRID_MOD_BASE` (env, setado pelo runner) e injeta
`common/media/lua/shared/{DataModel,Algorithm,Network,DevTool}` e
`42.20/media/lua/{server,client}` no `package.path`. As suites usam `require`
normalmente e stubs para o ambiente PZ (ItemContainer, InventoryItem, Events,
sendServerCommand etc.).

## Histórico / nota

As suites originais (mask_test, compact_test, picker_math_test, pickup_test,
pickup2_test) foram perdidas com o wipe do `/tmp`. As atuais foram recriadas a
partir do comportamento atual do código. Ao mexer em features novas, adicione
suites aqui — se o `/tmp` sumir de novo, o código sobrevive.
