# 0006 — Sidebar de refs como overlay com foco, operações via `git/refs_ops`

Data: 2026-10-14 · Ticket #6

## Contexto

O ADR 0001 diz que `.Dock` ainda não reserva área do editor. A sidebar
(painel `sidebar`) precisa ficar aberta ao lado do código sem roubar o
teclado o tempo todo. O `git` roda com stderr descartado, então as
operações não têm a mensagem de erro do git.

## Decisão

- Painel `.Overlay` ancorado à esquerda (340 px, altura toda), não modal:
  tem foco ao abrir e ao clicar dentro; um clique fora devolve o teclado
  ao editor (o painel só consome o mouse sobre ele). Quando `.Dock`
  reservar área, basta trocar a camada.
- Clique simples numa branch filtra o grafo, mas com atraso da janela de
  duplo clique (0,35 s), para que o duplo clique (checkout) não abra o
  grafo também.
- Operações em `git/refs_ops.odin` (`git_request_refs_op`, um
  `Refs_Op` serializado nos args do job) e uma consulta única
  `git_request_refs_snapshot` (branches, remotos, tags, stashes, reflog,
  submódulos, estado). O resultado (`Refs_Op_Outcome`) é diagnosticado
  pelo estado do repositório depois da falha (mudanças locais →
  `Blocked_Local_Changes`; arquivos em conflito → `Conflicts`; branch
  ainda existe após `-d` → `Not_Merged`), não pelo texto do stderr.
- Checkout de branch remota usa `checkout -b <local> --track <remoto/b>`;
  se a local já existe sem upstream, configura `--set-upstream-to`.

## Consequências

- Mensagens de erro são genéricas por operação; se a camada git passar
  a capturar stderr, `_refs_run_op` pode anexá-lo.
- Atalho global Ctrl/Cmd+Alt+B.
