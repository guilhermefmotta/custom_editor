# 0015 — Sessões do Claude Code por repositório: `--settings` próprio + hooks que gravam um arquivo de status

Data: 2026-10-14 · Épico #1 · Ticket #17

## Contexto

O ticket #17 roda o Claude Code (`claude`) no terminal embutido (ADR 0010),
uma sessão por repositório aberto (ADR 0014), com status visível
(trabalhando / esperando você / parada), notificação do sistema e um modo de
revisão do que a sessão mudou. O status só existe dentro do Claude Code; a
forma suportada de exportá-lo são os hooks (`Notification`, `Stop`,
`UserPromptSubmit`, `PreToolUse`...). Restrição: o usuário já tem hooks e
plugins em `~/.claude/settings.json`, que não pode ser editado nem
substituído, e não queremos criar `.claude/settings.local.json` dentro dos
repositórios dele.

## Decisão

1. **`claude --settings <arquivo-do-editor>`**. O editor gera, em
   `~/.config/editor/claude/` (`USERPROFILE` no Windows):
   - `claude-hooks.json` — só a chave `hooks`, com `SessionStart`,
     `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`
     e `SessionEnd`, todos chamando o mesmo comando;
   - `status-hook.sh` (`status-hook.ps1` no Windows) — copia o payload JSON
     do hook (stdin) de forma atômica (tmp + `mv`) para o arquivo indicado em
     `$CUSTOM_EDITOR_CLAUDE_STATUS`; não imprime nada (stdout de
     `UserPromptSubmit` iria para o contexto do Claude) e sempre sai com 0.
   Os dois são reescritos a cada execução do editor (sempre batem com o
   build). `--settings` é a camada "linha de comando" das settings do Claude
   Code: chaves ausentes vêm dos arquivos do usuário e as listas de hooks são
   **mescladas** entre camadas (docs: *settings → "Lists merge instead of
   overriding"*, *hooks → "Hook entries merge across settings levels"*), então
   os hooks/plugins/skills do usuário continuam valendo. Nada em `~/.claude`
   nem no repositório é escrito.
2. **A variável de ambiente é o "interruptor"**: só os terminais que o editor
   abre recebem `CUSTOM_EDITOR_CLAUDE_STATUS=<dir>/state/<pid>-<n>.status`
   (via `term.Spawn_Options.env`, que já existia — não foi preciso mudar
   `terminal/`). Fora disso o script é um no-op.
3. **Lançamento**: Unix → `$SHELL -l -c "exec claude --settings '<arq>'"`
   (shell de login para achar o `claude` no PATH do perfil do usuário; app
   GUI no macOS não tem `~/.local/bin` no PATH); Windows →
   `cmd.exe /c claude --settings "<arq>"`. `CUSTOM_EDITOR_CLAUDE_CMD` troca o
   comando (wrapper, versão específica). cwd = raiz do repositório ativo.
4. **Status por arquivo, lido por polling** (0,25 s, `os.stat` mtime/tamanho
   de cada sessão; só relê quando mudou). Máquina de estados
   (`claude_sessions_model.odin`, pura e testada):
   `UserPromptSubmit/PreToolUse/PostToolUse → Working`;
   `Notification` (`permission_prompt`, `idle_prompt`, `elicitation_*`,
   `agent_needs_input`) `→ Waiting`; `Stop/SessionEnd/SessionStart → Stopped`;
   processo terminou → `Stopped` + `exited`. Notificações informativas
   (`auth_success`...) não mudam nada. `PostToolUse` existe para voltar a
   "trabalhando" depois que você aprova uma permissão.
   Por que arquivo e não socket: zero dependência no script (só `sh`, `cat`,
   `mv`), funciona igual nas três plataformas e sobrevive a o editor estar
   ocupado; a latência de 0,25 s é irrelevante para status humano.
5. **Uma sessão por raiz de repositório** (`Claude_Sessions`, registro no
   próprio arquivo). Pedir de novo reaproveita; sessão cujo processo saiu é
   recriada. O terminal é do registro de sessões; o painel de terminal só o
   **mostra** como aba "externa" (`terminal_panel_attach/detach/shows`,
   adicionados em `terminal_panel.odin`): fechar a aba não mata o Claude.
6. **Ctrl/Cmd+J** ("Claude: Toggle Session") mostra/esconde a sessão do repo
   ativo, criando-a no primeiro uso. Na troca de repositório (hook do ADR
   0014) a aba da sessão do repo que sai é destacada (o processo continua em
   segundo plano); se ela estava na tela, a do repo que entra é mostrada.
   Efeito colateral: Ctrl+J deixa de chegar aos programas do terminal (no
   Claude Code é "nova linha" — Shift+Enter continua funcionando).
   **Ctrl/Cmd+Shift+J** abre o painel "Claude: Sessions" (todas as sessões,
   cor do status, tempo no status, mensagem da notificação; Enter mostra —
   trocando de repo se preciso —, R revisa, X para, N cria). Cada aba de
   repositório ganha um ponto na cor do status (`repos_tab_dot`, gancho
   novo em `repos.odin`).
7. **Notificação do sistema** quando uma sessão passa a `Waiting` (uma vez
   por transição; não notifica se você está olhando para aquela sessão com a
   janela em foco): macOS `osascript -e 'display notification'`, Linux
   `notify-send`, Windows toast via PowerShell — argv sem shell, disparado
   numa thread curta (`process_start` sob `search_proc_mu` + `process_wait`),
   nunca bloqueia a UI. Banner no editor quando a sessão é de outro repo.
8. **Modo revisão** (`review_mode*.odin`, Ctrl/Cmd+Alt+J ou R no painel):
   ao iniciar a sessão o editor guarda o `HEAD` (`git rev-parse` pela fila);
   a revisão lista `git diff --name-status <base>` (working tree) + arquivos
   não rastreados. Diff contra o **início da sessão**, não contra o HEAD
   atual, para que o que o Claude já commitou continue na revisão; repo sem
   commits usa a árvore vazia; base ainda desconhecida → `HEAD`. Enter abre
   o diff do arquivo inteiro contra a base no modo Diff do `git_dialog`
   (`git_dialog_show_diff`); Espaço marca como revisado (em memória, por
   sessão); C abre o Working Tree (`working_tree_open`) para o commit.

## Consequências

- O usuário pode inspecionar/remover `~/.config/editor/claude/`; apagar não
  quebra nada (é regenerado).
- Se o Claude Code mudar a semântica de `--settings` para "substituir", os
  hooks do usuário deixariam de valer só nas sessões abertas pelo editor; o
  teste de settings garante que o arquivo contém apenas `hooks`.
- Hooks rodam em toda chamada de ferramenta (`PreToolUse/PostToolUse`):
  custo de um `sh` + `cat` + `mv` (~ms).
- O backend Windows (script .ps1, `cmd /c`, toast) foi só compilado
  (`odin build -target:windows_amd64 -build-mode:obj`), não executado.
- As marcas de "revisado" não persistem entre execuções do editor.
