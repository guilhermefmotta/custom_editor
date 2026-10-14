# Benchmark: editor vs. Emacs

Ticket #18 · ADR 0016 (renderização por evento). Data: 2026-10-14.

## Ambiente

- Apple M5, 16 GB, macOS 27.0, tela Retina interna 2560×1664
  (`WINDOW_HIGHDPI` ligado, atlas de fonte em 2×).
- Editor: `odin build . -out:<bin> -define:BENCH=true` (sem `-o:`, igual ao
  build normal), Odin dev-2026-10, raylib 6.0 estático do `vendor:raylib`.
  Rodado da raiz do repo (cwd = repo git → refresh de status a cada 4 s, LSP
  `ols` para o `.odin`), `editor.toml` do repo (keymap vim, blink desligado).
- Emacs: GNU Emacs 31.1 (`/Applications/Emacs.app/Contents/MacOS/Emacs`,
  o launcher faz `exec` — o PID é o do Emacs), config do usuário
  (`~/.emacs.d/init.el`, com `exec-path-from-shell`).
- Arquivo: `renderer.odin` (1 145 linhas) nos dois.

## Método (reproduzível: `docs/benchmark.py`)

```sh
odin build . -out:/tmp/editor_bench -define:BENCH=true
python3 docs/benchmark.py editor /tmp/editor_bench renderer.odin               # parado, 1 arquivo
python3 docs/benchmark.py editor /tmp/editor_bench renderer.odin --terminals 8 # + 8 shells ociosos
python3 docs/benchmark.py editor /tmp/editor_bench renderer.odin --legacy      # loop antigo (sempre renderiza)
python3 docs/benchmark.py editor /tmp/editor_bench renderer.odin --keys 200    # latência (teclas sintéticas)
python3 docs/benchmark.py plain  ./editor_antigo   renderer.odin               # binário sem BENCH: só CPU/RSS
python3 docs/benchmark.py emacs  /Applications/Emacs.app/Contents/MacOS/Emacs renderer.odin
```

- **CPU parado**: espera o primeiro quadro, mais 5 s para estabilizar (LSP,
  git, shells), e mede **20 s**: `Δ cputime / Δ tempo` pelo `ps -o time=`
  (número principal) e também a média de `ps -o %cpu` amostrado a cada 1 s
  (no macOS é uma média com decaimento — oscila mais). A janela não é tocada
  durante a medição.
- **RAM**: `ps -o rss` no fim da janela.
- **Tempo de abertura**: do `Popen` até o fim do primeiro `EndDrawing`
  (editor: linha `BENCH first_frame wall_ms=`); Emacs: até o
  `window-setup-hook` (`float-time`), mais o `emacs-init-time`.
- **Latência tecla → quadro**: sem permissão de Acessibilidade não dá para
  injetar teclas reais na janela (e `osascript keystroke` digitaria no app em
  foco, não necessariamente no editor). Então é medida **dentro do
  processo**, com teclas sintéticas (`EDITOR_BENCH_KEYS=N`): uma thread, a
  cada ~250 ms, marca `GetTime()` e chama `wake.request()` — o mesmo caminho
  que um evento do SO faz para acordar o loop dormindo; o quadro seguinte
  insere/apaga um caractere no buffer como a digitação (com `didChange` do
  LSP) e mede-se até o `EndDrawing` retornar (swap feito). Não inclui o
  tempo do teclado/SO até o evento chegar à GLFW nem o scan-out da tela.
  Com o `-define:BENCH=true`, teclas reais também geram linhas
  `BENCH key ... render_ms= frame_ms=` (do quadro que viu a tecla até o
  render / até o swap) para medir à mão.
- Só os processos iniciados pelo script são mortos (`SIGKILL`, para o editor
  não gravar sessão). 3 rodadas para os cenários principais.

## Resultados

### CPU parado e RAM

| Cenário | CPU (Δcputime/20 s) | CPU (`ps %cpu` médio) | RSS |
|---|---|---|---|
| **Editor, 1 arquivo** (3 rodadas) | **0,69 / 0,64 / 0,49 %** | 0,81 / 0,31 / 0,40 % | 102–104 MB |
| **Editor, 1 arquivo + 8 terminais ociosos** (3 rodadas) | **0,79 / 0,69 / 0,64 %** | 1,66 / 0,23 / 0,18 % | 110 MB |
| Editor, loop antigo (`--legacy`), 1 arquivo | 10,81 % | 10,96 % | 103 MB |
| Editor, loop antigo, 8 terminais | 14,01 % | 14,39 % | 108 MB |
| Binário do `epic-1` antes deste ticket, 1 arquivo | 10,84 % | 10,68 % | 102 MB |
| **Emacs** (config do usuário), 1 arquivo (3 rodadas) | **0,39 / 0,39 / 0,39 %** | 0,97 / 1,15 / 1,24 % | 197 MB |

Medição anterior do ticket (mesma máquina): editor 101 MB / 10,3 %, Emacs
198 MB / 0,4 % — batem com as de agora.

Parado, o editor desenha ~1,3 quadro/s (contadores `BENCH idle`): a cada 4 s o
refresh de status do git (prazo + "status pronto" + jobs da fila de alguma
tela) dá ~5 quadros; fora isso dorme em `glfwWaitEvents`. O resto da CPU é o
`git status`/`git diff` desse refresh e o polling dos PTYs (8 leitores com
`poll` de 500 ms; com os 50 ms de antes eram ~0,3 % a mais).

### Tempo de abertura (até o primeiro quadro)

| | Rodadas | |
|---|---|---|
| **Editor** | 296 / 292 / 275 ms (1 arquivo); 315 / 355 / 362 ms (+8 terminais) | `main()` → 1º quadro: 267–353 ms |
| **Emacs** | 3 597 / 3 288 / 3 288 ms | `emacs-init-time`: 2,60 / 2,44 / 2,43 s |

### Latência tecla → quadro (in-process, teclas sintéticas, N = 200)

| Loop | p50 | p95 | máx |
|---|---|---|---|
| **Por evento** (loop dormindo quando a tecla chega) | **2,8–3,0 ms** | 7,3–11,8 ms | 23–32 ms |
| Antigo (sempre renderizando a 60 fps) | 25,8 ms | 32,7 ms | 33,6 ms |

No loop antigo a tecla espera o próximo quadro (0–16,7 ms) e o `EndDrawing`
ainda segura o pacing de 60 fps. No novo, a tecla acorda o loop, que desenha
na hora (o quadro depois de dormir não espera pacing). O p95 maior que o p50
vem das teclas que caem num trecho em que o loop está acordado (refresh do
git, LSP respondendo). Digitando de verdade, depois da primeira tecla o loop
fica 1 s no fps cheio (como o antigo) — então a primeira tecla depois de
parado é a que mais ganha.

**Emacs: não medido.** Não há forma justa de medir in-process equivalente
no Emacs (o redisplay dele não expõe "fim do quadro" desenhado na tela) e
sem injeção de teclas real não dá para medir de fora nos dois do mesmo jeito.

## Resumo

| | Editor (por evento) | Emacs |
|---|---|---|
| CPU parado, 1 arquivo | ~0,6 % | ~0,4 % |
| CPU parado, + 8 terminais | ~0,7 % | — |
| RSS | ~103 MB (110 MB com 8 terminais) | ~197 MB |
| Abertura até o 1º quadro | ~0,29 s | ~3,3 s (init 2,4–2,6 s) |
| Tecla → quadro | p50 ~3 ms (in-process) | não medido |

Meta do ticket (< 1 % parado, com 1 arquivo e com 8 terminais): atingida.
