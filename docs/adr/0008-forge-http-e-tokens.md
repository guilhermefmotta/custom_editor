# 0008 — Forge: HTTP via subprocesso (gh/glab/curl), tokens no cofre do SO e worker próprio

Data: 2026-10-14 · Ticket #14 (painel Forge) · Escopo: local ao ticket (pacote `forge/`)

## Contexto

O painel Forge lista PRs/MRs com status dos checks, abre o diff, lê/publica
comentários e lista/dispara pipelines e jobs no GitHub e no GitLab
(inclusive self-hosted / GitHub Enterprise). O core do Odin não tem cliente
HTTPS, as chamadas podem levar segundos e precisam de autenticação por host.
A camada git (`git/**`) está sendo reescrita em paralelo e não pode ser
tocada; a fila git assíncrona do ticket #3 não existe na base deste ticket.

## Decisão

1. **Pacote `forge/` independente**, com worker próprio (`worker.odin`:
   `client_start/submit/poll/stop`, uma thread, fila FIFO sob mutex). Todo
   subprocesso (git, gh, glab, curl, security, secret-tool) roda nessa
   thread; a UI (`forge_panel.odin`) só enfileira e consome resultados no
   `update` do painel. O worker usa a própria arena temporária.
2. **Descoberta**: `git rev-parse --show-toplevel` a partir do diretório do
   arquivo ativo e `git remote get-url origin` (ou o primeiro remoto),
   rodados pelo próprio `forge/` (sem depender de `git/`). O host define a
   plataforma: contém "github" → GitHub (api.github.com ou `https://host/api/v3`),
   contém "gitlab" → GitLab (`https://host/api/v4`). Porta de URL http(s)
   é mantida (é a porta da API); porta ssh é descartada.
3. **Transporte, nesta ordem**:
   - `gh api` / `glab api --hostname <host>` quando o CLI está instalado e
     `auth status --hostname` passa — reaproveita o login do usuário, o
     editor não vê nem guarda token;
   - senão `curl` com token: variável de ambiente (`GH_TOKEN`/`GITHUB_TOKEN`,
     `GH_ENTERPRISE_TOKEN` para GHE, `GITLAB_TOKEN`/`GL_TOKEN`) ou o token
     salvo para o host. O header de autenticação vai pelo **stdin** do curl
     (`-H @-`), nunca na linha de comando (visível em `ps`);
   - sem nenhum dos dois: leituras anônimas via curl (funciona para projetos
     públicos, exceto o GraphQL do GitHub); escrita ou 401/403/404 viram a
     mensagem "not authenticated … `gh auth login` ou Forge: Set Token".
4. **Lista de PRs via GraphQL** (uma requisição traz PRs + status agregado
   dos checks: `statusCheckRollup` no GitHub, `headPipeline.status` no
   GitLab). O resto segue os endpoints REST do Git Crab
   (`src-tauri/src/commands/forge.rs`). Diff: GitHub `pulls/N` com
   `Accept: application/vnd.github.diff`; GitLab `merge_requests/N/diffs`
   remontado como diff unificado. "Disparar pipeline": GitLab cria pipeline
   na branch atual; GitHub (sem API genérica) re-executa o último workflow
   run da branch.
5. **Token seguro por host** (`token.odin`, tudo atrás de `when ODIN_OS`):
   - macOS: Keychain, generic password `service=custom_editor.forge`,
     `account=<host>`; gravado por `security -i` com o comando no stdin;
   - Linux: Secret Service via `secret-tool store/lookup service … host …`
     (segredo no stdin);
   - Windows: Credential Manager via `CredWriteW/CredReadW` (advapi32,
     declarados em `token_windows.odin`), alvo `custom_editor.forge:<host>`;
   - fallback (Linux sem `secret-tool`, outros SOs): arquivo
     `<user config dir>/custom_editor/forge_tokens`, modo 0600, linhas
     `host token`. Menos seguro — só usado quando não há cofre.
   Tokens são validados (`[A-Za-z0-9._:~+/=-]`), o que também torna seguro o
   quoting no `security -i`. O buffer do campo de token é zerado após o uso.
6. **Erros** viram texto (`Result.err`): saída do CLI, `HTTP <status>:
   <message>` do curl, "network error: …" para falha de rede, com dica de
   token quando parece problema de autenticação. O painel mostra no rodapé e
   num banner; nada bloqueia a thread da UI.
7. **Testabilidade**: o exec é injetável (`Exec_Proc`); os testes usam
   fixtures em `forge/testdata` e um exec falso — nenhuma rede ou processo
   real nos testes.

## Consequências

- Requer `curl` (ou `gh`/`glab`) no PATH; em apps abertos pelo Finder o
  PATH é mínimo, então o exec tenta também `/opt/homebrew/bin`,
  `/usr/local/bin`, `/usr/bin`.
- `gh auth status` roda a cada detecção (abrir o painel / salvar token);
  custa ~0,3–1 s, mas só no worker.
- Sem timeout duro para gh/glab (curl usa `--max-time 60`); um CLI travado
  prende só a fila do Forge.
- Quando a fila git/rede compartilhada do épico existir, o worker do Forge
  pode continuar separado (operações HTTP não disputam o índice git).
