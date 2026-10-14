# 0004 — Terminal embutido: libvterm vendorizada + PTY/ConPTY com threads de I/O

Data: 2026-10-14 · Épico #1 · Ticket #16

## Contexto

O ticket #16 traz um terminal embutido (o uso principal será rodar o Claude
Code dentro dele, ticket #17): TUI de tela cheia, 256 cores/truecolor, colar
texto grande, até 8 instâncias. Precisamos de um emulador VT completo (não
vale reescrever) e de um PTY por plataforma, sem travar a thread da UI.

## Decisão

1. **libvterm 0.3.3 vendorizada** em `terminal/libvterm/` (fonte C, ~200 KB,
   licença MIT em `LICENSE`), compilada como **biblioteca estática** por
   `terminal/libvterm/build.sh` (cc/clang/gcc → `lib/libvterm.a`) ou
   `build.bat` (MSVC → `lib/vterm.lib`). `build.sh`/`build.bat` da raiz e o
   CI (`.github/workflows/*.yml`, MSVC via `ilammy/msvc-dev-cmd`) chamam esse
   passo antes do `odin build`. `lib/` é ignorado pelo git.
   - Por quê: mesma versão nas três plataformas (o layout das structs nos
     bindings depende disso), binário sem dependência em runtime (Homebrew não
     precisa estar instalado no Mac de quem baixa o release), e Windows não
     tem pacote — compilar do fonte é o único caminho robusto lá.
   - Conveniência de dev: em macOS/Linux, se `lib/libvterm.a` ainda não foi
     gerado, `terminal/vterm.odin` cai para `system:vterm`
     (`brew install libvterm` / `libvterm-dev`), então um `odin build .`
     direto continua funcionando. No Windows o passo de build é obrigatório.
2. **Subpacote `terminal/` (package `term`)** — o nome `terminal` colide com
   `core:terminal` (importado pelo runner de testes). Contém os bindings,
   o modelo (`terminal.odin`) e os backends `pty_posix.odin`
   (`forkpty` + `execve`, fd mestre não bloqueante) e `conpty_windows.odin`
   (`CreatePseudoConsole`, Windows 10 1809+).
3. **Threads**: por terminal, uma thread de leitura (PTY → `vterm_input_write`
   sob mutex → flag `dirty`) e uma de escrita (bytes de teclado/colar/respostas
   da libvterm vão para um buffer sob o mutex; a thread escreve no PTY sem
   segurar o lock). A UI nunca bloqueia em I/O; ela só copia o grid pronto
   (`term.snapshot`) quando `dirty` está marcado ou a vista mudou. `dirty`
   é o gancho para o futuro loop de renderização por evento.
4. **Scrollback** num anel de 5000 linhas mantido pelo modelo (callbacks
   `sb_pushline/popline` da libvterm). Altscreen habilitado; reflow não.
5. **Teclas**: Shift+Enter envia `ESC CR` (Meta+Enter, nova linha no Claude
   Code); Ctrl+letra vira código de controle; Esc/Ctrl+C vão ao programa;
   copiar/colar = Cmd+C/V no macOS, Ctrl+Shift+C/V nos outros. Colar usa
   bracketed paste quando o programa liga o modo.
6. **Fonte**: o painel carrega sua própria instância do arquivo de fonte do
   editor (mesmo tamanho `FONT_SIZE`) com mais faixas Unicode (setas,
   box-drawing, blocos, braille, símbolos). Box-drawing e blocos são
   desenhados como retângulos para emendar entre células.
7. Shell: `$SHELL` (com `-l` no macOS, como o Terminal.app) ou `%COMSPEC%`;
   cwd = raiz do repositório (ancestral com `.git`) do diretório atual;
   `TERM=xterm-256color`, `COLORTERM=truecolor`.

## Consequências

- Build passa a exigir um compilador C (já presente onde o Odin roda:
  clang/gcc no Unix, MSVC no Windows).
- O backend ConPTY foi só verificado por compilação cruzada
  (`odin build -target:windows_amd64 -build-mode:obj`), não executado.
- O painel é `.Overlay` na metade de baixo (ADR 0001: `.Dock` ainda não
  reserva espaço); quando houver dock real, só o cálculo do retângulo muda.
- API para outras telas (ex. #17): `terminal_panel_active()` e o pacote
  `term` (`send_bytes`, `paste`, `snapshot`...).
