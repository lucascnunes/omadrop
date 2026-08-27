// OmaDrop i18n. The language is passed EXPLICITLY to tLang() from reactive
// properties (settings.language), so every QML binding re-evaluates when the
// user switches language in the panel — no shared module state involved.
// pt_* locales get Portuguese; everything else English.
//
// Usage:  Strings.tLang(uiLanguage, "key")
//         Strings.tLang(uiLanguage, "manyItems").replace("%1", n)

var TABLE = {
  en: {
    barTooltip: "OmaDrop · left: shelf · right: settings · middle: clear",
    oneItem: "1 item",
    manyItems: "%1 items",
    gearTooltip: "Settings & history",
    closeTooltip: "Close (Esc)",
    newShelf: "New shelf",
    newShelfTooltip: "Archives this shelf and starts a fresh one",
    clearShelf: "Clear",
    clearShelfTooltip: "Empties the active shelf (history is kept)",
    dragHintWithItems: "drag a tile into any app · drop files here to collect them",
    dragHintEmpty: "shake the mouse to open a shelf, or drop files here",
    emptyHint: "Drag files here — shaking the mouse opens\nthis shelf. The capture hotkey shelves a selection.",
    historyEmptyShort: "Nothing archived yet",
    sectionShake: "SHAKE",
    shakeRow: "Open a shelf on mouse shake",
    intensityRow: "Shake intensity",
    intensityCaption: "%1 reversals · lower = more sensitive",
    sectionPosition: "SHELF POSITION",
    posCursor: "Cursor",
    sectionHotkeys: "HOTKEYS",
    hotkeyCapture: "Capture selection",
    hotkeyOpen: "Open the shelf",
    copyLine: "Copy bindings.lua line",
    sectionGeneral: "GENERAL",
    languageRow: "Language",
    langAuto: "Auto",
    langEn: "English",
    langPt: "Português",
    notificationsRow: "Capture notifications",
    limitRow: "Shelf limit",
    limitCaption: "Overflowing oldest items are dropped",
    sectionHistory: "RECENT SHELVES",
    activeBadge: "current",
    makeCurrent: "Make current",
    deleteShelfTip: "Delete from history",
    dragAll: "Select All",
    dragAllTooltip: "Press and drag to drop every item at once",
    sectionSupport: "SUPPORT",
    settingsTitle: "OmaDrop · Settings",
    sectionActions: "SHELF ACTIONS",
    toastNothing: "Nothing captured — select files first",
    toastFailed: "Capture failed (%1)",
    toastShelvedOne: "1 file on the shelf",
    toastShelvedMany: "%1 files on the shelf",
    toastDuplicate: "Already on the shelf",
    toastArchived: "Fresh shelf started — the previous one is in history",
    toastDroppedMany: "%1 dropped into the shelf",
    toastCopied: "Line copied — paste it into ~/.config/hypr/bindings.lua"
  },
  pt: {
    barTooltip: "OmaDrop · esquerdo: shelf · direito: configurações · meio: limpar",
    oneItem: "1 item",
    manyItems: "%1 itens",
    gearTooltip: "Configurações e histórico",
    closeTooltip: "Fechar (Esc)",
    newShelf: "Nova shelf",
    newShelfTooltip: "Arquiva esta shelf no histórico e começa outra",
    clearShelf: "Limpar",
    clearShelfTooltip: "Esvazia a shelf atual (o histórico fica intacto)",
    dragHintWithItems: "arraste um tile para qualquer app · solte arquivos aqui para guardar",
    dragHintEmpty: "sacuda o mouse para abrir uma shelf, ou solte arquivos aqui",
    emptyHint: "Arraste arquivos para cá — sacudir o mouse abre\nesta shelf. A hotkey de captura guarda a seleção.",
    historyEmptyShort: "Sem histórico ainda",
    sectionShake: "SHAKE",
    shakeRow: "Abrir shelf ao sacudir o mouse",
    intensityRow: "Intensidade do gesto",
    intensityCaption: "%1 reversões · menos = mais sensível",
    sectionPosition: "POSIÇÃO DA JANELA",
    posCursor: "Cursor",
    sectionHotkeys: "HOTKEYS",
    hotkeyCapture: "Capturar seleção",
    hotkeyOpen: "Abrir a shelf",
    copyLine: "Copiar linha p/ bindings.lua",
    sectionGeneral: "GERAL",
    languageRow: "Idioma",
    langAuto: "Auto",
    langEn: "English",
    langPt: "Português",
    notificationsRow: "Notificações ao capturar",
    limitRow: "Limite da shelf",
    limitCaption: "Itens excedentes são descartados do início",
    sectionHistory: "SHELVES RECENTES",
    activeBadge: "atual",
    makeCurrent: "Tornar atual",
    deleteShelfTip: "Apagar do histórico",
    dragAll: "Selecionar Tudo",
    dragAllTooltip: "Pressione e arraste para soltar todos os itens de uma vez",
    sectionSupport: "APOIE O PROJETO",
    settingsTitle: "OmaDrop · Configurações",
    sectionActions: "AÇÕES DA SHELF",
    toastNothing: "Nada capturado — selecione arquivos antes",
    toastFailed: "Captura falhou (%1)",
    toastShelvedOne: "1 arquivo na shelf",
    toastShelvedMany: "%1 arquivos na shelf",
    toastDuplicate: "Já está na shelf",
    toastArchived: "Nova shelf criada — a anterior foi para o histórico",
    toastDroppedMany: "%1 recebido(s) na shelf",
    toastCopied: "Linha copiada — cole em ~/.config/hypr/bindings.lua"
  }
}

function localeName() {
  try {
    return String(Qt.locale().name || "en_US")
  } catch (e) {
    return "en_US"
  }
}

function code() {
  return localeName().indexOf("pt") === 0 ? "pt" : "en"
}

// lang is "auto" | "en" | "pt" from settings; anything else follows the locale.
function tLang(lang, key) {
  var c = (lang === "en" || lang === "pt") ? lang : code()
  var table = TABLE[c] || TABLE.en
  var value = table[key]
  if (value === undefined) value = TABLE.en[key]
  return value === undefined ? key : value
}

function t(key) {
  return tLang("", key)
}
