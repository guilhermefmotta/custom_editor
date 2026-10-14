# language: pt
# Ticket #3 — F2 · Base: camada git assíncrona.
# Não há runner BDD: cada Cenário corresponde a testes @(test) em git/*_test.odin
# (rodar com `odin test ./git`).

Funcionalidade: Camada git assíncrona
  Para que as telas git do editor (grafo de commits, working tree, sidebar,
  resolvedor de conflitos, busca, histórico de arquivo) nunca travem a UI,
  como desenvolvedor de telas
  quero pedir consultas git a uma fila numa thread de trabalho
  e ler resultados prontos por id a cada frame.

  Contexto:
    Dado um repositório git real criado num diretório temporário

  # teste: test_queue_runs_jobs_off_main_thread
  # teste: test_queue_release_and_callbacks
  # teste: test_git_run_passes_args_verbatim
  Cenário: Comandos git rodam numa thread de trabalho com fila
    Quando a UI pede uma consulta com git_request_*
    Então a chamada retorna um id imediatamente, sem executar git na thread da UI
    E o resultado fica disponível por git_poll/git_poll_as quando a thread de trabalho termina
    E os pedidos são executados em ordem FIFO
    E um pedido liberado antes de rodar é descartado sem vazar memória
    E um callback registrado com git_on_done é chamado por git_queue_update na thread principal
    E os argumentos chegam ao git literalmente (aspas, $, crases, quebras de linha)

  # teste: test_log_paginated_with_parents_and_refs
  # teste: test_log_search_and_file_history
  Cenário: Log de commits paginado pronto para desenhar grafo
    Dado um histórico com merge, branches, tag anotada e um remoto
    Quando peço o log com skip e limit
    Então recebo uma página de commits em ordem topológica com hash, pais, autor, e-mail, data e assunto
    E cada commit traz suas refs (branch local com marca de HEAD, branch remota, tag)
    E a página informa se há mais commits depois dela
    E posso filtrar por revisão, por texto da mensagem e por caminho de arquivo

  # teste: test_commit_detail_and_file_diff
  Cenário: Arquivos alterados de um commit e diff do arquivo inteiro num commit
    Dado um commit raiz, um commit que modifica, adiciona, remove e renomeia arquivos, e um commit de merge
    Quando peço os detalhes de um commit
    Então recebo a mensagem completa e a lista de arquivos com o tipo de mudança (comparado ao primeiro pai)
    Quando peço o diff de um arquivo nesse commit
    Então recebo o arquivo inteiro lado a lado com as linhas alteradas marcadas
    E no commit raiz o arquivo aparece todo como adicionado

  # teste: test_branches_with_upstream_ahead_behind
  # teste: test_remotes_tags_stashes
  # teste: test_reflog_paginated
  # teste: test_submodules
  Cenário: Branches, remotos, tags, stashes, reflog e submódulos
    Dado um repositório com remoto, branches com upstream, tags, stashes e um submódulo
    Quando peço branches
    Então recebo branches locais e remotas, a atual marcada, com upstream e ahead/behind
    Quando peço remotos, tags, stashes, reflog e submódulos
    Então recebo cada lista com seus campos (URL, alvo da tag e se é anotada, índice e mensagem do stash, ação do reflog, estado do submódulo)

  # teste: test_file_at_revision
  # teste: test_conflict_stages_in_merge
  Cenário: Conteúdo de arquivo numa revisão e estágios de conflito
    Quando peço o conteúdo de um arquivo em HEAD, numa branch e num hash
    Então recebo o texto daquela revisão, e "ausente" quando o arquivo não existe nela
    Dado um merge parado com conflito num arquivo
    Quando peço os estágios de conflito desse arquivo
    Então recebo base, ours e theirs com os rótulos dos dois lados

  # teste: test_repo_state_operations
  Cenário: Estado do repositório
    Quando o repositório está limpo, em merge, rebase, cherry-pick ou revert
    Então o estado informa a operação correta como enum Repo_Operation (nome estável via repo_operation_name)
    E lista os arquivos em conflito
    E informa a branch atual e o hash de HEAD

  # teste: test_conflict_stages_in_merge
  # teste: test_repo_state_operations
  Cenário: Merge com conflito num repositório real
    Dado duas branches que alteram a mesma linha de um arquivo
    Quando faço merge de uma na outra
    Então o estado é "merging" com o arquivo na lista de conflitos
    E os estágios base/ours/theirs refletem cada lado
