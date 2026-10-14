# language: pt
# Ticket #18 (T17) — Renderização por evento + benchmark contra o Emacs.
# ADR: docs/adr/0016-renderizacao-por-evento.md
# Testes: frame_pacing_test.odin, wake/wake_test.odin, git/manager_timer_test.odin
# Benchmark: docs/benchmark.md (docs/benchmark.py)

Funcionalidade: Renderização por evento
  Como quem deixa o editor aberto o dia todo
  Quero que ele não gaste CPU quando nada está acontecendo
  Para economizar bateria sem perder fluidez ao digitar e rolar

  # teste: test_frame_wait_policy
  # teste: test_cursor_blink
  Cenário: Parado, o editor dorme até chegar evento
    Dado que o editor está com um arquivo aberto e nada se movendo
    E que passou mais de 1 s desde a última tecla ou movimento do mouse
    Quando o quadro termina
    Então o loop dorme em glfwWaitEvents até chegar um evento
    E com o cursor piscando ligado ele acorda só na próxima troca do pisca
    E depois de 10 s sem input o cursor fica sólido e não acorda mais

  # teste: test_frame_wait_policy
  # teste: test_wake_request_concurrent
  # teste: test_manager_refresh_after_sleep
  Cenário: Rolagem, animação e saída de terminal renderizam a 60/120 fps; threads acordam o loop
    Dado que o editor está dormindo
    Quando a rolagem suave está em andamento, há jobs git na fila ou uma busca rodando
    Então o loop renderiza todo quadro no fps_target do editor.toml
    Quando uma thread (git, LSP, busca, terminal, Forge, debug) termina um resultado
    Então ela chama wake.request() e o loop acorda (glfwPostEmptyEvent) e desenha
    E muitos pedidos seguidos postam só um evento por quadro

  # (medido — docs/benchmark.md)
  Cenário: CPU parado perto de 0%
    Dado que o editor abriu "renderer.odin"
    Quando ele fica parado por 20 s
    Então o uso de CPU fica abaixo de 1%
    Dado que há 8 sessões de terminal ociosas
    Quando ele fica parado por 20 s
    Então o uso de CPU fica abaixo de 1%

  # (medido — docs/benchmark.md)
  Cenário: Benchmark documentado contra o Emacs
    Dado o mesmo arquivo aberto no editor e no Emacs com a config do usuário
    Quando eu rodo docs/benchmark.py para os dois
    Então docs/benchmark.md tem CPU parado, RAM, tempo de abertura e latência tecla→quadro
    E o que não dá para medir de forma justa aparece como "não medido"

  # teste: test_autosave_after_sleep
  # teste: test_banner_expires_after_sleep
  # teste: test_manager_refresh_after_sleep
  # (latência — docs/benchmark.md; fluidez ao digitar/rolar — teste manual)
  Cenário: Nenhuma regressão de fluidez ao digitar e rolar
    Dado que eu estou digitando ou rolando
    Então o loop fica no fps cheio por 1 s depois do último input
    E a rolagem que começa logo depois de dormir anima suave (dt de animação limitado)
    E a repetição de tecla usa o dt real do quadro
    E timers (auto save, banner, refresh do git, status do Claude) disparam no primeiro quadro depois de dormir
