# language: pt
# Ticket #8 — T7 · Tela: resolvedor de conflitos estilo IntelliJ (painel `merge_resolver`)
# Mapeamento cenário → teste: comentário "# teste:" antes de cada cenário.

Funcionalidade: Resolvedor de conflitos em três painéis
  Para resolver conflitos de merge/rebase sem sair do editor
  Como usuário do editor
  Quero ver Local | Resultado | Remoto alinhados e decidir cada lado de cada conflito

  # teste: test_mr_parse_three_conflicts, test_mr_layout_aligned (+ manual: realce visual)
  Cenário: Três painéis alinhados com realce por conflito
    Dado um arquivo com 3 blocos de conflito de tamanhos diferentes
    Quando o resolvedor abre o arquivo
    Então o painel Local mostra o contexto mais as linhas "ours" de cada conflito
    E o painel Remoto mostra o contexto mais as linhas "theirs"
    E o Resultado mostra o arquivo com os marcadores
    E os três painéis têm o mesmo número de linhas visuais, com cada conflito começando na mesma linha

  # teste: test_mr_accept_first_replaces_second_appends, test_mr_accept_tracks_conflict_by_position, test_mr_ignore_unresolved_frees_other_side
  Cenário: Accept e Ignore independentes por lado
    Dado um conflito ainda com marcadores
    Quando aceito o lado Local
    Então o bloco com marcadores é substituído pelas linhas Local e o lado Local mostra ✓
    Quando aceito também o lado Remoto
    Então as linhas Remoto são anexadas abaixo e o conflito fica "both"
    E aceitar o conflito seguinte altera o conflito seguinte (não o já resolvido)
    E ignorar um lado de um bloco com marcadores apaga o bloco, mostra ✕ e deixa o outro lado disponível

  # teste: test_mr_newline_after_resolved_block, test_mr_last_conflict_without_newline
  Cenário: A quebra de linha após o bloco resolvido é preservada
    Dado um conflito seguido da linha "after"
    Quando aceito qualquer lado
    Então "after" continua numa linha própria

  # teste: test_mr_undo_restores_markers_resets_sides
  Cenário: Desfazer até os marcadores voltarem libera os dois lados
    Dado um conflito com o lado Local aceito e o Remoto ignorado
    Quando desfaço até os marcadores voltarem
    Então os dois lados voltam a "pendente" e o conflito volta a "não resolvido"

  # teste: test_mr_merge_flow_end_to_end, test_merge_resolve_refuses_markers
  Cenário: Done grava, faz stage e passa ao próximo arquivo; depois Commit merge
    Dado um merge parado com arquivos em conflito
    Quando resolvo um arquivo e aciono Done (Ctrl/Cmd+Enter)
    Então o arquivo é gravado sem marcadores, entra no stage e o próximo arquivo em conflito abre
    E Done é recusado com mensagem se ainda houver "<<<<<<<" ou ">>>>>>>" no início de linha
    E depois do último arquivo aparece "Commit merge" (ou "Continue rebase" num rebase)

  # teste: test_merge_abort_restores, test_merge_rebase_continue, test_mr_banner_for (+ manual: banner na janela)
  Cenário: Abortar restaura o estado; banner na janela principal
    Dado um merge com conflitos
    Então a janela principal mostra "N files in conflict - Resolve"
    Quando todos os arquivos estão no stage
    Então o banner passa a "Merge ready to commit - Commit"
    Quando aborto o merge
    Então o repositório volta ao estado anterior ao merge e o banner some

  # teste: test_mr_merge_flow_end_to_end
  Cenário: Repositório real — merge com 3 arquivos em conflito ponta a ponta
    Dado um repositório com as branches "main" e "feature" que conflitam em 3 arquivos
    Quando faço o merge, resolvo os 3 arquivos no resolvedor e aciono Commit merge
    Então HEAD é um commit de merge com 2 pais
    E a working tree fica limpa
