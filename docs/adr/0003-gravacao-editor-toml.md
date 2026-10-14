# 0003 — Gravação do `editor.toml` pela tela de configurações

Data: 2026-10-14 · Épico #1 · Ticket #15

## Contexto

A tela de configurações (#15) precisa gravar tema, fonte, tamanho, modo de
teclas, tab, quebra de linha e auto save. O config é carregado em camadas
(defaults < system < user < workspace) e não há serializador TOML; o único
escritor existente (`config_persist_keymap_mode`) reescrevia uma linha sem
escrita atômica. Ao implementar descobrimos também que o lexer TOML
descartava todo valor inteiro/float (dígitos viravam chave nua), então
`tab_size`, `font.size` etc. nunca eram lidos dos arquivos.

## Decisão

1. **Sempre o arquivo do usuário** (`default_config_paths().user`,
   `~/.config/editor/editor.toml`; no Windows cai em `%USERPROFILE%` quando
   não há `HOME`). O diretório/arquivo é criado se faltar.
2. **Patch de uma linha** (`toml_patch_value`): troca só o valor de
   `chave = valor`, mantendo indentação, espaçamento, comentário da linha e
   fim de linha (LF/CRLF); chave ausente entra após a última chave da seção
   (antes dos comentários-separadores do próximo cabeçalho); seção ausente
   é anexada ao fim. Tabelas `[[...]]` nunca são alvo.
3. **Nunca deixar o arquivo inválido** (`config_write_value`): o arquivo
   atual precisa passar em `toml_validate` (modo estrito sobre o parser
   tolerante) — senão nada é gravado e a tela pede correção manual; o
   resultado é validado e o valor relido antes de gravar; grava em
   `<arquivo>.tmp` e renomeia por cima (MoveFileEx REPLACE_EXISTING no
   Windows).
4. **Validação** em `config_setting_parse`: fonte 8..72 (mesmo limite do
   Ctrl+=/−), tab 1..16, atraso do auto save 0.1..600 s, tema precisa
   existir no registro, fonte precisa ser arquivo .ttf/.otf/.ttc existente.
   Valor inválido não altera nem a memória nem o arquivo.
5. **Aplicação imediata**: tema via `registry_set_theme`; `FONT_SIZE` (o
   atlas é recriado por `main.odin`); arquivo de fonte via
   `settings_font_path`/`settings_font_gen` (lidos por `main.odin`); modo de
   teclas + `keymap_switch_reset`; quebra de linha em todos os painéis
   (e nos novos splits); tab e auto save lidos de `e.cfg` ao vivo. Na
   partida, `font.size`/`font.family`/`word_wrap` do config passam a valer.
6. Lexer TOML corrigido para números (um run de dígitos seguido de letras
   continua chave nua, ex. `2fa`).

## Consequências

- O `editor.toml` do workspace continua vencendo o do usuário na partida;
  a tela marca com `*` as chaves também definidas no workspace.
- Como números agora são lidos, valores do `editor.toml` do repositório
  passam a ter efeito (ex.: `font.size = 14` em vez do 18 fixo).
- `palette.odin` ("Set Keymap Mode") segue gravando no arquivo do workspace
  (não editado por este ticket), agora com a mesma escrita segura.
- A inserção de Tab em `input.odin`/`vim.odin` ainda usa 4 espaços fixos;
  `tab_size` hoje alimenta o formatador LSP. Ligar o Tab do editor a
  `e.cfg.editor.tab_size` é follow-up (arquivos fora deste ticket).
