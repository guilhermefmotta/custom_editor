# Performance em repositórios grandes

ADR 0017. Data: 2026-10-20.

## Como medir

Repo sintético (gerador em Python, ~1 minuto): 250 pacotes × 10 pastas ×
100 arquivos `.ts` (250 001 arquivos rastreados, ~800 MB) + `node_modules/`
ignorado com 100 000 arquivos. Um token único (`NEEDLE_UNIQUE_TOKEN`) num
arquivo rastreado e em todos os do `node_modules`.

```sh
EDITOR_PERF_REPO=/caminho/do/repo odin test . -define:ODIN_TEST_NAMES=editor.test_perf_large_repo
```

O teste imprime, para cada busca, o quadro mais lento (o tempo que a thread
da UI fica ocupada num quadro) e o tempo total.

## Resultados (Apple M5, macOS 27, SSD; repo no cache do sistema)

| Cenário | Antes | Depois |
|---|---|---|
| Ctrl+P: quadro mais lento | 72 ms | 4,7 ms |
| Ctrl+P: arquivos listados | 50 000 (teto) | 250 001 |
| Ctrl+P: filtrar "file042" | 73 ms **por quadro** | 80 ms no total (18 quadros) |
| Filtro do tree: quadro mais lento | 27 ms | 4,3 ms |
| Filtro do tree: resultados | 170 (parava em 20k entradas) | 300 (teto de exibição) |
| Busca de texto | 72 s | 9,5 s (ripgrep ou interna) |
| Cancelar busca em andamento | até o fim do arquivo atual | 0,3 ms |
| Índice de arquivos (`git ls-files`, em thread) | — | 0,4–0,8 s |

No editor rodando (driver de UI temporário, mesmo repo): quadro mais lento
5 ms no Ctrl+P, 7 ms no filtro do tree, 4 ms durante a busca de texto.

O `rg` direto no mesmo repo leva 12 s nesta máquina, quase todo em tempo de
sistema: o limite é abrir 250k arquivos, não o editor.

No Windows a diferença tende a ser maior: o iterador do `core:os` abria cada
arquivo para ler o ID, e o antivírus inspeciona cada abertura. A listagem
nova (`FindFirstFileExW` com `FindExInfoBasic`) não abre arquivo nenhum.

## Dicas para monorepos

- **Instale o ripgrep** (`brew install ripgrep`, `winget install
  BurntSushi.ripgrep.MSVC`, `scoop install ripgrep`): a busca usa ele quando
  encontra.
- **Ligue o fsmonitor do git** no repo: `git config core.fsmonitor true &&
  git config core.untrackedCache true`. O `git status` passa a responder do
  monitor em vez de varrer o disco; o editor sugere isso quando o status
  passa de 1,5 s.
- Arquivos no `.gitignore` não aparecem nas buscas. Para incluí-los:
  Settings → "Search git-ignored files" (`[editor] search_ignored_files =
  true`).
