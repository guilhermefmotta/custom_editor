# language: pt
Funcionalidade: Grafo de commits e detalhe do commit (painel `commit_graph`)
  Como desenvolvedor
  Quero ver o histórico do repositório como um grafo navegável
  Para entender branches, merges e o que cada commit alterou

  Contexto:
    Dado um repositório git aberto no editor

  # teste: commit_graph_layout_test.odin (todos os testes de raias)
  Cenário: Raias coloridas com badges, autor e data relativa
    Quando eu abro o painel "Git: Commit Graph" (Ctrl+Alt+G)
    Então cada commit aparece numa raia com cor própria da branch
    E os commits com branch, tag ou HEAD mostram badges com o nome da ref
    E cada linha mostra o autor e a data relativa ("3 hours ago")

  # teste: test_cg_relative_time
  Cenário: Data relativa legível
    Dado um commit feito há 2 dias
    Então a data aparece como "2 days ago"

  # teste: test_commit_graph_paging_large_repo (git/commit_graph_ops_test.odin)
  Cenário: Paginação incremental em repositório grande
    Dado um repositório com 5000 commits
    Quando eu rolo até o fim da lista carregada
    Então a próxima página de commits é pedida à fila git e anexada ao grafo
    E cada página é obtida em menos de 2 segundos
    E só as linhas visíveis são desenhadas

  # teste: test_commit_search_message_author_hash, test_commit_search_branch_filter
  Cenário: Busca por mensagem, autor ou hash
    Quando eu digito "fix" no campo de busca
    Então a lista mostra só os commits cuja mensagem, autor ou hash corresponde

  # teste: test_commit_search_branch_filter
  Cenário: Filtro do grafo por branch
    Quando eu escolho a branch "feature" no seletor de branch (Ctrl+B)
    Então o grafo mostra apenas os commits alcançáveis por "feature"

  # teste: test_commit_detail_files (git/commit_graph_ops_test.odin)
  Cenário: Detalhe do commit selecionado
    Quando eu seleciono um commit no grafo
    Então o painel de detalhe mostra mensagem, autor, data, hash, pais e refs
    E a lista de arquivos alterados naquele commit

  # teste: test_commit_detail_files (diff do arquivo via git_diff_commit_file)
  Cenário: Diff do arquivo inteiro de um commit
    Dado um commit selecionado com arquivos alterados
    Quando eu abro um arquivo da lista (Enter ou duplo clique)
    Então vejo o diff lado a lado do arquivo inteiro naquele commit
    E apenas um arquivo é carregado por vez

  # teste: test_graph_linear, test_graph_branch_merge, test_graph_parallel_branches,
  #        test_graph_octopus, test_graph_multiple_roots, test_graph_page_continuity
  Cenário: Cálculo das raias é lógica pura testada
    Dado commits em ordem de grafo com seus pais
    Quando as raias são calculadas página a página
    Então merges, branches paralelas, octopus e raízes múltiplas ficam em raias consistentes
    E o resultado é o mesmo que calcular tudo de uma vez
