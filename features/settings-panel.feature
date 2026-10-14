# language: pt
Funcionalidade: Tela de configurações
  Para ajustar o editor sem editar o editor.toml à mão
  Como usuário do editor
  Eu quero uma tela de configurações que aplica as mudanças na hora
  e as grava no meu editor.toml de usuário sem estragar o arquivo

  Contexto:
    Dado o editor aberto com a configuração carregada em camadas
    E a tela "Settings" aberta pela paleta ("Settings: Open") ou por Ctrl/Cmd+,

  # teste: test_settings_rows_cover_required_keys (settings_panel_test.odin)
  # teste: test_settings_cycle_values (settings_panel_test.odin)
  Cenário: A tela edita tema, fonte, tamanho, modo de teclas, tab, quebra de linha e auto save
    Quando eu olho a lista de configurações
    Então vejo as linhas Theme, Font family, Font size, Keymap mode, Tab size, Word wrap, Auto save e Auto save delay
    E cada linha mostra o valor atual
    E com Esquerda/Direita eu alterno tema, modo de teclas (normal, vim, emacs) e liga/desliga
    E com Enter eu digito um valor novo para fonte, tamanho, tab e atraso do auto save

  # teste: test_settings_apply_updates_config (settings_panel_test.odin)
  # visual: troca de tema/fonte/tamanho na tela — build + teste manual
  Cenário: Mudança aplica na hora
    Dado o tema "dark" ativo e tamanho de fonte 18
    Quando eu troco o tema para "gruvbox" e o tamanho de fonte para 20
    Então o tema ativo passa a ser "gruvbox" no mesmo quadro
    E FONT_SIZE vale 20 e o atlas da fonte é recriado
    E o modo de teclas, o tab, a quebra de linha e o auto save passam a valer imediatamente

  # teste: test_patch_replaces_value_preserving_comments (config/writer_test.odin)
  # teste: test_patch_inserts_missing_key_and_section (config/writer_test.odin)
  # teste: test_write_setting_round_trip (config/writer_test.odin)
  Cenário: Mudança é gravada no editor.toml do usuário preservando o arquivo
    Dado um editor.toml de usuário com comentários e seções em uma ordem própria
    Quando eu altero o tamanho de tab para 2
    Então a linha "tab_size" é reescrita com o valor 2 mantendo o comentário da linha
    E todas as outras linhas do arquivo continuam idênticas e na mesma ordem
    E a gravação é feita num arquivo temporário renomeado por cima do original
    E recarregar o arquivo devolve tab_size = 2

  # teste: test_write_setting_creates_user_file (config/writer_test.odin)
  Cenário: editor.toml do usuário ainda não existe
    Dado que ~/.config/editor/editor.toml não existe
    Quando eu altero o tema
    Então o diretório e o arquivo são criados contendo só a chave alterada

  # teste: test_validate_rejects_invalid_values (config/writer_test.odin)
  # teste: test_settings_invalid_value_keeps_file (settings_panel_test.odin)
  Esquema do Cenário: Valor inválido mostra erro sem quebrar o arquivo
    Quando eu informo "<valor>" para "<config>"
    Então a tela mostra uma mensagem de erro na linha
    E o valor em uso não muda
    E o editor.toml do usuário continua byte a byte igual

    Exemplos:
      | config          | valor      |
      | Tab size        | 0          |
      | Font size       | -3         |
      | Theme           | inexistente|
      | Font family     | /nao/existe.ttf |
      | Auto save delay | abc        |

  # teste: test_write_setting_refuses_invalid_toml (config/writer_test.odin)
  Cenário: editor.toml do usuário já está inválido
    Dado um editor.toml de usuário com erro de sintaxe
    Quando eu altero qualquer configuração
    Então o arquivo não é reescrito
    E a tela mostra que o arquivo precisa ser corrigido à mão
