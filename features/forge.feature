# language: pt
Funcionalidade: Forge — pull requests, pipelines/jobs e comentários (GitHub/GitLab)
  Para acompanhar o trabalho do time sem sair do editor
  Como desenvolvedor num repositório hospedado no GitHub ou GitLab
  Eu quero ver PRs/MRs com o status dos checks, abrir o diff, ler e publicar
  comentários e acompanhar/disparar pipelines e jobs

  Contexto:
    Dado o editor aberto dentro de um repositório git com remoto "origin"
    E o painel Forge aberto pela paleta ("Forge: Toggle") ou Ctrl/Cmd+Alt+P

  Esquema do Cenário: Detecta GitHub e GitLab pela URL do remoto
    Dado o remoto "<url>"
    Quando o Forge detecta o host
    Então a plataforma é "<plataforma>", o host é "<host>" e o projeto é "<projeto>"
    # teste: test_detect_github_https, test_detect_github_ssh, test_detect_gitlab_self_hosted,
    #        test_detect_gitlab_subgroups_ssh_url, test_detect_unknown_host, test_detect_api_urls

    Exemplos:
      | url                                                    | plataforma | host              | projeto              |
      | https://github.com/odin-lang/Odin.git                  | GitHub     | github.com        | odin-lang/Odin       |
      | git@github.com:odin-lang/Odin.git                      | GitHub     | github.com        | odin-lang/Odin       |
      | https://gitlab.com/group/sub/proj                      | GitLab     | gitlab.com        | group/sub/proj       |
      | ssh://git@gitlab.empresa.com.br:2222/time/app.git      | GitLab     | gitlab.empresa.com.br | time/app         |
      | https://ci-user@gitlab.empresa.com.br/time/app.git     | GitLab     | gitlab.empresa.com.br | time/app         |
      | https://bitbucket.org/a/b.git                          | Desconhecida | bitbucket.org   | a/b                  |

  Cenário: Token guardado de forma segura por host
    Dado que não há "gh"/"glab" autenticado para o host
    Quando eu executo "Forge: Set Token" e digito o token (o campo mostra só asteriscos)
    Então o token é gravado no cofre do sistema associado ao host do remoto
      (macOS Keychain; Linux Secret Service via secret-tool; Windows Credential Manager)
    E o token nunca aparece na linha de comando de um subprocesso
    E as próximas chamadas para esse host usam o token via curl
    # teste: test_token_store_uses_stdin_not_argv, test_curl_token_goes_to_stdin,
    #        test_auth_prefers_cli_then_token

  Cenário: Lista PRs/MRs abertos com status dos checks
    Dado um repositório GitHub (ou GitLab) com PRs abertos
    Quando eu abro a aba "Pull Requests"
    Então vejo número, título, autor, branch origem → destino e um ícone do status dos checks
      (sucesso, falha, em andamento, pendente ou sem checks)
    E PRs em rascunho aparecem marcados como "draft"
    # teste: test_parse_github_prs_graphql, test_parse_gitlab_mrs_graphql, test_check_state_mapping,
    #        test_worker_lists_prs_off_ui_thread

  Cenário: Abre o diff de um PR
    Dado a lista de PRs carregada
    Quando eu seleciono um PR e pressiono Enter
    Então o diff unificado do PR aparece num painel de texto com linhas +/- coloridas
    # teste: test_parse_gitlab_mr_diffs, test_github_diff_request_uses_diff_media_type

  Cenário: Lista pipelines e jobs com status
    Quando eu abro a aba "Pipelines"
    Então vejo os pipelines (GitLab) / workflow runs (GitHub) com status, branch e data
    Quando eu pressiono Enter num pipeline
    Então vejo os jobs desse pipeline com status, estágio e duração
    # teste: test_parse_github_runs, test_parse_gitlab_pipelines, test_parse_github_jobs, test_parse_gitlab_jobs

  Cenário: Dispara pipeline e repete job
    Dado a aba "Pipelines" aberta
    Quando eu pressiono Ctrl+T e confirmo
    Então um pipeline é disparado na branch atual (GitLab: POST pipeline; GitHub: re-run do último run da branch)
    Quando eu seleciono um job e pressiono Ctrl+R e confirmo
    Então o job é reexecutado e a lista de jobs é recarregada
    # teste: test_trigger_and_retry_requests

  Cenário: Lê e publica comentários num PR
    Dado um PR selecionado
    Quando eu pressiono Ctrl+E
    Então vejo os comentários com autor, data e texto (notas de sistema do GitLab ficam de fora)
    Quando eu digito um comentário e pressiono Enter
    Então o comentário é publicado no PR e a lista de comentários é recarregada
    # teste: test_parse_github_comments, test_parse_gitlab_notes_skips_system, test_post_comment_request

  Cenário: Chamadas de rede fora da thread da UI e erros como mensagem
    Dado qualquer operação do Forge
    Então ela roda numa thread de trabalho do pacote forge e a UI só consome resultados prontos
    Quando a rede falha, o token é inválido ou não há autenticação
    Então a mensagem de erro aparece no painel e num banner, sem travar o editor
    # teste: test_worker_reports_network_error, test_worker_reports_missing_auth,
    #        test_curl_http_error_message, test_worker_lists_prs_off_ui_thread
