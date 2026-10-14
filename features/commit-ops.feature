# language: pt
Funcionalidade: Operações em commit (cherry-pick, revert, reset, rebase interativo)
  Como usuário do grafo de commits
  Quero agir sobre um commit pelo menu de contexto
  Para reaplicar, desfazer, mover o HEAD e reescrever o histórico sem sair do editor

  Contexto:
    Dado um repositório git aberto no editor
    E o grafo de commits ("commit_graph") aberto com um commit selecionado

  Cenário: Menu de contexto no grafo
    Quando eu clico com o botão direito numa linha do grafo, ou aperto a tecla Menu / Shift+F10
    Então vejo as ações Cherry-pick, Revert, Reset soft, Reset mixed, Reset hard, Rebase interativo, Criar branch aqui, Criar tag aqui e Copiar hash
    # teste: test_commit_ops_menu_items

  Cenário: Cherry-pick de um commit de outra branch
    Dado um commit em outra branch que não conflita com a minha
    Quando eu escolho "Cherry-pick"
    Então um novo commit com a mesma mudança é criado sobre o HEAD
    E o grafo é recarregado
    # teste: test_commit_ops_cherry_pick

  Cenário: Cherry-pick com conflito abre o resolvedor
    Dado um commit de outra branch que altera as mesmas linhas que a minha
    Quando eu escolho "Cherry-pick"
    Então o repositório fica no estado Cherry_Picking com arquivos em conflito
    E o painel "merge_resolver" é aberto
    # teste: test_commit_ops_cherry_pick_conflict

  Cenário: Revert de um commit
    Quando eu escolho "Revert" num commit
    Então um commit novo desfazendo a mudança é criado, sem abrir editor de mensagem
    # teste: test_commit_ops_revert

  Cenário: Reset soft, mixed e hard
    Quando eu escolho "Reset soft" num commit anterior
    Então o HEAD aponta para ele e as mudanças desfeitas ficam no índice
    Quando eu escolho "Reset mixed"
    Então as mudanças ficam só na working tree
    Quando eu escolho "Reset hard"
    Então uma confirmação explícita é pedida
    E ao confirmar índice e working tree ficam iguais ao commit
    # teste: test_commit_ops_reset_soft_mixed_hard
    # teste: test_commit_ops_reset_hard_needs_confirm

  Cenário: Criar branch e tag no commit
    Quando eu escolho "Criar branch aqui" ou "Criar tag aqui" e digito um nome
    Então a branch/tag é criada no commit (operação reaproveitada de git/refs_ops.odin)
    # verificação: build + teste manual (lógica coberta por git/refs_ops_test.odin)

  Cenário: Copiar hash
    Quando eu escolho "Copiar hash"
    Então o hash completo vai para a área de transferência
    # verificação: teste manual

  Cenário: Rebase interativo com reordenação, reword, squash, fixup e drop
    Dado o painel "commit_ops" aberto com os commits posteriores ao selecionado
    Quando eu reordeno commits e marco pick/reword/squash/fixup/drop
    E inicio o rebase
    Então o histórico resultante segue a nova ordem, mensagens e combinações, sem abrir editor externo
    # teste: test_commit_ops_rebase_interactive
    # teste: test_rebase_todo_build
    # teste: test_rebase_steps_validate
    # teste: test_rebase_step_move

  Cenário: Conflito no rebase interativo abre o resolvedor
    Dado um rebase interativo cuja reordenação conflita
    Quando o rebase para por conflito
    Então o repositório fica no estado Rebasing e o painel "merge_resolver" é aberto
    # teste: test_commit_ops_rebase_conflict
