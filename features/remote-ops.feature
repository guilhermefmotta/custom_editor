# language: pt
Funcionalidade: Operações remotas e stash (ticket #7, painel "remote_ops")
  Como usuário do editor
  Quero buscar, puxar, enviar e guardar alterações sem sair do editor
  Para sincronizar com o remoto sem travar a interface

  Contexto:
    Dado um repositório local "work" clonado de um remoto bare "origin"

  # teste: test_remote_ops_fetch_all
  Cenário: Fetch de todos os remotos
    Dado que outro clone enviou um commit novo para "origin/main"
    Quando eu executo "Git: Fetch All"
    Então "origin/main" no repositório local aponta para o commit novo
    E a operação roda na fila de rede, sem bloquear a thread da UI

  # teste: test_remote_ops_pull_merge
  Cenário: Pull com merge
    Dado que "main" local e "origin/main" divergiram sem conflito
    Quando eu executo "Git: Pull (Merge)"
    Então HEAD é um commit de merge com dois pais
    E o repositório fica limpo

  # teste: test_remote_ops_pull_rebase
  Cenário: Pull com rebase
    Dado que "main" local e "origin/main" divergiram sem conflito
    Quando eu executo "Git: Pull (Rebase)"
    Então o histórico local fica linear sobre "origin/main"

  # teste: test_remote_ops_push
  Cenário: Push
    Dado um commit local ainda não enviado
    Quando eu executo "Git: Push"
    Então "main" no remoto aponta para o commit local

  # teste: test_remote_ops_push_rejected
  Cenário: Push rejeitado por non-fast-forward
    Dado que o remoto tem um commit que eu não tenho
    Quando eu executo "Git: Push"
    Então a operação falha com o tipo "Rejected"
    E vejo uma mensagem clara sugerindo pull antes do push

  # teste: test_remote_ops_force_with_lease
  # teste manual: diálogo de confirmação (ui_confirm) antes do force push
  Cenário: Force push só com confirmação explícita
    Dado que eu reescrevi um commit já enviado
    Quando eu executo "Git: Force Push (with lease)..."
    Então um diálogo de confirmação perigosa é exibido
    E só após confirmar é executado "git push --force-with-lease"
    E o remoto passa a apontar para o meu commit

  # teste: test_remote_ops_missing_remote_fails_fast
  # teste: test_remote_ops_classify_errors
  Cenário: Erros de autenticação ou rede aparecem como mensagem clara
    Dado um remoto que não existe
    Quando eu executo "Git: Fetch All"
    Então a operação termina em poucos segundos com erro de rede ou remoto inexistente
    E nenhum prompt de credencial é aberto (GIT_TERMINAL_PROMPT=0, ssh BatchMode)
    E a mensagem é exibida no banner

  # teste: test_remote_ops_stash_save_pop
  Cenário: Criar stash com mensagem opcional e pop do último
    Dado alterações locais não commitadas
    Quando eu executo "Git: Stash Changes..." com a mensagem "wip x"
    Então o working tree fica limpo e o stash "On main: wip x" existe
    Quando eu executo "Git: Stash Pop"
    Então as alterações voltam e a lista de stash fica vazia

  # teste: test_remote_ops_pull_conflict
  # teste manual: abertura do painel "merge_resolver"
  Cenário: Pull que gera conflito abre o resolvedor de conflitos
    Dado que "main" local e "origin/main" alteraram a mesma linha
    Quando eu executo "Git: Pull (Merge)"
    Então o estado do repositório é "Merging" com o arquivo em conflito
    E o painel "merge_resolver" é aberto
