# 0012 — Resolvedor de conflitos em três painéis: documento próprio com rastreamento por posição

Data: 2026-10-14 · Ticket #8 (épico #1)

## Contexto

O modo Merge do `git_dialog.odin` mostrava um conflito por vez (ours/theirs),
reconstruía o arquivo por offsets fixos e fazia stage com git síncrono na
thread da UI. O comportamento aprovado é o do Git Crab
(`ThreePaneEditor.tsx`, `MergeWorkspace.tsx`, `cm/conflictExt.ts`), que
também carregava bugs já corrigidos lá: conflitos indexados re-parseando
marcadores (o Accept caía no conflito errado depois do primeiro resolvido e
todos apareciam "não resolvidos" até o último), `GitOperation` comparado
como string com caixa errada (Commit merge nunca commitava) e a janela
principal sem atualizar depois do commit.

## Decisão

1. Painel registrado `merge_resolver` (`merge_resolver.odin`, prioridade 80,
   `.Overlay`, Ctrl/Cmd+Alt+M, comandos "Git: Resolve Conflicts",
   "Git: Abort Merge / Rebase", "Git: Commit Merge / Continue Rebase").
   O modo Merge do `git_dialog` foi removido; `git_dialog_open_merge` e o
   seletor de branch abrem o painel (`merge_resolver_open_file`).
2. **Edição do Resultado: editor de texto simples dentro do painel**, não o
   `Buffer`/pane do editor. Motivo: o resolvedor precisa (a) mapear cada
   bloco de conflito por cada mudança, inclusive undo/redo, e (b) alinhar
   três painéis linha a linha com linhas fantasmas; o `Buffer` não expõe
   mudanças como (from, to, insert) nem permite decorações/linhas fantasmas,
   e acoplar o undo dele exigiria mexer em arquivos compartilhados. O modelo
   puro fica em `merge_resolver_model.odin` (sem raylib, testado):
   - documento = bytes; toda edição é `mr_edit(from, to, insert)` com pilha
     de undo/redo de mudanças (digitação contígua não é agrupada: cada tecla é
     um passo; aceitável para o tamanho das edições aqui);
   - cada conflito original i é rastreado por posição (`blocks[i]`), mapeado
     por toda mudança como o `mapPos` do CodeMirror (`from` assoc −1, `to`
     assoc +1). Nunca re-parsear marcadores para indexar conflitos;
   - estados por lado Pending/Applied/Ignored; o primeiro Accept substitui o
     bloco preservando o `\n` final, o segundo anexa abaixo; Ignore num bloco
     com marcadores apaga o bloco e libera o outro lado; quando um undo traz
     os marcadores de volta os dois lados voltam a Pending;
   - painéis Local/Remoto são reconstruídos do próprio arquivo com marcadores
     (contexto + linhas daquele lado; seção base do diff3 descartada), o que
     garante o alinhamento conflito a conflito; `mr_layout` gera as linhas
     visuais (com fantasmas) dos três painéis, que rolam juntos.
   Cursor, setas, Home/End, PgUp/PgDn, Backspace/Delete, Enter, Tab, colar e
   clique para posicionar; sem seleção nem realce de sintaxe.
3. Operações em `git/merge_ops.odin`, sempre pela fila (`git_request_custom`):
   `git_request_merge_load` (conteúdo + rótulos via `git_query_conflict`),
   `git_request_merge_resolve` (recusa `<<<<<<<`/`>>>>>>>` no início de
   linha, grava e `git add`; arquivo apagado → `git rm`),
   `git_request_merge_complete` e `git_request_merge_abort`. Complete/abort
   escolhem o comando pelo enum `git.Repo_Operation` lido do repositório no
   próprio job: `commit --no-edit`, `rebase|cherry-pick|revert --continue`
   (com `-c core.editor=true`), `merge|rebase|cherry-pick|revert --abort`,
   `reset --merge` para conflitos sem operação (stash pop). Cada resultado
   traz o `Repo_State` logo depois da operação.
4. Depois de commit/abort: `git_manager_refresh_now`, `sidebar_refresh` e
   releitura imediata do estado para o banner.
5. Banner da janela principal (`ui_banner`, sem editar `ui_banner.odin`):
   o `update` do painel lê `git_request_repo_state` a cada 3 s e mostra,
   fixo, "N files in conflict - Resolve" ou "Merge ready to commit -
   Commit" (rebase/cherry-pick/revert: "Continue"). Clicar no texto (fora do
   X) ou Ctrl/Cmd+Alt+M abre o painel; o X dispensa até o estado mudar. Os
   textos ficam em inglês como o resto da UI; a fonte não tem ✓/✕/—, então
   ✓ e ✕ são desenhados com linhas.

## Consequências

- Done (Ctrl/Cmd+Enter) só grava sem marcadores e pula para o próximo
  arquivo não resolvido; depois do último aparece "Commit merge" /
  "Continue rebase". Num rebase que para de novo, a lista recarrega.
- Trocar de arquivo com edições não salvas pede confirmação.
- Arquivo binário: só Skip (resolver fora do editor), como no Git Crab.
- O editor do Resultado é deliberadamente mínimo; se um dia o `Buffer`
  expuser mudanças e decorações, o modelo de blocos pode ser ligado a ele
  sem mudar a lógica de Accept/Ignore.
