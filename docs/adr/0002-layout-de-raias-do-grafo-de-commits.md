# 0002 — Layout de raias incremental do grafo de commits

Data: 2026-10-14 · Épico #1 · Ticket #4 (decisão local da tela `commit_graph`)

## Contexto

A fila git (#3) entrega `Log_Page` em ordem de grafo (`--date-order`) com os
pais de cada commit, sem colunas. O grafo precisa aguentar 10 mil+ commits
com paginação incremental, e o Git Crab só desenhava linhas verticais (sem
arestas de merge), recalculando tudo de uma vez.

## Decisão

1. **Layout puro e incremental** (`commit_graph_layout.odin`): `Graph_Layout`
   guarda as raias abertas (hash esperado em cada raia + cor) entre chamadas;
   `graph_layout_add(hash, parents)` gera a linha do commit com segmentos
   `.Pass` (raia atravessa), `.In` (raia converge no nó, metade de cima) e
   `.Out` (nó sai para a raia do pai, metade de baixo). O primeiro pai herda a
   raia/cor; os demais entram numa raia que já espera por eles ou abrem uma
   nova (próxima cor de 8). Raias livres no fim são removidas. Alimentar
   página a página dá o mesmo resultado que tudo de uma vez (testado).
2. **Páginas mantidas vivas**: os resultados de `git_request_log` (500 por
   página) não são copiados; a tela guarda os `Job_Id` e aponta para os
   commits na arena de cada job até reset/fechar. As strings de hash usadas
   pelo layout são emprestadas dessas páginas.
3. **Busca sem grafo**: resultados de busca (mensagem/autor/hash, op
   `git/commit_graph_ops.odin`) não são contíguos na história, então aparecem
   como lista plana sem raias (como no Git Crab).
4. **Virtualização**: só as linhas visíveis do grafo, da lista de arquivos e
   do diff são desenhadas; o diff é de um arquivo por vez.

## Consequências

- Memória proporcional ao histórico já rolado (~500 commits por arena).
- `--skip` refaz a caminhada a cada página; medido em 5000 commits: página
  mais lenta < 0,4 s (teste `test_commit_graph_paging_large_repo`).
- Se o histórico mudar entre páginas (commit novo), F5 recarrega do zero.
