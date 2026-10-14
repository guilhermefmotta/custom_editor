# 0002 — Busca de texto com escopo de branch

Data: 2026-10-14 · Épico #1 · Ticket #12

## Contexto

A busca (Ctrl/Cmd+Shift+F) só olhava o disco. O ticket pede buscar em
qualquer branch local/remota sem checkout, de forma paralela, e ao abrir um
resultado perguntar entre checkout para editar ou abrir só leitura.

## Decisão

1. **Onde roda**: a busca de branch roda na thread da própria busca
   (`search_worker_proc` → `search_branch_run`), não na fila git. É uma
   busca, fora da UI; o ADR 0001 exige só "nada de git síncrono na thread da
   UI". As ações de tela (checkout, Smart Checkout, ler blob para só
   leitura) vão pela fila (`git_request_custom` / `git_request_file_at`).
2. **Como lê**: `git ls-tree -r -z -l <ref>` (com tamanho, para pular
   > 2 MB sem ler), depois os blobs são divididos em até 8 threads (no
   mínimo 64 blobs por thread), cada uma com **um** `git cat-file --batch`.
   Os ids vão por um arquivo temporário como stdin (sem thread escritora
   nem deadlock de pipe). Processos via `core:os` (`process_start`/`pipe`),
   portável macOS/Linux/Windows; `process_start` serializado por mutex.
   Binário = NUL nos 8 KiB iniciais. Limite `MAX_SEARCH_RESULTS`.
3. **stderr**: `git_run` descarta stderr, mas para saber se o checkout foi
   bloqueado por mudanças locais precisamos dele; `search_git_capture` usa
   `os.process_exec` (só fora da thread da UI).
4. **Só leitura**: o `Pane` não tem flag de somente leitura e `pane.odin`/
   `editor.odin` são compartilhados. O blob é gravado em
   `<temp>/editor-branch-view/<branch>/<caminho>` com permissão 0444 e
   aberto normalmente: salvar falha ("Save failed") e o arquivo do
   repositório nunca é tocado. Uma flag de somente leitura real no `Pane`
   fica para quando alguém precisar mexer em `pane.odin`.
5. **Smart Checkout**: `stash push -u` → `switch` (ou `switch -c --track`)
   → `stash pop`; se o `switch` falhar, o stash é reaplicado; conflito no
   pop mantém o stash e abre `ui_panel_open("merge_resolver")`.

## Consequências

- Medido (build debug, `odin test`, rastreador de memória ligado):
  este repositório (166 blobs) ~40 ms; git-crab (201) ~45–80 ms;
  repositório de 808 arquivos ~240–320 ms.
- Painel `search` registrado (só mostra o diálogo de confirmação).
