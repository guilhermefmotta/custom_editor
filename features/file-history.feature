# language: pt
# Ticket #10 — T9 · Tela: histórico de arquivo e blame (painel `file_history`).
# Não há runner BDD: cada Cenário corresponde a testes @(test) em
# file_history_test.odin (rodar com `odin test .`). O que é só visual é
# validado por build + teste manual (ver relatório do ticket).

Funcionalidade: Histórico de arquivo e blame
  Para entender quem mudou um arquivo, quando e por quê
  como usuário do editor
  quero ver os commits que alteraram o arquivo, o diff de cada um
  e o blame por linha do buffer que estou editando.

  Contexto:
    Dado um repositório git real criado num diretório temporário

  # teste: test_fh_history_lists_commits_following_renames
  # teste: test_fh_history_diff_per_commit_through_queue
  Cenário: Histórico de um arquivo com o diff do arquivo inteiro de cada commit
    Dado um arquivo alterado por três commits, um deles renomeando o arquivo
    E um commit que não toca o arquivo
    Quando abro o histórico do arquivo
    Então vejo os três commits que o alteraram, do mais novo ao mais antigo
    E o commit que não toca o arquivo não aparece
    E cada commit sabe o caminho do arquivo naquele commit (segue a renomeação)
    E ao selecionar um commit vejo o diff do arquivo inteiro contra o pai

  # teste: test_fh_blame_lines_with_author_and_summary
  # teste: test_fh_relative_time
  # teste: test_fh_blame_colors_by_commit
  Cenário: Blame por linha com autor, data relativa, commit, cor e mensagem
    Dado um arquivo com linhas vindas de dois commits diferentes
    Quando abro o blame do arquivo
    Então cada linha mostra autor, data relativa e hash curto do commit
    E linhas do mesmo commit têm a mesma cor e commits diferentes têm cores diferentes
    E passar o mouse numa linha mostra a mensagem do commit

  # teste: test_fh_open_targets_panel
  Cenário: Abrir pelo arquivo atual e pela árvore de arquivos
    Quando executo "Git: File History" ou "Git: Blame" com um arquivo aberto
    Então o painel file_history abre na aba correspondente com o arquivo do pane ativo
    E a árvore de arquivos pode abrir o mesmo painel com file_history_open(e, abs_path)

  # teste: test_fh_blame_uncommitted_lines_have_no_author
  Cenário: Linhas não commitadas aparecem sem autor
    Dado um arquivo commitado
    Quando edito o buffer inserindo uma linha nova sem salvar
    E abro o blame do arquivo
    Então a linha nova aparece sem autor, sem data e sem commit
    E as demais linhas mantêm o autor do commit
