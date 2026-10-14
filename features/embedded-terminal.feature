# language: pt
Funcionalidade: Terminal embutido (PTY/ConPTY + libvterm)
  Para rodar o shell e programas de tela cheia (como o Claude Code) sem sair do editor
  Como usuário do editor
  Eu quero um painel de terminal com abas, emulação completa e entrada de teclado fiel

  Contexto:
    Dado o editor compilado com o subpacote terminal/ e a libvterm

  Cenário: Painel com abas, mostrar/esconder por atalho, shell na raiz do repositório
    Dado o editor aberto num arquivo dentro de um repositório git
    Quando eu pressiono Ctrl+` (ou executo "Terminal: Toggle" na paleta)
    Então o painel de terminal aparece na metade de baixo da janela com uma aba
    E o shell ($SHELL, ou %COMSPEC% no Windows) roda com diretório atual na raiz do repositório
    Quando eu executo "Terminal: New Tab" (Ctrl+Shift+`)
    Então uma segunda aba aparece e Ctrl+Tab / clique alterna entre as abas
    Quando eu pressiono Ctrl+` de novo
    Então o painel some e os shells continuam vivos
    # teste: test_repo_root_finds_git_dir
    # visual: build + teste manual

  Cenário: Processo no PTY tem a saída emulada no grid
    Dado um terminal criado com 24 linhas e 80 colunas
    Quando ele roda "printf 'abc\n'" num PTY
    Então o grid contém "abc" na primeira linha
    # teste: test_spawn_printf_reaches_grid

  Cenário: Cores e atributos ANSI viram atributos de célula
    Dado um terminal sem processo
    Quando ele recebe "\e[1;31mR\e[0m\e[38;5;208mO\e[38;2;1;2;3;48;2;4;5;6mT\e[0m\e[7mV"
    Então a célula "R" é negrito com a cor vermelha da paleta
    E a célula "O" tem a cor 208 da paleta de 256 cores
    E a célula "T" tem fg truecolor (1,2,3) e bg (4,5,6)
    E a célula "V" tem o atributo reverso
    # teste: test_ansi_colors_become_cell_attrs

  Cenário: Cursor e rolagem
    Dado um terminal de 5 linhas sem processo
    Quando ele recebe 20 linhas numeradas
    Então o cursor fica na última linha e as linhas que saíram da tela vão para o histórico
    E rolar a visão para trás mostra as linhas antigas
    # teste: test_cursor_and_scrollback

  Cenário: Redimensionar o painel redimensiona o PTY e a emulação
    Dado um terminal rodando "sleep 0.3; stty size" num PTY
    Quando o terminal é redimensionado para 30 linhas e 100 colunas
    Então o programa vê "30 100"
    E o grid passa a ter 30 linhas e 100 colunas
    # teste: test_resize_reaches_pty

  Cenário: Saída rápida e grande não perde dados nem trava a UI
    Dado um terminal rodando "seq 1 100000" num PTY
    Quando a thread de leitura do PTY processa a saída
    Então todos os bytes chegam à libvterm e a última linha visível é "100000"
    E a thread da UI só copia o grid pronto quando o flag "dirty" está marcado
    # teste: test_large_output_no_data_loss
    # visual: rodar `yes | head -100000` no app e digitar no editor ao mesmo tempo

  Cenário: Teclas especiais chegam ao programa
    Dado um terminal sem processo capturando o que seria escrito no PTY
    Quando eu envio Ctrl+C, Esc, Shift+Enter e Enter
    Então o PTY recebe "\x03", "\e", "\e\r" e "\r" respectivamente
    # teste: test_keys_encode_to_pty_bytes

  Cenário: Colar texto grande
    Dado um terminal com o modo bracketed paste ligado pelo programa
    Quando eu colo um texto de várias linhas
    Então o PTY recebe "\e[200~", o texto com quebras de linha como "\r" e "\e[201~"
    # teste: test_paste_bracketed
    # visual: Cmd+V / Ctrl+Shift+V no app; Cmd+C / Ctrl+Shift+C copia a tela visível

  Cenário: Várias instâncias simultâneas
    Dado 8 terminais rodando ao mesmo tempo
    Quando todos são fechados
    Então todos os processos e threads terminam e nenhuma memória vaza
    # teste: test_many_instances

  Cenário: Builds de macOS, Linux e Windows incluem a libvterm
    Dado o fonte da libvterm 0.3.3 vendorizado em terminal/libvterm/
    Quando build.sh / build.bat ou o CI rodam
    Então a libvterm é compilada como biblioteca estática e ligada ao binário
    # visual: CI (.github/workflows/build.yml e release.yml)
