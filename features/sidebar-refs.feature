# language: pt
Funcionalidade: Sidebar de branches, tags, stashes, reflog e submódulos (#6)
  Como usuário do editor
  Quero ver e operar as referências do repositório numa barra lateral
  Para trocar de branch, integrar trabalho e gerenciar tags e stashes sem sair do editor

  Contexto:
    Dado um repositório git com um remoto "origin" (repositório bare local)
    E a sidebar aberta (painel "sidebar")

  Cenário: Branches locais com ahead/behind, remotas agrupadas e busca por seção
    Dado a branch local "main" rastreando "origin/main" com 1 commit à frente e 1 atrás
    E as branches remotas "origin/main" e "origin/feat" e "upstream/x"
    Quando a sidebar carrega as referências
    Então a branch "main" mostra o indicador "↑1 ↓1"
    E as branches remotas aparecem agrupadas sob "origin" e "upstream"
    Quando eu digito "fe" com a seleção na seção de remotas
    Então só a seção de remotas é filtrada e mostra "origin/feat"
    # teste: test_sidebar_rows_sections_and_remote_groups
    # teste: test_sidebar_filter_is_per_section
    # teste: test_sidebar_ahead_behind_label
    # teste: test_refs_snapshot_ahead_behind_with_bare_remote

  Cenário: Ações por menu de contexto numa branch
    Dado a branch local "feat" que não é a atual
    Quando eu abro o menu de contexto dela
    Então vejo "Checkout", "New branch from here...", "Rename...", "Delete...", "Merge into current", "Rebase current onto this" e "Push"
    E duplo clique na branch faz checkout
    E apagar pede confirmação e, se a branch não estiver mergeada, oferece apagar à força
    E merge ou rebase com conflito abre o painel "merge_resolver"
    E push publica a branch com "git push -u <remoto> <branch>"
    # teste: test_sidebar_menu_actions_by_row_kind
    # teste: test_refs_op_create_rename_delete_branch
    # teste: test_refs_op_delete_unmerged_needs_force
    # teste: test_refs_op_merge_and_rebase
    # teste: test_refs_op_merge_conflict_reports_conflicts
    # teste: test_refs_op_push_sets_upstream

  Cenário: Checkout bloqueado por mudanças locais oferece Smart Checkout ou forçar
    Dado uma mudança local em "a.txt" que conflita com a branch "other"
    Quando eu faço checkout de "other"
    Então o checkout é bloqueado por mudanças locais
    E a sidebar oferece "Smart Checkout" (stash, troca, restaura) ou "Force checkout"
    Quando eu escolho Smart Checkout
    Então a branch atual vira "other" e a mudança local é restaurada (ou o resolvedor de conflitos é aberto)
    Quando eu escolho forçar
    Então a branch atual vira "other" e a mudança local é descartada
    # teste: test_refs_op_checkout_blocked_then_smart
    # teste: test_refs_op_force_checkout_discards

  Cenário: Checkout de branch remota cria a local com upstream
    Dado a branch remota "origin/feat" sem branch local "feat"
    Quando eu faço checkout de "origin/feat"
    Então existe a branch local "feat" rastreando "origin/feat" e ela é a atual
    # teste: test_refs_op_checkout_remote_creates_tracking_branch

  Cenário: Tags, stashes, reflog e submódulos listados e operáveis
    Quando eu crio a tag "v1" (anotada ou leve) e depois apago
    Então a tag aparece e depois some da lista
    Dado um stash com uma mudança
    Quando eu aplico, faço pop ou apago o stash
    Então a mudança volta ao working tree e o stash sai da lista (pop/apagar)
    E o reflog e os submódulos aparecem em suas seções
    # teste: test_refs_op_tags
    # teste: test_refs_op_stashes
    # teste: test_refs_snapshot_lists_everything

  Cenário: Clicar numa branch filtra o grafo de commits
    Quando eu clico numa branch
    Então a sidebar chama sidebar_on_branch_activate com o nome da branch
    E abre o painel "commit_graph" (filtro ligado na integração: commit_graph_show_branch)
    # teste: test_sidebar_activate_records_branch (visual: manual)
