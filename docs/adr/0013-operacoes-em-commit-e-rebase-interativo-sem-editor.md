# 0013 — Operações em commit e rebase interativo sem editor externo

Data: 2026-10-14 · Ticket #9 (épico #1)

## Contexto

O grafo (#4) precisa de cherry-pick, revert, reset soft/mixed/hard, rebase
interativo, criar branch/tag e copiar hash num commit. Todo git roda na fila
(ADR 0001), sem terminal: qualquer comando que abra um editor (`revert`,
`squash`/`reword` do rebase, o próprio todo do `rebase -i`) travaria o worker.
O `git_run` descarta o stderr e não aceita variáveis de ambiente. O Git Crab
resolvia o rebase com um script `.sh` temporário em `GIT_SEQUENCE_EDITOR`
(não funciona sem bit de execução / no Windows sem sh no PATH do processo).

## Decisão

1. Painel registrado `commit_ops` (`commit_ops.odin`, overlay, prioridade 70,
   acima do grafo): menu de contexto, confirmação, prompt de nome/mensagem e a
   lista do rebase interativo. O grafo só chama `commit_ops_open_menu` (clique
   direito numa linha, tecla Menu ou Shift+F10) e expõe
   `commit_graph_reload`.
2. Operações em `git/commit_ops.odin` (`git_request_commit_op`,
   `git_request_rebase_commits`, `git_request_rebase_interactive`), rodando com
   o `_remote_exec` do #7 (env extra, stderr capturado, stdin fechado) e o env
   `GIT_EDITOR=":"` (no-op interno do git, portável), `GIT_MERGE_AUTOEDIT=no`,
   `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`. As variáveis de ambiente vencem
   `core.editor`/configuração do usuário, por isso env e não `-c`.
3. Rebase interativo: o todo é gerado pelo editor (`rebase_todo_build`, puro)
   e gravado em `<git-dir>/custom-editor-rebase/todo`;
   `GIT_SEQUENCE_EDITOR="cp '<todo>'"` (o git executa o editor via `sh`, que
   o Git for Windows traz; caminhos com `/` do `rev-parse --absolute-git-dir`,
   aspas simples POSIX). Nada de script com bit de execução.
   - reword = `pick` + `exec git commit --amend --allow-empty --no-verify
     --cleanup=strip -F '<msg-N.txt>'` (mensagem num arquivo; sem editor);
   - squash mantém a mensagem combinada do git (comentários removidos pelo
     cleanup), fixup mantém a primeira;
   - drop e reordenação são só o todo. Commits de merge do intervalo são
     achatados (aviso na UI), como `rebase -i` sem `--rebase-merges`.
   - Os arquivos ficam no git dir até o próximo rebase (as linhas `exec`
     ainda precisam das mensagens se o rebase parar), e são apagados quando
     ele termina limpo.
   - Recusado com mudanças rastreadas na working tree ou outra operação em
     andamento; validação pura (`rebase_steps_validate`): primeiro commit
     mantido não pode ser squash/fixup, reword não pode ser vazio.
4. Resultado `Commit_Op_Result{outcome = Ok|Failed|Conflicts|Stopped,
   operation, conflicts}`: após falha o job consulta `git_query_repo_state`.
   `Conflicts`/`Stopped` → banner + `ui_panel_open("merge_resolver")` (#8, que
   é dono de continue/abort). Cherry-pick/revert que não tem o que aplicar é
   abortado e vira `Failed` (repo volta limpo). Merge commits usam `-m 1`.
5. Reset hard sempre passa por `ui_confirm` (perigo); soft/mixed rodam direto.
   Criar branch/tag reaproveita `git_request_refs_op` (`git/refs_ops.odin`).
   Depois de qualquer operação: `git_manager_refresh_now` + `commit_graph_reload`.

## Consequências

- Nenhum editor externo é aberto em nenhuma operação deste painel.
- Depende de `sh`/`cp` do git no Windows (presentes no Git for Windows); não
  testado em Windows nesta entrega (`odin check -target:windows` exige SDK).
- O `exec` do reword roda hooks de `commit` apenas se o usuário os tiver e
  `--no-verify` não cobrir (post-commit roda).
