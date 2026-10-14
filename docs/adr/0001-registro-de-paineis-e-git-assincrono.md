# 0001 — Registro de painéis/comandos via `@(init)` e git assíncrono

Data: 2026-10-14 · Épico #1

## Contexto

O épico #1 porta ~13 telas do Git Crab para o editor, executadas em paralelo
(um worktree por ticket). Hoje cada tela nova precisaria editar os mesmos
pontos centrais — `palette.odin` (lista de comandos), `input.odin` (despacho
de teclado) e `renderer.odin` (desenho) — o que faria todos os tickets
conflitarem nesses arquivos e serem serializados. Além disso, o `git` roda
como subprocesso: chamado na thread da UI, trava o editor (o Git Crab teve
travamentos com commits grandes).

## Decisão

1. **Registro de comandos e painéis** (ticket #2): cada tela vive no(s)
   seu(s) próprio(s) arquivo(s) e se registra numa procedure marcada com
   `@(init)` — comandos da paleta e painéis (procs de desenho, input,
   abrir/fechar, prioridade de foco). `palette.odin`, `input.odin` e
   `renderer.odin` só iteram o registro. Telas novas **não editam** esses
   três arquivos.
2. **Camada git assíncrona** (ticket #3): toda consulta/operação git nova
   passa pela fila da thread de trabalho do pacote `git`; a UI só lê
   resultados prontos. Nenhuma chamada git síncrona nova na thread da UI.
   Operações específicas de uma tela ficam em `git/<tela>_ops*.odin`.
3. **Componentes de UI** compartilhados (`ui_*.odin`): lista, abas,
   divisor, confirmação, menu de contexto, banner — as telas usam esses em
   vez de redesenhar à mão como `git_dialog.odin` faz hoje.

## Consequências

- Telas sem arquivos em comum rodam em paralelo; o escalonador só
  serializa quem realmente compartilha arquivo (ex.: #5 e #8 em
  `git_dialog.odin`).
- Ordem de inicialização de `@(init)` não é garantida entre arquivos: o
  registro não pode depender de ordem (ordenar por nome/prioridade ao ler).
- Tickets #2 e #3 bloqueiam todas as telas; se a API do registro ou da
  camada git precisar mudar depois, muda neste ADR primeiro.

### API da camada git (ticket #3)

- Fila: `Git_Queue` (em `git/queue.odin`, documentada no topo do arquivo),
  embutida em `Git_Manager.queue`; uma thread de trabalho por repositório,
  iniciada no primeiro pedido, execução FIFO. `git_manager_update` já bombeia
  a fila (callbacks) a cada frame.
- Pedido → id: `git_request_log/commit_detail/commit_file_diff/branches/
  remotes/tags/stashes/reflog/submodules/file_at/conflict/repo_state/command/
  custom(...)` retornam `Job_Id` na hora.
- Leitura: `git_poll_as(q, id, T)` por frame (`.Queued/.Running/.Done/.Failed/
  .Unknown`) ou `git_on_done(q, id, cb, user)` (callback na thread principal,
  resultado liberado logo depois). `git_release(q, id)` libera tudo do
  resultado (arena por job) e cancela se ainda não terminou.
- Operações de tela (`git/<tela>_ops*.odin`) são `Git_Work_Proc` enfileiradas
  com `git_request_custom`; dentro delas `context.allocator` é a arena do job
  e as consultas síncronas `git_query_*` (`git/queries.odin`) podem ser usadas.
- Estado de operação é o enum `Repo_Operation`; a UI compara o enum, nunca
  strings (`repo_operation_name` dá nomes estáveis só para exibição/log).
