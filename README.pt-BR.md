# OmaDrop

[🇺🇸 English](README.md)

Dropzone flutuante para o [Omarchy](https://omarchy.org/) inspirada no
[Dropover](https://dropoverapp.com/) (macOS): *collect files in a temporary
shelf, then move, share, or process everything at once.*

Selecione arquivos no gerenciador de arquivos, **sacuda o mouse** (ou use uma
hotkey) e uma shelf aparece junto ao cursor segurando os arquivos enquanto
você navega até o destino real — navegador, outro app, outra workspace — e
arrasta os itens de lá.

```
┌──────────────────────────────┐
│ 󰏗 OmaDrop   3 itens    󰤨   │
├──────────────────────────────┤
│ ┌──────┐ ┌──────┐ ┌──────┐  │
│ │ 󰈟    │ │ 󰉋    │ │ 󰈦    │  │
│ │a.png │ │pasta │ │rel.pdf│ │
│ └──────┘ └──────┘ └──────┘  │
│ [ Nova shelf ] [ Limpar ]    │
└──────────────────────────────┘
```

## Instalação

```bash
omarchy plugin add git@github.com:lucascnunes/omadrop.git --enable
# ou, durante o desenvolvimento:
ln -s "$(pwd)" ~/.config/omarchy/plugins/lucas.omadrop
omarchy plugin enable lucas.omadrop
```

O ícone **󰏗** entra na barra (seção direita). Ele é o corpo do plugin:
removê-lo da barra desliga o OmaDrop inteiro.

## Uso

| Ação | Como |
|---|---|
| Capturar a seleção | Sacuda o mouse sobre os arquivos selecionados, **ou** pressione `Super+Shift+D`, **ou** clique-direito no ícone |
| Abrir a shelf atual | `Super+Shift+A` ou clique esquerdo no ícone |
| Guardar arrastando | Arraste arquivos de qualquer app **para dentro** da shelf |
| Usar a shelf | Arraste um tile para qualquer aplicativo (upload no navegador, anexo no e-mail, mover no gerenciador de arquivos…) — duplo-clique abre o arquivo |
| Configurar | Clique direito no ícone da barra (ou botão 󰤨 na shelf) |

As hotkeys sugeridas precisam de uma linha em `~/.config/hypr/bindings.lua`
(o painel de configurações copia a linha pronta — os combos são editáveis):

```lua
o.bind("SUPER SHIFT, D", "OMADROP CAPTURE", "omarchy-shell omadrop capture")
o.bind("SUPER SHIFT, A", "OMADROP OPEN", "omarchy-shell omadrop open")
```

> **Como a captura funciona**: o Wayland não expõe "arquivos selecionados",
> então ao acionar a hotkey o OmaDrop copia a seleção por trás dos panos
> (tecla sintetizada invisível), lê a lista do clipboard e **restaura seu
> clipboard anterior**. Você nunca aperta Ctrl+C; se preferir copiar
> manualmente, use `omarchy-shell omadrop clip`, que só lê o clipboard atual.
> Em terminais a síntese de teclas é automaticamente pulada (evita SIGINT).

## Configurações

Disponíveis no painel (botão 󰤨) e persistidas no seu `shell.json`
(`~/.config/omarchy/shell.json`, dentro da entrada deste widget):

| Setting | Default | O que faz |
|---|---|---|
| `shakeEnabled` | `true` | Liga/desliga a detecção de sacudida |
| `shakeReversals` | `4` | Quantas reversões de direção contam como shake (**menos = mais sensível**) |
| `shelfPosition` | `cursor` | `cursor`, `topLeft`, `topCenter`, `topRight`, `bottomLeft`, `bottomCenter`, `bottomRight` |
| `maxItems` | `20` | Limite de itens da shelf ativa |
| `showNotifications` | `true` | Toasts de "N arquivos na shelf" |
| `language` | `auto` | Idioma da interface: `auto` (segue o sistema), `en`, `pt`. A troca atualiza na hora o painel, a shelf e os toasts |
| `hotkeyCapture` / `hotkeyOpen` | `SUPER SHIFT, D` / `SUPER SHIFT, A` | Combos editáveis; o chip de copiar do painel emite a linha `o.bind(...)` correspondente |

### Histórico de shelves ("Nova shelf")

O botão *Nova shelf* arquiva a shelf atual no histórico e começa vazia. No
painel, **Shelves recentes** lista tudo: reabra qualquer uma (torna-a atual)
ou apague entradas antigas. O estado vive em
`~/.local/state/omadrop/shelf.json` e sobrevive a reinícios do shell.

## IPC (para scripts e keybinds)

```bash
omarchy-shell omadrop capture   # seleção -> shelf (pipeline completo)
omarchy-shell omadrop clip      # lê só o clipboard atual
omarchy-shell omadrop open      # mostra a shelf
omarchy-shell omadrop toggle    # alterna visibilidade
omarchy-shell omadrop settings  # abre o painel de configuração
omarchy-shell omadrop archive   # nova shelf (arquiva a atual)
omarchy-shell omadrop clear     # esvazia a shelf atual
omarchy-shell omadrop suspend   # pausa o detector de shake (sessão)
omarchy-shell omadrop resume
omarchy-shell omadrop status    # JSON com estado atual
```

## Solução de problemas

- **Shake não dispara** — veja `~/.local/state/omadrop/shaked.log`; aumente a
  sensibilidade (`shakeReversals: 3`). Teste sem risco com
  `omarchy-shell omadrop capture`.
- **Shake dispara demais** — suba `shakeReversals` para 5–6, ou suspenda com
  `omarchy-shell omadrop suspend`.
- **Captura não acha arquivos** — o app focado precisa responder a Ctrl+C com
  `text/uri-list` (Nautilus, Dolphin, Thunar e Nemo respondem). As teclas de
  captura vão via **ydotool** (nível kernel, imune a conflitos de input
  method); o daemon auto-inicia na primeira captura e fica residente (~1 MB).
  Com fcitx5 ativo, o wtype sozinho falha silenciosamente — confira
  `~/.local/state/omadrop/capture.log` com `OMADROP_DEBUG=1`.
- **Arrastar para apps não funciona** — entradas remotas (ex.: `network://`)
  não participam de drags nativos; caminhos locais sim.

## Arquitetura

```
manifest.json            híbrido bar-widget + panel (keepLoaded)
OmaDrop.qml              raiz: IPC, settings, estado, daemon, geometria
BarWidget.qml            ícone da barra + badge (lê shelf.json)
ShelfWindow.qml          janela layer-shell: tiles drag-out, DropArea, settings
SettingsPanel.qml        popout de configurações + histórico sob o ícone da barra
ShelfModel.js            lógica pura (URIs, dedupe, serialização) testável em node
Strings.js               i18n (en/pt); callers passam settings.language para tLang()
scripts/capture-selection.sh   clipboard snapshot → wtype → uri-list → restore
scripts/omadrop-shaked         daemon Python (~80 Hz via socket1 do Hyprland)
tests/shelf-model-test.js      node tests/shelf-model-test.js
```

Por que Python no detector: o loop é I/O-bound (~0,02 ms/request medido,
dorme ~98% do tempo) então CPU < 1% em qualquer linguagem; Python evita
toolchain de build num plugin distribuído por git. Upgrades futuros
documentados: detector dentro do shell via `Quickshell.Io.Socket` (economiza
~20 MB RSS) ou plugin C++ nativo do Hyprland (eventos/botões do ponteiro).

## Desinstalação

```bash
omarchy plugin remove lucas.omadrop --yes
```

Depois limpe o que o plugin deixou para trás:

```bash
rm -rf ~/.local/state/omadrop          # histórico de shelves, logs, lock do daemon
```

E remova as duas linhas `o.bind(... omadrop ...)` que você adicionou no
`~/.config/hypr/bindings.lua`, seguido de `omarchy reload hyprland`
(ou `omarchy restart shell`).

## Apoie o projeto

O OmaDrop é gratuito e de código aberto. Se ele te economiza tempo todo dia,
considere apoiar:

- ⭐ Dê uma estrela no repo: [github.com/lucascnunes/omadrop](https://github.com/lucascnunes/omadrop)
- ☕ Pague um café: [ko-fi.com/lucascnunes](https://ko-fi.com/lucascnunes)

## Licença

MIT — veja [LICENSE](LICENSE).
