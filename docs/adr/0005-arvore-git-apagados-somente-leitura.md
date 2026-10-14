# ADR 0005 — Árvore de arquivos: status do git e arquivos apagados somente leitura (#11)

## Contexto
A árvore (`file_tree.odin`) precisa mostrar o status do git por arquivo/pasta,
listar arquivos apagados (que não existem no disco) e abrir a versão do HEAD
deles só para leitura. O editor não tem buffer/pane somente leitura
(`buffer.odin`/`pane.odin` sem flag) e `editor.odin`, `input.odin` e
`renderer.odin` são compartilhados.

## Decisão
- O status vem do `git.Git_Manager` (`e.git_mgr.current.entries`), sem processo
  git novo. A árvore guarda um índice (`Tree_Git_Index`, em `git_integration.odin`)
  com chaves relativas ao cwd (raiz da árvore), reconstruído só quando o hash do
  conteúdo do status muda (o manager troca o array a cada refresh de ~4s).
- A sincronização roda no `update` do painel registrado `tree_head_view`
  (o hook roda todo frame, aberto ou não) — nada novo em arquivos compartilhados.
- Apagados são injetados ao listar cada pasta (`ghost = true`); pastas que só
  têm apagados também são injetadas e cadeias de pasta única não são compactadas
  quando escondem apagados.
- "Abrir só leitura" é um painel overlay próprio (`tree_head_view`) que pede
  `git_request_file_at(HEAD, path)` pela fila e mostra o texto com rolagem. Não
  foi criado buffer somente leitura (exigiria mudar `pane.odin`/`input.odin`).
- Filtro "só alterados" (Ctrl+G na árvore) monta as linhas a partir do índice,
  com todas as pastas expandidas; pastas fechadas à mão ficam em `collapsed`.

## Consequências
- Sem edição de arquivos compartilhados. Se um dia houver buffer somente leitura,
  `_ft_open_node` é o único ponto a trocar.
- Pastas inteiras não rastreadas (`?? dir/`) aparecem no filtro como pasta que
  é lida do disco ao expandir; a expansão delas não sobrevive a um refresh de status.
