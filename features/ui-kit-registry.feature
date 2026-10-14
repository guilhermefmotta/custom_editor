# language: pt
Funcionalidade: Kit de UI reutilizável e registro de painéis e comandos
  Para que as telas do épico #1 sejam construídas em paralelo sem conflitar
  nos arquivos centrais (palette.odin, input.odin, renderer.odin)
  Como desenvolvedor de uma tela nova
  Eu quero registrar comandos e painéis a partir do meu próprio arquivo
  e montar a tela com componentes de UI compartilhados

  Contexto:
    Dado o editor compilado com os arquivos ui_*.odin

  Cenário: Comando registrado via @(init) aparece na paleta
    Dado um arquivo novo que chama ui_register_command dentro de uma proc @(init)
    E palette.odin não foi editado para conhecer esse comando
    Quando eu abro a paleta com Ctrl+Shift+P (Cmd+Shift+P no macOS)
    Então o comando registrado aparece na lista junto com os comandos nativos
    E ao escolhê-lo com Enter a proc do comando é executada

  Cenário: Registro não depende da ordem de @(init)
    Dado comandos e painéis registrados em ordens diferentes
    Quando o registro é lido
    Então os comandos saem ordenados por nome
    E os painéis saem ordenados por prioridade decrescente e depois por id
    E registrar de novo o mesmo id substitui o anterior em vez de duplicar

  Cenário: Painel registrado abre e fecha por comando e por atalho
    Dado um painel registrado com id, título, prioridade, procs de desenho e de input
    E o painel declara um comando de alternância e o atalho Ctrl+Shift+U
    Quando eu executo o comando na paleta
    Então o painel abre
    Quando eu pressiono Ctrl+Shift+U
    Então o painel fecha

  Cenário: Painel aberto no topo recebe teclado e mouse antes do editor
    Dado dois painéis registrados abertos com prioridades 10 e 20
    Quando eu pressiono uma tecla ou clico com o mouse
    Então a proc de input do painel de prioridade 20 é chamada primeiro
    E se ela consumir o evento o editor e o outro painel não o recebem
    E nem input.odin nem renderer.odin foram editados para conhecer esses painéis

  Cenário: Proc por frame é chamada para painéis registrados
    Dado um painel registrado com proc update
    Quando um frame é renderizado
    Então a proc update é chamada com o delta de tempo do frame

  Cenário: Lista com seleção, rolagem e filtro
    Dado uma lista com 100 itens e 10 linhas visíveis
    Quando eu pressiono Seta para baixo 12 vezes
    Então o item 12 fica selecionado e a rolagem mantém ele visível
    Quando eu pressiono PgDn
    Então a seleção avança 10 itens
    Quando eu pressiono PgUp duas vezes
    Então a seleção volta 20 itens sem passar do primeiro
    Quando eu rolo a roda do mouse para baixo
    Então a rolagem avança sem passar do fim da lista
    Quando eu digito um texto no filtro
    Então só os itens que contêm o texto (sem diferenciar maiúsculas) ficam visíveis
    E a seleção volta ao primeiro item filtrado

  Cenário: Diálogo existente usa o componente de lista
    Dado o diálogo "Open Workspace" aberto com mais entradas do que cabem na tela
    Quando eu uso Seta, PgUp/PgDn, Home/End ou a roda do mouse
    Então a seleção e a rolagem seguem a lógica do componente de lista

  Cenário: Abas
    Dado um componente de abas com 3 abas e a primeira ativa
    Quando eu clico na terceira aba
    Então a terceira aba fica ativa
    Quando eu pressiono Ctrl+Tab na última aba
    Então a primeira aba fica ativa (circular)

  Cenário: Painéis com divisor redimensionável pelo mouse
    Dado dois painéis lado a lado com divisor em 50% e tamanho mínimo de 100px por lado
    Quando eu arrasto o divisor com o mouse
    Então a proporção acompanha o mouse
    E nenhum lado fica menor que o mínimo

  Cenário: Diálogo de confirmação com ação extra
    Dado um diálogo de confirmação com "Confirmar", "Cancelar" e uma ação extra
    Quando eu pressiono Enter
    Então o resultado é Confirmar
    Quando eu pressiono Esc
    Então o resultado é Cancelar
    Quando eu navego com Tab até a ação extra e pressiono Enter
    Então o resultado é a ação extra

  Cenário: Menu de contexto com clique direito
    Dado um menu de contexto aberto com clique direito perto da borda da janela
    Então o menu é reposicionado para caber inteiro na janela
    Quando eu escolho um item com o mouse ou com Seta + Enter
    Então o índice do item escolhido é retornado e o menu fecha
    Quando eu clico fora do menu ou pressiono Esc
    Então o menu fecha sem escolha

  Cenário: Banner no topo
    Dado que uma tela chama ui_banner_show com uma mensagem e duração de 3 segundos
    Então um banner aparece no topo da janela
    E ele some depois de 3 segundos ou ao clicar no X

  Cenário: Diálogos existentes continuam funcionando
    Dado o editor com o kit e o registro
    Quando eu abro o git_dialog e o workspace_dialog
    Então eles se comportam como antes

  Cenário: Demonstração viva do registro
    Dado o arquivo ui_demo.odin que só se registra via @(init)
    Quando eu executo "UI Kit: Demo" na paleta
    Então abre um painel com abas, lista filtrável, painéis com divisor, confirmação, menu de contexto e banner
