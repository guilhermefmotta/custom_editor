# 0016 — Renderização por evento: dormir em `glfwWaitEventsTimeout`, acordar por `glfwPostEmptyEvent` da mesma GLFW do raylib

Data: 2026-10-14 · Épico #1 · Ticket #18

## Contexto

O loop de `main.odin` renderizava sempre (`SetTargetFPS(60)`): ~11–12% de
CPU parado com um arquivo aberto (medido, `docs/benchmark.md`). O editor já
tem várias fontes assíncronas: fila git por repositório (ADR 0001/0014),
refresh de status do git (4 s no repo ativo, 15 s nos de fundo), terminal
(threads de leitura do PTY, ADR 0010), status do Claude por polling (ADR
0015), LSP, busca, Forge, debug adapter. Muitos timers avançam com `dt` do
quadro (auto save, banner, debounces, polls). Se o loop dormir sem cuidado,
resultados de threads só aparecem no próximo movimento do mouse e os timers
param.

O raylib oferece `EnableEventWaiting()` (o `PollInputEvents` do `EndDrawing`
chama `glfwWaitEvents`), mas sem timeout e sem forma de outra thread acordar
o loop.

## Decisão

1. **Esperar fora do raylib, na mesma GLFW.** O `libraylib.a` do
   `vendor:raylib` (macOS, conferido com `nm`; o build oficial do raylib
   para Windows/Linux também compila `rglfw.c` dentro da lib, mas essas libs
   não vêm nesta instalação do Odin para conferir — aqui só rodou
   `odin check -target:linux_amd64`) exporta os símbolos da GLFW
   (`nm libraylib.a | grep glfwPostEmptyEvent` → `T _glfwPostEmptyEvent`,
   `_glfwWaitEventsTimeout`). `frame_pacing.odin` os declara num
   `foreign { }` **sem biblioteca**: o linker resolve na cópia que já está
   no binário — não há segunda GLFW (que teria estado separado e não
   acordaria nada). Não usamos `EnableEventWaiting`: depois do `EndDrawing`
   (que já fez o reset do input do quadro e o `glfwPollEvents`), o loop chama
   `glfwWaitEventsTimeout(t)` / `glfwWaitEvents()` quando a política manda.
   Os callbacks da GLFW enchem o estado de input do raylib exatamente como se
   a espera tivesse acontecido dentro do `PollInputEvents`.
2. **`wake.request()`** (pacote novo `wake/`, sem raylib, usável pelos
   subpacotes e testes): flag atômica + chama o "poster" instalado pelo main
   (`glfwPostEmptyEvent`, thread-safe pela GLFW) **só na transição
   falso→verdadeiro** — uma enxurrada (`cat arquivo-grande` no terminal) posta
   no máximo um evento por quadro. O main consome com `wake.take()` no
   início do quadro e olha `wake.peek()` antes de dormir (pedido que chegou
   durante o quadro → renderiza de novo). Chamam `wake.request()`: worker da
   fila git (job pronto), thread de refresh do `Git_Manager` (status novo),
   leitor do PTY (saída nova / processo saiu), `rq_push` do LSP e do debug
   adapter (mensagem nova), worker do Forge (resultado), thread de busca
   (terminou). O poster é instalado depois do `InitWindow` e removido antes
   do `CloseWindow`.
3. **Política pura** (`frame_wait_policy`, testada): renderiza o próximo
   quadro se *animando* (alguém chamou `frame_request_anim()` — rolagem
   suave em curso —, fila git do repo ativo/`repos.ops` ocupada, operação
   remota, troca de repo pendente, busca rodando), se uma thread acordou
   durante o quadro, ou se houve input do usuário há menos de
   **1 s** (`FRAME_INPUT_GRACE`). Senão dorme até o prazo mais próximo
   pedido com `frame_request_in(s)`, ou até um evento se não há prazo.
   A janela de 1 s depois do input mantém digitação/rolagem idênticas ao
   loop antigo (fps cheio) e cobre de graça os debounces curtos (LSP 0,3/0,5 s,
   duplo clique 0,35 s, busca do grafo/paleta) sem cada um precisar
   agendar prazo.
4. **Prazos explícitos** (`frame_request_in`), pedidos a cada quadro por quem
   precisa: refresh de status git do repo ativo e dos de fundo (o `timer` do
   `Git_Manager`; com a thread rodando não há prazo, ela acorda o loop),
   poll do status do Claude (0,25 s se alguma sessão está *trabalhando*,
   2 s senão — mudanças de sessão parada/esperando vêm de input seu ou de
   saída do terminal, que já acordam o loop), auto save (`delay - idle`),
   expiração do banner, debounce de didChange/hover do LSP, pisca do cursor,
   reticências do Forge. Os timers continuam corretos porque **`frame_dt` é
   o tempo real desde o quadro anterior, sono incluído** (um timer de 4 s
   que dormiu 4 s dispara no primeiro quadro depois de acordar). O
   `rl.GetFrameTime()` não serve: atrasa um quadro e somaria o sono no
   quadro seguinte ao do evento (repetição de tecla dispararia na hora).
   `frame_anim_dt` = `frame_dt` limitado a 1/30 s para animações (rolagem que
   começa logo depois de dormir continua suave).
5. **Cursor piscando** (`[cursor] blink`, desligado por padrão; antes não era
   implementado): fase ancorada no último input, acorda só nas transições;
   depois de **10 s** sem input o cursor fica sólido e o loop para de acordar
   por ele. O pulso dos marcadores de gutter (breakpoint, diagnóstico) não
   pede quadros: respira enquanto o editor renderiza por outro motivo e fica
   parado quando ocioso.
6. **Terminal**: o leitor do PTY fazia `poll` de 50 ms para ver `quit` —
   8 shells ociosos = 160 acordadas/s de thread (~0,3% de CPU). Passou a
   500 ms (`READ_POLL_MS`): o `destroy` já manda SIGHUP antes, o que encerra
   a leitura na hora; os 500 ms só limitam o caso de filho que ignora SIGHUP.
7. **Configuração**: `[window] fps_target` (já existia, agora usado —
   60/120) e `[window] event_driven = true` (false = loop antigo, sempre
   renderizando).
8. **Instrumentação** só com `-define:BENCH=true` (`bench.odin`): tempo até o
   primeiro quadro, latência tecla→quadro (teclas reais e sintéticas),
   contadores de quadros/sonos/acordadas, `EDITOR_BENCH_TRACE=1` para ver por
   que cada quadro foi desenhado. Método e números em `docs/benchmark.md`.

## Alternativas descartadas

- **`EnableEventWaiting` + timer em thread chamando `glfwPostEmptyEvent`**:
  funcionaria, mas precisaria de uma thread-relógio para os prazos; a espera
  com timeout direto é mais simples.
- **Linkar a GLFW de novo** (`vendor:glfw`): duas cópias = dois estados; o
  `glfwPostEmptyEvent` de uma não acorda a espera da outra.
- **Timeout fixo curto sempre** (ex.: acordar a cada 100 ms): 10 quadros/s
  parado (~2% de CPU) e latência de até 100 ms para resultados de threads.
- **Prazo para cada debounce curto**: muitas mudanças espalhadas; a janela de
  1 s pós-input cobre todos e é o mesmo comportamento do loop antigo.

## Consequências

- Parado com um arquivo: ~0,7% de CPU (antes ~11–12%); com 8 terminais
  ociosos ~0,8–1%. O que sobra é o refresh de status do git a cada 4 s
  (processos `git` + ~5 quadros) e o polling dos PTYs.
- Tecla com o loop dormindo: acorda e desenha em ~3 ms (p50) contra ~26 ms no
  loop antigo (que esperava o próximo quadro e o pacing de 60 fps).
- Código novo que dependa de tempo **precisa** pedir prazo
  (`frame_request_in`) ou animação (`frame_request_anim`) se o efeito tiver
  que acontecer sem input; thread nova que produz resultado para a UI chama
  `wake.request()`. Debounces menores que 1 s depois de input não precisam.
- `frame_dt`/`frame_anim_dt` substituem `rl.GetFrameTime()` no loop.
