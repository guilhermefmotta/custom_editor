# 0002 — Operações remotas: fila de rede própria e git não interativo

Data: 2026-10-14 · Ticket #7 (painel `remote_ops`) · Escopo: local ao ticket

## Contexto

Fetch/pull/push podem levar dezenas de segundos (rede lenta, host
inalcançável) ou ficar pendurados esperando credencial num prompt que
ninguém vê. A fila compartilhada `e.git_mgr.queue` tem um único worker FIFO:
uma operação de rede ali travaria todas as outras telas (log, status, diff).
`git_run` (`git/process*.odin`) descarta stderr e não aceita variáveis de
ambiente, e é arquivo compartilhado.

## Decisão

1. `remote_ops.odin` mantém uma `git.Git_Queue` própria (worker próprio) só
   para jobs de rede (fetch, push e a parte de fetch do pull). Ela é bombeada
   no `update` do painel e reinicializada quando a raiz do repo muda.
2. Pull = dois jobs: `Fetch_Upstream` na fila de rede, depois
   `Merge_Upstream` / `Rebase_Upstream` na fila compartilhada, serializados
   com as outras escritas no índice. Stash save/pop também na compartilhada.
3. `git/remote_ops_{posix,windows}.odin` têm um exec próprio que captura
   stdout+stderr, fecha stdin e define `GIT_TERMINAL_PROMPT=0`,
   `GCM_INTERACTIVE=never`, `LC_ALL=C` (mensagens estáveis para classificar)
   e, se o usuário não configurou ssh próprio, `GIT_SSH_COMMAND="ssh -o
   BatchMode=yes -o ConnectTimeout=15"`, mais `-c http.lowSpeedLimit/Time`.
   `process*.odin` não foi alterado.
4. Falhas viram `Remote_Op_Result{ok=false, kind, message}` (job `.Done`),
   com `kind` classificado a partir da saída do git.

## Consequências

- Uma operação de rede lenta não bloqueia as outras telas; ainda não há
  timeout duro do subprocesso (depende dos timeouts do ssh/http). Se um
  helper de credencial travar, só a fila de rede fica presa.
- Uma operação por vez no painel; nova tentativa durante uma em andamento
  mostra aviso.
