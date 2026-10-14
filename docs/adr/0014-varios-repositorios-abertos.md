# 0014 — Vários repositórios abertos: `e.git_mgr` como ponteiro para o repo ativo

Data: 2026-10-14 · Ticket #13 (épico #1)

## Contexto

O editor tinha um único `e.git_mgr: git.Git_Manager` (126 usos em 18 arquivos),
uma raiz de LSP e um cwd. O fluxo do usuário é revisar ~8 projetos abertos ao
mesmo tempo. Cada `Git_Manager` tem threads (status e fila) que guardam
ponteiro para o próprio struct, então ele não pode ser copiado/trocado por valor.

## Decisão

1. **Modelo** (`repos.odin`): `Repo_Set` no `Editor` com `list: [dynamic]^Repo`
   (alocados no heap, endereço estável) e `active` (−1 = nenhum). Cada `Repo` tem
   a pasta (identidade da aba, sem duplicata, máx. 16), um `git.Git_Manager`
   próprio (raiz = repo git que contém a pasta, "" se não houver) e, enquanto
   está em segundo plano, a visão guardada: panes/buffers/split, painéis
   registrados que estavam abertos e se a árvore estava aberta.
2. **`e.git_mgr` vira `^git.Git_Manager`** e aponta para o gerenciador do repo
   ativo (ou de `repos.none`, raiz "", quando nada está aberto — nunca nil).
   As 126 leituras `e.git_mgr.root/.queue/.current` não mudam; só os 18
   `&e.git_mgr` viraram `e.git_mgr`.
3. **Troca em duas fases** (`repos_switch`): (a) *Leaving*: hooks
   `Repo_Switch_Hook(.Leaving)`, fecha os painéis ligados a repo (o `on_close`
   de cada tela libera seus jobs na fila antiga) e os lembra, fecha o diálogo
   git, cancela busca/scan da paleta; (b) espera a fila antiga ficar sem job
   em andamento e `remote_ops_busy()` falso (+2 frames para os `update` das
   telas consumirem resultados; teto de 3 s) — ids de job são por fila e uma
   tela nunca pode consultar um id do repo A na fila do B; (c) troca visão,
   `e.git_mgr`, cwd, recria a árvore, hooks `.Entered`, reabre os painéis
   lembrados (que recarregam do repo novo no `on_open`).
   Telas com estado fora do `on_close` assinam `repos_register_switch_hook`
   (`@(init)`): Forge (cliente preso à raiz) e sidebar (filtro de branch).
   Terminal, configurações, boas-vindas e as abas ficam abertos na troca.
4. **cwd segue o repo ativo** (`os.change_directory`). Walkers (`"."`) da
   busca, paleta de arquivos, árvore, goto-def e terminal passam a operar no
   repo ativo sem reescrevê-los. Caminhos que não podem seguir o cwd são
   fixados no início: sessão (`session_file_path` absoluto) e fontes
   (`launch_dir`). `git` sempre roda com `-C raiz` absoluta.
5. **Segundo plano**: só o repo ativo bombeia callbacks da fila
   (`git_manager_update`); os outros só atualizam status a cada 15 s
   (`git_manager_update_status`, novo em `git/manager.odin`) para a aba mostrar
   branch e nº de mudanças. Jobs já enfileirados continuam rodando na thread
   de cada repo.
6. **LSP**: um `LSP_Manager` só; ele já cria um servidor por raiz de projeto
   sob demanda (ao abrir arquivo). Logo N repos abertos não sobem N servidores;
   fechar um repo para os clientes com raiz dentro dele
   (`lsp_stop_clients_under`). Documentos dos buffers em segundo plano ficam
   abertos no servidor.
7. **Clone/init** (`git/repo_ops*.odin`): jobs `git_request_clone/init` numa
   fila sem repo (`e.repos.ops`), com o ambiente não interativo das operações
   remotas (`remote_env`: `GIT_TERMINAL_PROMPT=0`, ssh BatchMode, `LC_ALL=C`),
   progresso por leitura em blocos da saída do `git clone --progress`
   (POSIX; no Windows só ao final) e erro classificado por
   `remote_classify_error`.
8. **Recentes** de repositório em `~/.config/editor/recent_repos` (um por
   linha, máx. 20), separados dos arquivos recentes (`Recents_Dialog`).
   **Sessão** guarda os repos, a visão de cada um e o ativo; arquivos antigos
   (só a visão única) continuam válidos.

## Consequências

- Telas novas: continuam usando `e.git_mgr`; se guardarem estado ligado ao
  repositório fora do `on_close`, assinam o hook de troca.
- Uma tela que mantém um painel aberto com job longo atrasa a troca em até 3 s.
- Fechar um repo/sair espera o git em andamento das threads dele (join); sair
  durante um clone espera o clone terminar.
- O rascunho de commit do working tree é global (não por repo).
- Abrir um arquivo de outro repo pelos recentes de arquivo abre na visão do
  repo ativo (não troca de aba).
