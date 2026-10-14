# 0002 — Histórico de arquivo com `--follow` e blame do buffer via arquivo temporário

Data: 2026-10-14 · Épico #1 · Ticket #10 (tela `file_history`)

## Contexto

A tela de histórico/blame precisa (a) seguir renomeações do arquivo e (b)
mostrar o blame do conteúdo do buffer, com as linhas editadas e ainda não
commitadas sem autor (paridade com `get_line_authors` do Git Crab).

- `git_request_log` (`Log_Options`) não tem opção `--follow`, e com `--follow`
  o caminho do arquivo muda ao longo do histórico — o diff de cada commit
  precisa do nome do arquivo *naquele* commit.
- O caminho natural para (b) é `git blame --porcelain --contents - <arq>` com o
  buffer no stdin, mas `git_run` (`popen(..., "r")` no POSIX) não alimenta
  stdin, e mudar `git/process*.odin` afeta todas as unidades.

## Decisão

Tudo local à tela, em `file_history_git.odin`, como `Git_Work_Proc`
enfileiradas com `git_request_custom`:

1. **Histórico**: `git log --follow -z -M --name-status --format=... HEAD -- <path>`.
   O parser acompanha o nome do arquivo do mais novo para o mais antigo: num
   commit `R`/`C` guarda `path` (novo) e `old_path` (antigo) e passa a usar o
   nome antigo para os commits anteriores. O diff de cada commit usa a consulta
   pronta `git_request_commit_file_diff(hash, path, old_path)`.
2. **Blame do buffer**: a UI copia o texto do buffer para os `args` do pedido
   (a fila copia os args para a arena do job); o worker grava esse texto num
   arquivo temporário (`os.create_temp_file`), roda
   `git blame --porcelain --contents <tmp> -- <path>` e apaga o arquivo.
   Linhas atribuídas ao hash zero (não commitadas) ficam sem autor. Se o git
   não conhece o arquivo (não rastreado), todas as linhas ficam sem autor.
   Sem buffer aberto para o arquivo, o blame é do arquivo em disco.

## Consequências

- Nenhuma mudança em arquivos compartilhados (`git/queue.odin`,
  `git/process*.odin`, `Log_Options`).
- Se no futuro `git_run` ganhar stdin, trocar o arquivo temporário por
  `--contents -` é local a `fh_blame_work`.
- O gutter de blame do editor (`git_integration.odin`, síncrono, do disco)
  continua independente; pode migrar para `fh_request_blame` quando quiser.
