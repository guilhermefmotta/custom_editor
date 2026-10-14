# 0005 — Painel working tree: git_dialog vira host de Diff/Merge, stage/unstage all seguros em merge

Data: 2026-10-14 · Ticket #5 (épico #1)

## Contexto

O modo Status do `git_dialog.odin` (lista de arquivos + commit) chamava git
síncrono na thread da UI e não era registrado (ADR 0001). No Git Crab,
`unstage_all` com reset mixed abortava o merge em andamento e `stage_all`
colocava arquivos em conflito no stage, com os marcadores.

## Decisão

1. O working tree é o painel registrado `working_tree` (`working_tree*.odin`).
   O `git_dialog.odin` deixa de ter tela própria: `.Status` passa a ser o
   estado ocioso (o diálogo se esconde) e ele só hospeda o modo Diff, o modo
   Merge (legado, será substituído pelo #8) e o seletor de branch.
   `git_dialog_open` (comando "Git" da paleta) abre o painel.
2. O diff do arquivo inteiro é buscado pela fila (`Wt_Op.File_Diff`, texto
   bruto) e entregue ao modo Diff com `git_dialog_show_diff`, que assume a
   posse do `File_Diff`.
3. Operações em `git/worktree_ops.odin` (`git_request_wt`):
   - stage all = `git add -A -- <paths>` apenas dos caminhos não conflitados
     (`git diff --name-only --diff-filter=U`);
   - unstage all = `git reset -q -- <paths staged>` (repo sem commits:
     `git rm --cached`), nunca reset sem paths; conflitados ficam de fora;
   - stage de um arquivo conflitado que ainda tem marcadores é recusado;
   - hunk = patch do hunk + `git apply --cached [--reverse]` via arquivo
     temporário no git dir (o `git_run` não tem stdin).

## Consequências

Nenhuma chamada git síncrona nova na UI. O modo Merge e o seletor de branch
continuam com o git síncrono herdado até serem substituídos (#8, #6).
