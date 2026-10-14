# language: pt
Funcionalidade: Vários repositórios abertos, recentes, clone/init e boas-vindas (ticket #13)
  Como desenvolvedor revisando o que sessões de IA mudaram em ~8 projetos
  Quero abrir vários repositórios ao mesmo tempo, um por aba
  Para trocar entre eles sem perder o estado de git, LSP e painéis de cada um

  # teste: test_repos_open_switch_close
  Cenário: Vários repositórios abertos, cada um com seu estado
    Dado os repositórios "a" e "b" abertos em abas
    E um arquivo aberto no repositório "a"
    Quando eu troco para "b" (aba, Ctrl/Cmd+Alt+2 ou "Repo: Switch...")
    Então e.git_mgr passa a ser o gerenciador git de "b"
    E a visão de "b" (painéis/buffers) é a dele, sem o arquivo de "a"
    Quando eu volto para "a"
    Então o arquivo de "a" volta aberto onde estava
    E abrir "a" de novo não cria aba duplicada

  # teste: test_repos_switch_changes_git_mgr
  Cenário: As telas de git usam o repositório ativo
    Dado os repositórios "a" e "b" abertos
    Quando uma tela enfileira "git rev-parse --show-toplevel" em e.git_mgr.queue com "a" ativo
    Então o resultado é a raiz de "a"
    Quando eu troco para "b" e repito
    Então o resultado é a raiz de "b"
    E o status do repositório em segundo plano continua sendo atualizado para a aba

  # teste: test_repos_open_many
  Cenário: Abrir várias pastas de uma vez
    Dado o diálogo "Repo: Open Folders..." com duas pastas marcadas (Shift+Enter)
    Ou duas pastas arrastadas e soltas na janela
    Quando eu confirmo (Ctrl+Enter)
    Então cada pasta abre na sua própria aba e a primeira fica ativa
    E uma pasta inexistente é reportada sem impedir as outras

  # teste: test_repos_open_errors_and_limit
  Cenário: Limite de repositórios abertos e caminhos inválidos
    Dado 16 repositórios abertos
    Quando eu abro mais um
    Então recebo "Too many open repositories (max 16)"
    E um caminho que não é pasta é recusado com "Not a folder"

  # teste: test_recent_repos_order_dedup_limit
  Cenário: Repositórios recentes
    Quando eu abro "a", depois "b", depois "a" de novo
    Então os recentes são "a", "b" (mais recente primeiro, sem duplicata)
    E a lista guarda no máximo 20 entradas, persistidas em ~/.config/editor/recent_repos

  # teste: test_repo_ops_clone_local_bare
  Cenário: Clonar por URL
    Dado um repositório bare local "origin.git"
    Quando eu clono "origin.git" em "work" pela fila git
    Então "work" tem os arquivos e o upstream "origin/main"
    E o progresso aparece no diálogo e o repositório abre numa aba nova
    E clonar de novo no mesmo destino falha com mensagem clara

  # teste: test_repo_ops_clone_bad_url
  Cenário: Clone com erro claro
    Quando eu clono uma URL inexistente
    Então vejo "Clone failed: repository not found (check the URL and your access)."
    E nenhum prompt de credencial bloqueia (GIT_TERMINAL_PROMPT=0)

  # teste: test_repo_ops_init
  Cenário: Iniciar repositório
    Quando eu inicio um repositório em uma pasta que ainda não existe
    Então a pasta é criada com ".git" e abre numa aba
    E iniciar sobre um arquivo falha com "Init failed: not a directory"

  # teste: test_session_restores_repos
  Cenário: Sessão reabre os repositórios da última vez
    Dado "a" (com um arquivo aberto) e "b" (ativo) abertos ao sair
    Quando o editor reabre sem argumentos
    Então "a" e "b" voltam em abas, "b" ativo, e o arquivo de "a" volta aberto

  # manual (visual)
  Cenário: Tela de boas-vindas
    Dado que nenhum repositório está aberto e nenhum arquivo está sendo editado
    Então vejo a tela de boas-vindas com recentes, abrir pasta(s), clonar e iniciar
    Quando eu abro um repositório
    Então a tela some e a aba do repositório aparece no topo
