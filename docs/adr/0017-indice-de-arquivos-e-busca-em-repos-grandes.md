# 0017 — Índice de arquivos em thread, listagem sem stat, ripgrep e git proporcional ao repo

Data: 2026-10-20

## Contexto

Em monorepos (1 GB+, centenas de milhares de arquivos) o editor travava e o
Windows marcava a janela como "não respondendo" ao usar Find File (Ctrl+P),
o filtro do file tree e a busca de texto. Medido num repo sintético de 250k
arquivos (`docs/perf-large-repos.md`) e lido no código:

- **Listagem de pasta cara, na thread da UI.** O iterador de diretório do
  `core:os` faz `fstatat` por entrada no POSIX e, no Windows, **abre cada
  arquivo** (`CreateFileW` + `GetFileInformationByHandleEx`) — com o
  antivírus inspecionando cada abertura. Ctrl+P e o filtro do tree passavam
  3000 entradas por quadro por esse iterador, na thread da UI.
- **Refiltragem a cada quadro.** O Ctrl+P rodava o match nos até 50k
  arquivos várias vezes por quadro (contagem + desenho), digitando ou não.
- **Resultados incompletos.** Os tetos (20k entradas no tree, 50k arquivos
  no Ctrl+P) cortavam um monorepo: o arquivo existia e não aparecia.
- **Busca de texto lenta e cega ao `.gitignore`.** Uma thread, um buffer de
  4 MB alocado por arquivo, lista fixa de pastas puladas: 72 s no repo
  sintético.
- **Git proporcional ao repo inteiro.** `git status` + `git diff HEAD` do
  repositório todo a cada 4 s; `git blame` síncrono na thread da UI; hash do
  status inteiro a cada quadro no file tree.
- **Goto definition / references sem LSP** liam o workspace inteiro na
  thread da UI.

## Decisão

1. **Um índice de arquivos por workspace, construído numa thread**
   (`ws_index.odin`). Dentro de um repo git: `git ls-files -z -c -o
   --deduplicate --exclude-standard` — rastreados + não rastreados, menos o
   `.gitignore`; o git responde do próprio índice. Fora de git (ou git
   velho sem `--deduplicate`): walk próprio sem stat. O resultado é um
   snapshot imutável com contagem de referências: a busca que está rodando
   nunca perde a lista; o snapshot atual continua servindo enquanto o
   próximo é construído (reconstrução quando tem mais de 3 s, ao abrir o
   Ctrl+P, ou quando o editor cria/renomeia/apaga arquivo). A opção
   `[editor] search_ignored_files` (Settings: "Search git-ignored files")
   inclui os ignorados, sempre sem `.git`, `node_modules` e as outras pastas
   de `WS_SKIP_DIRS`.
2. **Listagem de pasta sem acesso por arquivo** (`fast_dir*.odin`):
   `readdir` + `d_type` no POSIX (stat só para `DT_UNKNOWN`/symlink) e
   `FindFirstFileExW(FindExInfoBasic, FIND_FIRST_EX_LARGE_FETCH)` no Windows.
   Usada pelo file tree (expandir pasta), pelo diálogo de workspace e pelo
   walk de fallback. Links para pastas não são seguidos pelo walk.
3. **Na thread da UI só comparação de strings, com orçamento de tempo.**
   Ctrl+P e o filtro do tree percorrem o snapshot no máximo 4 ms por quadro,
   continuando no quadro seguinte (`frame_collect` mantém o loop acordado
   enquanto há trabalho). Sem teto de arquivos. No Ctrl+P, ao terminar,
   arquivos cujo **nome** contém a busca vêm primeiro, caminhos curtos antes.
4. **Busca de texto: ripgrep embutido no editor, pool de threads senão**
   (`search_fast.odin`, `ripgrep_bundled.odin`). O build de release baixa um
   ripgrep fixo (14.1.1, SHA-256 conferido, `scripts/fetch-ripgrep.sh`) para
   `bundled/` e o `#load` o embute no executável (+4 MB); na primeira busca
   ele é gravado uma vez na pasta de cache do usuário, com o hash no nome, e
   roda de lá — o editor não depende de nada instalado. Build local sem
   `bundled/` cai num `rg` instalado (PATH, Homebrew, cargo, scoop). No
   Windows o processo é criado com `CREATE_NO_WINDOW` (o editor não tem
   console; sem isso piscaria uma janela a cada busca). Saída lida em
   streaming; cancelar uma busca (nova tecla) **mata o processo** em vez de
   esperar. Sem `rg`: N threads sobre o snapshot, um buffer reaproveitado por
   thread, arquivos acima de 8 MB e binários pulados. Os dois devolvem o mesmo
   formato, agrupado por arquivo.
5. **Git proporcional ao que está aberto.** O refresh mede quanto levou e o
   próximo espera pelo menos 5× isso (até 60 s); além do timer, refresh ao
   salvar e ao voltar o foco para a janela. O `git diff` dos hunks (marcas na
   margem) só roda nos arquivos abertos nos painéis. `git blame` roda numa
   thread. O file tree só recalcula o hash do status quando o manager troca
   o status (`status_gen`). Se o status levar mais de 1,5 s e
   `core.fsmonitor` não estiver ligado, o editor sugere uma vez
   `git config core.fsmonitor true && git config core.untrackedCache true`.
6. **Goto definition / references sem LSP** percorrem o índice e param em
   1,5 s, avisando que a lista é parcial.

## Consequências

- Medido no repo sintético (macOS, M5): quadro mais lento durante Ctrl+P,
  filtro do tree e busca de texto entre 2 e 8 ms (antes 72 ms no Ctrl+P; no
  Windows o custo por arquivo aberto era a causa do "não respondendo"); lista
  do Ctrl+P completa (250k em vez de 50k); busca de texto 72 s → ~9,5 s, o
  mesmo tempo do `rg` direto nesta máquina (limitado pelo `open()` do
  sistema); cancelar uma busca em andamento 0,3 ms.
- Arquivos ignorados pelo `.gitignore` saem das buscas por padrão (antes
  saía só uma lista fixa de pastas). O file tree navegando pasta a pasta
  continua mostrando tudo que está no disco.
- O Ctrl+P e o filtro do tree passam a mostrar arquivos em pastas que
  começam com ponto e que estão no git (`.github/…`), como o `git ls-files`
  lista.
- Um arquivo criado fora do editor aparece nas buscas em até 3 s (ou ao
  reabrir o Ctrl+P).
- A busca com ripgrep usa a semântica dele para maiúsculas/minúsculas
  (Unicode); a interna continua ASCII.
- `perf_test.odin` reproduz as medições (`EDITOR_PERF_REPO=<repo>`).
