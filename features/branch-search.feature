# language: pt
Funcionalidade: Busca de texto com escopo de branch e checkout para editar
  Para achar código que só existe em outra branch sem trocar de branch
  Como usuário do editor
  Eu quero buscar texto no disco ou em qualquer branch local/remota
  e, ao abrir um resultado, escolher entre fazer checkout para editar ou só ler

  Contexto:
    Dado um workspace que é um repositório git

  Cenário: Seletor de escopo na busca
    Quando eu abro a busca com Ctrl+Shift+F (Cmd+Shift+F no macOS)
    Então vejo o escopo atual "workspace" ao lado da caixa de busca
    Quando eu pressiono Ctrl+B (ou clico no escopo)
    Então vejo a lista "Workspace (disco)", as branches locais e as remotas
    E ao escolher uma branch a busca passa a rodar nela
    # teste: test_search_scope_entries

  Cenário: Busca numa branch lê os blobs do git, sem checkout, em paralelo
    Dado a branch "feature" com um arquivo que contém "SOMENTE_NA_FEATURE"
    E a branch atual "main" que não contém esse texto
    Quando eu busco "somente_na_feature" com escopo "feature"
    Então o resultado aponta o arquivo e a linha certa na branch "feature"
    E o diretório de trabalho continua na "main", sem checkout
    E arquivos binários (NUL nos 8 KiB iniciais) e maiores que 2 MB são ignorados
    # teste: test_branch_search_finds_text_only_in_branch
    # teste: test_branch_search_skips_binary_and_large
    # teste: test_ls_tree_parse

  Cenário: Abrir resultado de branch não checada pergunta o que fazer
    Dado resultados de busca da branch local "feature", que não está checada
    Quando eu abro um resultado
    Então o editor pergunta "Checkout & editar", "Abrir só leitura" ou "Cancelar"
    E "Abrir só leitura" mostra o conteúdo da branch (git show) num arquivo protegido contra escrita
    E "Checkout & editar" troca para "feature" e abre o arquivo do disco
    # teste: test_open_decision
    # teste: test_checkout_existing_local_branch

  Cenário: Branch só no remoto cria a branch local com upstream
    Dado um remoto "origin" (repositório bare local) com a branch "remota-x"
    E nenhuma branch local "remota-x"
    Quando eu abro um resultado da busca em "origin/remota-x" e escolho "Checkout & editar"
    Então a branch local "remota-x" é criada rastreando "origin/remota-x" e fica checada
    # teste: test_checkout_creates_tracking_branch_from_remote

  Cenário: Mudanças locais que bloqueiam o checkout oferecem Smart Checkout
    Dado uma mudança local num arquivo que difere na branch alvo
    Quando o checkout falha por causa dessa mudança
    Então o editor oferece "Smart Checkout"
    E o Smart Checkout guarda as mudanças (stash -u), troca de branch e as reaplica (stash pop)
    E se a reaplicação conflitar, o resolvedor de merge é aberto
    # teste: test_checkout_blocked_then_smart_checkout
    # teste: test_smart_checkout_conflict_reported

  Cenário: Abrir resultado posiciona na linha com o termo destacado
    Quando eu abro um resultado da busca
    Então o cursor vai para a linha do resultado
    E o termo buscado fica selecionado (destacado) nessa linha
    # teste: test_search_place_cursor_selects_term
