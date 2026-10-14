# language: pt
Funcionalidade: Árvore de arquivos com status do git e filtro só alterados (#11)
  Para enxergar o que mudou no repositório sem sair da árvore de arquivos
  Como pessoa editando código num repositório git
  Eu quero ver o status de cada arquivo e pasta na árvore (Ctrl+;)

  Contexto:
    Dado um repositório git aberto no editor
    E o status vindo do git.Git_Manager (e.git_mgr.current.entries)

  Cenário: Arquivos marcados com letra e cor do Git Crab
    Dado arquivos com status porcelain " M", "M ", "MM", "A ", "AM", "??", " D", "D ", "R ", "RM", "UU", "AA", "DD", "DU", "UD", "AU", "UA"
    Quando eu abro a árvore de arquivos
    Então modificados mostram "M" em amarelo
    E novos no stage mostram "A" em verde
    E não rastreados mostram "U" em verde
    E apagados mostram "D" em vermelho com o nome riscado
    E renomeados mostram "R" em azul
    E conflitos (UU, AA, DD, DU, UD, AU, UA) mostram "!" em roxo
    # teste: test_tree_git_classify_porcelain
    # teste: test_tree_git_letters_and_colors
    # teste: test_tree_git_real_repo_status

  Cenário: Pastas com mudança dentro mostram um ponto na cor da mudança mais importante
    Dado uma pasta com um arquivo não rastreado, um modificado e um em conflito em subpastas
    Quando eu vejo a pasta na árvore
    Então ela mostra um ponto na cor de conflito
    E a prioridade é conflito > apagado > modificado > renomeado > adicionado > não rastreado
    # teste: test_tree_git_index_dir_priority
    # teste: test_tree_git_index_untracked_dir

  Cenário: Arquivos apagados aparecem na árvore e abrem a versão do HEAD só para leitura
    Dado um arquivo versionado que foi apagado do disco
    Quando eu abro a pasta dele na árvore
    Então o arquivo aparece riscado com "D", mesmo não existindo no disco
    E uma pasta cujos arquivos foram todos apagados também aparece
    Quando eu dou Enter no arquivo apagado
    Então o conteúdo do HEAD abre num painel somente leitura
    # teste: test_tree_git_deleted_children
    # teste: test_tree_git_inject_deleted
    # teste: test_tree_git_real_repo_status (conteúdo do HEAD via git_query_file_at)
    # manual: Enter abre o painel "tree_head_view" e não é possível editar

  Cenário: Filtro só alterados com as pastas já expandidas
    Dado arquivos alterados em pastas aninhadas
    Quando eu aperto Ctrl+G na árvore
    Então só os arquivos alterados aparecem, com todas as pastas expandidas
    E pastas fechadas manualmente continuam fechadas até o filtro ser desligado
    # teste: test_tree_git_changed_rows
    # teste: test_tree_git_changed_rows_collapsed

  Cenário: Status atualiza quando o git muda
    Dado a árvore aberta
    Quando o refresh do Git_Manager traz um status diferente
    Então as marcas e os apagados injetados são recalculados mantendo pastas expandidas e seleção
    E um refresh com o mesmo status não reconstrói a árvore
    # teste: test_tree_git_status_hash
    # manual: alterar um arquivo com a árvore aberta e ver a marca aparecer em até ~4s
