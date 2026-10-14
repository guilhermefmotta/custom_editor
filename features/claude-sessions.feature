# language: pt
# Ticket #17 (T16) — Sessões do Claude Code por repositório com status.
# ADR: docs/adr/0015-sessoes-claude-code-hooks-de-status.md
# Testes: claude_sessions_test.odin, review_mode_test.odin

Funcionalidade: Sessões do Claude Code por repositório
  Como quem revisa vários projetos ao mesmo tempo
  Quero uma sessão do Claude Code por repositório, com o status de cada uma
  Para saber qual precisa de mim e revisar o que ela mudou antes de commitar

  Contexto:
    Dado que o editor tem os repositórios "api" e "web" abertos
    E que "api" é o repositório ativo

  # teste: test_cs_start_one_session_per_repo
  # teste: test_cs_settings_only_editor_hooks
  Cenário: Iniciar o Claude Code na raiz do repositório ativo, uma sessão por repositório
    Quando eu peço a sessão do Claude do repositório ativo
    Então um terminal roda "claude --settings <arquivo-do-editor>" com cwd na raiz de "api"
    E o arquivo de settings do editor contém só os hooks de status do editor
    E as settings do usuário (~/.claude) não são alteradas
    Quando eu peço a sessão de "api" de novo
    Então a mesma sessão é reaproveitada
    Quando eu troco para "web" e peço a sessão
    Então "web" ganha a sua própria sessão e a de "api" continua rodando

  # (visual — teste manual) Ctrl/Cmd+J
  Cenário: Mostrar/esconder a sessão do repositório atual por atalho
    Dado que "api" tem uma sessão aberta e escondida
    Quando eu aperto Ctrl/Cmd+J
    Então o terminal da sessão de "api" aparece focado
    Quando eu aperto Ctrl/Cmd+J de novo
    Então ele some e o Claude continua rodando em segundo plano
    Quando eu troco para "web" e aperto Ctrl/Cmd+J
    Então aparece a sessão de "web" (criada se não existia)

  # teste: test_cs_parse_hook_payload
  # teste: test_cs_status_machine
  # teste: test_cs_fake_claude_drives_status
  Cenário: Painel com todas as sessões e o status de cada uma
    Dado sessões abertas em "api" e "web"
    Quando o Claude de "api" recebe um prompt ou usa uma ferramenta (UserPromptSubmit/PreToolUse)
    Então o status de "api" é "trabalhando"
    Quando o Claude de "api" pede permissão ou fica ocioso (Notification)
    Então o status de "api" é "esperando você"
    Quando o Claude de "api" termina a resposta (Stop) ou o processo sai
    Então o status de "api" é "parada"
    E o painel "Claude: Sessions" e a aba de cada repositório mostram um ponto com a cor do status

  # teste: test_cs_status_machine (notify)
  # teste: test_cs_notify_command
  Cenário: Notificação do sistema quando uma sessão passa a esperar você
    Dado que a sessão de "web" está "trabalhando" em segundo plano
    Quando ela passa para "esperando você"
    Então o sistema mostra uma notificação "Claude: web" com a mensagem do Claude
    E uma sessão que já estava esperando não notifica de novo

  # teste: test_review_lists_changed_files_and_marks_reviewed
  # teste: test_review_diff_vs_session_base
  Cenário: Modo revisão dos arquivos que a sessão mudou
    Dado que a sessão de "api" começou no commit B (HEAD guardado ao iniciar)
    E o Claude alterou "a.txt", criou "novo.txt" e commitou uma mudança em "b.txt"
    Quando eu abro "Claude: Review Changes"
    Então a lista mostra "a.txt", "b.txt" e "novo.txt" (diferença entre B e o working tree)
    Quando eu abro "a.txt"
    Então vejo o diff do arquivo inteiro contra B
    Quando eu marco "a.txt" como revisado
    Então ele aparece como revisado e o contador mostra "1/3 revisados"
    Quando eu peço para commitar
    Então o painel Working Tree abre para o commit
