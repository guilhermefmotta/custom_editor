# language: pt
# Ticket #5 — T4 · Tela: working tree (painel `working_tree`).
# Não há runner BDD: cada Cenário corresponde a testes @(test) em
# git/worktree_ops_test.odin (`odin test ./git`, repositório git real
# temporário) e working_tree_test.odin (`odin test .`, lógica pura da tela).
# O que é visual (desenho, atalhos, mouse) é validado por build + teste manual.

Funcionalidade: Working tree (stage, unstage, descartar, commit)
  Para preparar commits sem sair do editor
  como desenvolvedor
  quero ver as mudanças do repositório agrupadas e operar sobre elas
  sem nunca estragar um merge em andamento.

  Contexto:
    Dado um repositório git real criado num diretório temporário

  # teste: test_wt_sections_group_and_count
  Cenário: Seções Conflitos, Staged, Unstaged e Untracked com contagem
    Dado um arquivo em conflito, um arquivo staged, um modificado e um não rastreado
    Quando o painel working tree monta as seções
    Então aparecem as seções "Conflitos", "Staged", "Unstaged" e "Untracked" nessa ordem
    E cada cabeçalho mostra a quantidade de arquivos da seção
    E um arquivo com mudanças staged e não staged aparece nas duas seções
    E um arquivo em conflito aparece só em "Conflitos"

  # teste: test_wt_stage_unstage_file
  # teste: test_wt_stage_unstage_hunk
  # teste: test_wt_discard_and_ignore
  # teste: test_wt_queue_ops_and_refresh_order
  Cenário: Stage/unstage por arquivo e por hunk, descartar e .gitignore
    Dado um arquivo modificado em dois trechos distantes
    Quando faço stage só do primeiro hunk
    Então o índice contém apenas o primeiro trecho e o segundo continua unstaged
    E fazer unstage desse hunk volta o índice ao HEAD
    E stage/unstage do arquivo inteiro move o arquivo entre Staged e Unstaged
    E descartar (após confirmação na tela) restaura o arquivo, e apaga um não rastreado
    E "adicionar ao .gitignore" acrescenta o caminho ao .gitignore sem quebrar linhas existentes

  # teste: test_wt_stage_all_skips_conflicts
  Cenário: Stage all nunca coloca no stage um arquivo em conflito
    Dado um merge parado com conflito em "c.txt" (com marcadores) e outras mudanças
    Quando executo stage all
    Então as outras mudanças ficam staged
    E "c.txt" continua em conflito (entrada não mesclada no índice, listada em --diff-filter=U)
    E o merge continua em andamento

  # teste: test_wt_unstage_all_keeps_merge
  Cenário: Unstage all durante um merge mantém o merge em andamento
    Dado um merge com conflito resolvido e adicionado ao índice
    Quando executo unstage all
    Então nada fica staged
    E MERGE_HEAD continua existindo
    E o conteúdo resolvido do arquivo no disco é preservado

  # teste: test_wt_commit_amend_undo
  # teste: test_wt_commit_shortcut
  Cenário: Commit com mensagem, amend e desfazer o último commit
    Dado mudanças staged
    Quando escrevo a mensagem e pressiono Ctrl/Cmd+Enter
    Então um commit é criado com essa mensagem
    E com "amend" marcado o último commit é reescrito (mesmo pai, nova mensagem)
    E "desfazer último commit" faz soft reset: HEAD volta ao pai e as mudanças continuam staged
    E desfazer o commit inicial (sem pai) é recusado com mensagem de erro

  # teste: test_wt_file_diff_raw
  # manual: clicar num arquivo no painel abre o modo Diff do git_dialog
  Cenário: Clicar num arquivo abre o diff do arquivo inteiro
    Dado um arquivo modificado ou não rastreado
    Quando clico no arquivo no painel working tree
    Então abre a visão de diff lado a lado do arquivo inteiro (modo Diff do git_dialog)
    E Esc volta para o painel working tree
