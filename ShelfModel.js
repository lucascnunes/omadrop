// Pure logic for OmaDrop: settings normalization, URI parsing, shelf CRUD,
// geometry helpers and state serialization. Qt-free and DOM-free so it runs
// unchanged inside QML and under node (tests/shelf-model-test.js).

// ---------------------------------------------------------------------------
// Settings

var DEFAULTS = {
  shakeEnabled: true,
  shakeReversals: 4,        // direction reversals inside the window that count as one shake
  shelfPosition: "cursor",  // cursor | topLeft | topRight | bottomLeft | bottomRight
  maxItems: 20,
  showNotifications: true,
  language: "auto",         // auto | en | pt
  hotkeyCapture: "SUPER SHIFT, D",
  hotkeyOpen: "SUPER SHIFT, A"
}

var POSITIONS = ["cursor", "topLeft", "topCenter", "topRight", "bottomLeft", "bottomCenter", "bottomRight"]
var REVERSALS_MIN = 3
var REVERSALS_MAX = 7

// ---------------------------------------------------------------------------
// State file bounds
//
// shelf.json lives in the user's state dir, so anything may be sitting there.
// A state OmaDrop wrote is orders of magnitude under this (20 shelves x 100
// items, worst case); anything bigger is refused instead of parsed. Readers
// bound their read at STATE_BYTES_MAX + 1 so "too big" stays detectable
// without pulling the whole file into the shell.
var STATE_BYTES_MAX = 4 * 1024 * 1024

function isOversizedState(text) {
  return typeof text === "string" && text.length > STATE_BYTES_MAX
}

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

function clampInt(value, min, max, fallback) {
  var n = parseInt(value, 10)
  if (!isFinite(n)) n = Math.round(Number(value))
  if (!isFinite(n)) return fallback
  return Math.min(max, Math.max(min, n))
}

function boolOf(value, fallback) {
  if (value === undefined || value === null) return fallback
  if (value === true) return true
  if (value === false) return false
  var text = String(value).toLowerCase()
  if (text === "true" || text === "1" || text === "yes" || text === "on") return true
  if (text === "false" || text === "0" || text === "no" || text === "off") return false
  return fallback
}

function stringOf(value, fallback) {
  var text = String(value === undefined || value === null ? "" : value)
  return text === "" ? fallback : text
}

// The plugin entry in shell.json carries arbitrary keys (id at minimum);
// anything unrecognized is ignored here.
function normalizeSettings(entry) {
  var src = isPlainObject(entry) ? entry : {}
  return {
    shakeEnabled: boolOf(src.shakeEnabled, DEFAULTS.shakeEnabled),
    shakeReversals: clampInt(src.shakeReversals, REVERSALS_MIN, REVERSALS_MAX, DEFAULTS.shakeReversals),
    shelfPosition: POSITIONS.indexOf(src.shelfPosition) !== -1 ? src.shelfPosition : DEFAULTS.shelfPosition,
    maxItems: clampInt(src.maxItems, 1, 100, DEFAULTS.maxItems),
    showNotifications: boolOf(src.showNotifications, DEFAULTS.showNotifications),
    language: ["auto", "en", "pt"].indexOf(src.language) !== -1 ? src.language : DEFAULTS.language,
    hotkeyCapture: stringOf(src.hotkeyCapture, DEFAULTS.hotkeyCapture),
    hotkeyOpen: stringOf(src.hotkeyOpen, DEFAULTS.hotkeyOpen)
  }
}

// ---------------------------------------------------------------------------
// Small utilities

function safeParse(text) {
  try {
    var value = JSON.parse(String(text === undefined || text === null ? "" : text))
    return isPlainObject(value) ? value : null
  } catch (e) {
    return null
  }
}

function cloneJson(value) {
  // Deep-clone via JSON. Unlike safeParse (settings/state objects only),
  // this must also accept arrays — drag-all snapshots are item lists.
  try {
    return JSON.parse(JSON.stringify(value === undefined ? null : value))
  } catch (e) {
    return null
  }
}

var idCounter = 0

function shortId(prefix) {
  idCounter = (idCounter + 1) % 1296
  return String(prefix || "i") + Date.now().toString(36) + "-" + idCounter.toString(36)
}

function decodePercent(text) {
  try {
    return decodeURIComponent(String(text))
  } catch (e) {
    return String(text)
  }
}

// ---------------------------------------------------------------------------
// URIs and paths

// "file:///home/me/my%20file.txt" -> "/home/me/my file.txt".
// Non-file schemes (https, trash, network shares) return null: they are kept
// as remote entries but cannot participate in native drags.
function uriToPath(uri) {
  var text = String(uri === undefined || uri === null ? "" : uri)
  if (text.indexOf("/") === 0) return decodePercent(text)
  if (text.indexOf("file://") !== 0) return null
  var rest = text.slice("file://".length)
  if (rest.indexOf("localhost/") === 0) rest = rest.slice("localhost".length)
  rest = rest.split("?")[0].split("#")[0]
  return decodePercent(rest)
}

function pathToUri(path) {
  var parts = String(path || "").split("/")
  var encoded = []
  for (var i = 0; i < parts.length; i++) encoded.push(encodeURIComponent(parts[i]))
  return "file://" + encoded.join("/")
}

function baseName(path) {
  var clean = String(path || "").replace(/\/+$/, "")
  var slash = clean.lastIndexOf("/")
  return slash === -1 ? clean : clean.slice(slash + 1)
}

var KIND_EXTENSIONS = {
  image: ["png", "jpg", "jpeg", "webp", "gif", "bmp", "svg", "avif", "heic", "ico"],
  video: ["mp4", "mkv", "webm", "mov", "avi", "m4v"],
  audio: ["mp3", "flac", "wav", "ogg", "oga", "m4a", "opus"],
  pdf: ["pdf"],
  archive: ["zip", "tar", "gz", "tgz", "rar", "7z", "xz", "bz2", "zst", "iso"],
  text: ["txt", "md", "json", "csv", "log", "xml", "yml", "yaml", "js", "ts", "py", "rs", "go", "c", "cpp", "h", "sh", "lua", "toml", "ini", "conf"],
  doc: ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "pages", "numbers", "key"]
}

// Exact extension lookup (substring matching would turn ".c" into an image).
function guessKind(name) {
  var dot = String(name || "").lastIndexOf(".")
  if (dot === -1) return "file"
  var ext = String(name).slice(dot + 1).toLowerCase()
  for (var kind in KIND_EXTENSIONS) {
    var list = KIND_EXTENSIONS[kind]
    for (var i = 0; i < list.length; i++)
      if (list[i] === ext) return kind
  }
  return "file"
}

// Accepts file:// URIs, bare absolute paths, and other schemes (kept as links).
function makeItem(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (text === "") return null

  var path = null
  var uri = text
  var isDir = false

  if (text.indexOf("/") === 0) {
    path = decodePercent(text)
    uri = pathToUri(path)
  } else if (text.indexOf("://") !== -1) {
    path = uriToPath(text)
    isDir = /\/$/.test(text)
    // Canonicalize: the same file can arrive percent-encoded (clipboard) or
    // raw (QML drop.urls); dedupe must see one identity, not two.
    if (path !== null) uri = pathToUri(path)
  } else {
    return null
  }

  var name = baseName(path !== null ? path : text)
  if (isDir && path === null) name = baseName(text.replace(/\/+$/, ""))
  if (name === "") name = text

  return {
    id: shortId("i"),
    uri: uri,
    path: path,
    name: name,
    kind: path === null ? "link" : (isDir ? "dir" : guessKind(name)),
    addedAt: Date.now()
  }
}

function makeItems(list) {
  var out = []
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length; i++) {
    var item = makeItem(list[i])
    if (item) out.push(item)
  }
  return out
}

// ---------------------------------------------------------------------------
// State: { version, shelves: [shelf], activeShelfId }

function emptyState() {
  return { version: 1, shelves: [], activeShelfId: null }
}

function finiteOr(value, fallback) {
  var n = Number(value)
  return typeof value === "number" && isFinite(n) ? n : fallback
}

function sanitizeShelf(raw) {
  if (!isPlainObject(raw)) return null
  var items = []
  if (Array.isArray(raw.items)) {
    for (var i = 0; i < raw.items.length; i++) {
      var it = raw.items[i]
      if (!isPlainObject(it) || typeof it.uri !== "string" || it.uri === "") continue
      items.push({
        id: typeof it.id === "string" && it.id !== "" ? it.id : shortId("i"),
        uri: it.uri,
        path: typeof it.path === "string" ? it.path : null,
        name: typeof it.name === "string" && it.name !== "" ? it.name : baseName(it.path || it.uri),
        kind: typeof it.kind === "string" ? it.kind : "file",
        // Guard with typeof: isFinite(null) is true, which would turn a
        // stored null into epoch-zero.
        addedAt: finiteOr(it.addedAt, Date.now())
      })
    }
  }
  return {
    id: typeof raw.id === "string" && raw.id !== "" ? raw.id : shortId("s"),
    createdAt: finiteOr(raw.createdAt, Date.now()),
    updatedAt: finiteOr(raw.updatedAt, Date.now()),
    archivedAt: finiteOr(raw.archivedAt, null),
    items: items
  }
}

function deserializeState(text) {
  // Single choke point: every reader lands here, so bounding it here covers
  // the bar badge, the settings poll and the panel's own load alike.
  if (isOversizedState(text)) return emptyState()
  var parsed = safeParse(text)
  var state = emptyState()
  if (!parsed) return state

  var shelves = []
  if (Array.isArray(parsed.shelves)) {
    for (var i = 0; i < parsed.shelves.length; i++) {
      var shelf = sanitizeShelf(parsed.shelves[i])
      if (shelf) shelves.push(shelf)
    }
  }
  state.shelves = shelves.slice(-20)

  var active = typeof parsed.activeShelfId === "string" ? parsed.activeShelfId : null
  if (!active || !findShelf(state, active)) {
    // Point at the newest working shelf, if any survived sanitization.
    for (var j = state.shelves.length - 1; j >= 0; j--) {
      if (state.shelves[j].archivedAt === null) { active = state.shelves[j].id; break }
    }
  }
  state.activeShelfId = active
  normalizeWorkingShelves(state)
  return state
}

function serializeState(state) {
  return JSON.stringify(state === undefined ? emptyState() : state, null, 2)
}

function findShelf(state, id) {
  if (!state || !Array.isArray(state.shelves)) return null
  for (var i = 0; i < state.shelves.length; i++)
    if (state.shelves[i].id === id) return state.shelves[i]
  return null
}

function activeShelf(state) {
  if (!state) return null
  if (state.activeShelfId) {
    var found = findShelf(state, state.activeShelfId)
    if (found && found.archivedAt === null) return found
  }
  // Fall through: newest non-archived shelf becomes active again.
  for (var i = state.shelves.length - 1; i >= 0; i--) {
    if (state.shelves[i].archivedAt === null) {
      state.activeShelfId = state.shelves[i].id
      return state.shelves[i]
    }
  }
  return null
}

// At most one working (non-archived) shelf may exist. Strays (stale state,
// restart races) are merged into the winner — the shelf activeShelfId points
// at, else the newest non-empty, else the newest — and dropped.
function normalizeWorkingShelves(state) {
  if (!state || !Array.isArray(state.shelves)) return
  var working = []
  for (var i = 0; i < state.shelves.length; i++)
    if (state.shelves[i].archivedAt === null) working.push(state.shelves[i])
  if (working.length === 0) return
  if (working.length === 1) { state.activeShelfId = working[0].id; return }

  var winner = null
  for (var w = 0; w < working.length; w++)
    if (working[w].id === state.activeShelfId) { winner = working[w]; break }
  if (!winner) {
    var bestScore = -1
    for (var j = 0; j < working.length; j++) {
      var score = (working[j].items.length > 0 ? 1e13 : 0) + (working[j].updatedAt || 0)
      if (score > bestScore) { bestScore = score; winner = working[j] }
    }
  }

  var seen = {}
  for (var k = 0; k < winner.items.length; k++) seen[winner.items[k].uri] = true
  var kept = []
  for (var m = 0; m < state.shelves.length; m++) {
    var sh = state.shelves[m]
    if (sh.archivedAt !== null || sh === winner) { kept.push(sh); continue }
    for (var n = 0; n < sh.items.length; n++) {
      var it = sh.items[n]
      if (!seen[it.uri]) { seen[it.uri] = true; winner.items.push(it) }
    }
    // Losers are dropped: their items live on inside the winner.
  }
  state.shelves = kept
  state.activeShelfId = winner.id
}

function ensureActiveShelf(state) {
  normalizeWorkingShelves(state)
  var shelf = activeShelf(state)
  if (shelf) return shelf
  shelf = { id: shortId("s"), createdAt: Date.now(), updatedAt: Date.now(), archivedAt: null, items: [] }
  state.shelves.push(shelf)
  state.activeShelfId = shelf.id
  return shelf
}

// Adds paths/URIs into the active shelf, deduplicating against it.
// Returns { state, added, duplicates }. Mutates state in place; callers
// reassign their property so QML bindings notice.
function addItems(state, list, opts) {
  var options = opts || {}
  var maxItems = clampInt(options.maxItems, 1, 100, DEFAULTS.maxItems)
  var incoming = []
  if (Array.isArray(list)) {
    for (var i = 0; i < list.length; i++) {
      var item = makeItem(list[i])
      if (item) incoming.push(item)
    }
  }

  var shelf = ensureActiveShelf(state)
  var seen = {}
  for (var e = 0; e < shelf.items.length; e++) seen[shelf.items[e].uri] = true

  var added = 0
  var duplicates = 0
  for (var n = 0; n < incoming.length; n++) {
    var candidate = incoming[n]
    if (seen[candidate.uri]) { duplicates++; continue }
    seen[candidate.uri] = true
    shelf.items.push(candidate)
    added++
  }

  while (shelf.items.length > maxItems) shelf.items.shift()
  shelf.updatedAt = Date.now()
  return { state: state, added: added, duplicates: duplicates }
}

function removeItem(state, itemId) {
  var shelf = activeShelf(state)
  if (!shelf) return false
  for (var i = 0; i < shelf.items.length; i++) {
    if (shelf.items[i].id === itemId) {
      shelf.items.splice(i, 1)
      shelf.updatedAt = Date.now()
      return true
    }
  }
  return false
}

// Remove by filesystem path (used when a single-tile MOVE is confirmed via
// inotify — more reliable than Drag.onDragFinished on QtWayland).
function removeItemByPath(state, path) {
  if (!path) return false
  var shelf = activeShelf(state)
  if (!shelf) return false
  var removed = false
  for (var i = shelf.items.length - 1; i >= 0; i--) {
    if (shelf.items[i] && shelf.items[i].path === path) {
      shelf.items.splice(i, 1)
      removed = true
    }
  }
  if (removed) shelf.updatedAt = Date.now()
  return removed
}

function clearActive(state) {
  var shelf = activeShelf(state)
  if (!shelf) return false
  shelf.items = []
  shelf.updatedAt = Date.now()
  return true
}

// After a filesystem MOVE, retarget every matching item across ALL shelves
// (active + history). Drag-all clears the active shelf optimistically and
// archives a snapshot; late MOVED_TO events must still rewrite archived paths.
function repointMovedPath(state, oldPath, newPath) {
  if (!state || !oldPath || !newPath || oldPath === newPath) return false
  var changed = false
  for (var s = 0; s < state.shelves.length; s++) {
    var shelf = state.shelves[s]
    if (!shelf || !Array.isArray(shelf.items)) continue
    for (var i = 0; i < shelf.items.length; i++) {
      var it = shelf.items[i]
      if (it && it.path === oldPath) {
        it.path = newPath
        it.uri = pathToUri(newPath)
        it.name = baseName(newPath)
        shelf.updatedAt = Date.now()
        changed = true
      }
    }
  }
  return changed
}

// Update paths inside a drag-all snapshot (plain item array, not yet archived).
function repointItemsPath(items, oldPath, newPath) {
  if (!Array.isArray(items) || !oldPath || !newPath || oldPath === newPath) return false
  var changed = false
  for (var i = 0; i < items.length; i++) {
    var it = items[i]
    if (it && it.path === oldPath) {
      it.path = newPath
      it.uri = pathToUri(newPath)
      it.name = baseName(newPath)
      changed = true
    }
  }
  return changed
}

// Archive an explicit item snapshot (used after drag-all): the active shelf
// was cleared at pickup, so archiveCurrent alone would be a no-op.
function archiveSnapshot(state, items, opts) {
  if (!state || !Array.isArray(items) || items.length === 0) return false
  var shelf = ensureActiveShelf(state)
  shelf.items = cloneJson(items)
  shelf.updatedAt = Date.now()
  archiveCurrent(state, opts || {})
  return true
}

// Files the current shelf away into history and opens a fresh one.
function archiveCurrent(state, opts) {
  var maxShelves = clampInt(opts && opts.maxShelves, 3, 100, 20)
  var shelf = ensureActiveShelf(state)
  // An empty shelf has nothing to file away: stay on it instead of
  // polluting the history with empty entries.
  if (shelf.items.length === 0) return state
  shelf.archivedAt = Date.now()
  shelf.updatedAt = Date.now()

  var fresh = { id: shortId("s"), createdAt: Date.now(), updatedAt: Date.now(), archivedAt: null, items: [] }
  state.shelves.push(fresh)
  state.activeShelfId = fresh.id

  // Rebuild bounded history: keep every working shelf plus the newest
  // archived ones up to the budget. The fresh shelf must survive this.
  var working = []
  var archived = []
  for (var i = 0; i < state.shelves.length; i++) {
    var s = state.shelves[i]
    if (s.archivedAt === null) working.push(s)
    else archived.push(s)
  }
  archived.sort(function(a, b) { return (b.archivedAt || 0) - (a.archivedAt || 0) })
  archived = archived.slice(0, Math.max(0, maxShelves - working.length))

  var kept = working.concat(archived)
  kept.sort(function(a, b) { return (a.createdAt || 0) - (b.createdAt || 0) })
  state.shelves = kept
  return state
}

function reopenShelf(state, id) {
  var shelf = findShelf(state, id)
  if (!shelf) return false
  // Single-working invariant: whatever else was working goes to history.
  for (var i = 0; i < state.shelves.length; i++) {
    var s = state.shelves[i]
    if (s.id !== id && s.archivedAt === null) {
      s.archivedAt = Date.now()
      s.updatedAt = Date.now()
    }
  }
  shelf.archivedAt = null
  shelf.updatedAt = Date.now()
  state.activeShelfId = id
  return true
}

function deleteShelf(state, id) {
  var index = -1
  for (var i = 0; i < state.shelves.length; i++)
    if (state.shelves[i].id === id) { index = i; break }
  if (index === -1) return false

  state.shelves.splice(index, 1)
  if (state.activeShelfId === id) {
    state.activeShelfId = null
    activeShelf(state) // promotes the newest remaining working shelf, if any
  }
  return true
}

function totalActiveCount(state) {
  var shelf = state ? activeShelf({ version: 1, shelves: state.shelves, activeShelfId: state.activeShelfId }) : null
  return shelf ? shelf.items.length : 0
}

// For the bar badge: item count straight from the file's text.
function countActiveItemsText(text) {
  return totalActiveCount(deserializeState(text))
}

// ---------------------------------------------------------------------------
// Shell integration

// Locates this plugin's settings entry wherever it lives in shell.json
// (hybrid bar-widget/panel plugins are enabled through bar.layout).
function findBarEntry(config, id) {
  if (!isPlainObject(config) || !isPlainObject(config.bar) || !isPlainObject(config.bar.layout)) return null
  var target = String(id)
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var entries = config.bar.layout[sections[s]]
    if (!Array.isArray(entries)) continue
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      var entryId = String(isPlainObject(entry) ? (entry.id || "") : (entry || ""))
      if (entryId === target && isPlainObject(entry)) return entry
    }
  }
  return null
}

// ---------------------------------------------------------------------------
// Geometry

// Picks the monitor whose logical rectangle contains the global point.
function monitorFor(gx, gy, monitors) {
  if (!Array.isArray(monitors)) return null
  for (var i = 0; i < monitors.length; i++) {
    var m = monitors[i]
    if (!isPlainObject(m)) continue
    var mx = Number(m.x) || 0
    var my = Number(m.y) || 0
    var mw = Number(m.width) || 0
    var mh = Number(m.height) || 0
    if (mw <= 0 || mh <= 0) continue
    if (gx >= mx && gx < mx + mw && gy >= my && gy < my + mh) return m
  }
  return null
}

// Card position in coordinates local to the monitor, honoring the configured
// placement. Cursor mode biases the card up-left of the pointer so it does not
// sit under the hand.
function shelfAnchor(position, monitor, cursor, cardWidth, cardHeight, margin) {
  var mx = monitor ? (Number(monitor.x) || 0) : 0
  var my = monitor ? (Number(monitor.y) || 0) : 0
  var mw = monitor ? (Number(monitor.width) || 1280) : 1280
  var mh = monitor ? (Number(monitor.height) || 800) : 800
  var w = cardWidth
  var h = cardHeight
  var pad = margin

  function clampLocal(x, y) {
    return {
      x: Math.min(Math.max(pad, x), Math.max(pad, mw - w - pad)),
      y: Math.min(Math.max(pad, y), Math.max(pad, mh - h - pad))
    }
  }

  var gx = cursor ? (Number(cursor.x) || 0) : mx + mw / 2
  var gy = cursor ? (Number(cursor.y) || 0) : my + mh / 2
  var lx = gx - mx
  var ly = gy - my

  if (position === "topCenter") return clampLocal((mw - w) / 2, pad)
  if (position === "bottomCenter") return clampLocal((mw - w) / 2, mh - h - pad)
  if (position === "topLeft") return clampLocal(pad, pad)
  if (position === "topRight") return clampLocal(mw - w - pad, pad)
  if (position === "bottomLeft") return clampLocal(pad, mh - h - pad)
  if (position === "bottomRight") return clampLocal(mw - w - pad, mh - h - pad)
  return clampLocal(lx - w * 0.35, ly - h * 0.30) // cursor (default)
}

// ---------------------------------------------------------------------------
// Capture pipeline output

// Validates the JSON line printed by scripts/capture-selection.sh.
function parseCaptureResult(text) {
  var raw = String(text === undefined || text === null ? "" : text).trim()
  if (raw === "") return { ok: false, reason: "no-output", paths: [] }
  var parsed = safeParse(raw)
  if (!parsed || typeof parsed.ok !== "boolean" || !Array.isArray(parsed.paths))
    return { ok: false, reason: "bad-output", paths: [] }

  var paths = []
  for (var i = 0; i < parsed.paths.length; i++)
    if (typeof parsed.paths[i] === "string" && parsed.paths[i] !== "") paths.push(parsed.paths[i])

  return { ok: parsed.ok && paths.length > 0, reason: String(parsed.reason || ""), paths: paths }
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    DEFAULTS: DEFAULTS,
    POSITIONS: POSITIONS,
    REVERSALS_MIN: REVERSALS_MIN,
    REVERSALS_MAX: REVERSALS_MAX,
    STATE_BYTES_MAX: STATE_BYTES_MAX,
    isOversizedState: isOversizedState,
    normalizeSettings: normalizeSettings,
    safeParse: safeParse,
    cloneJson: cloneJson,
    uriToPath: uriToPath,
    pathToUri: pathToUri,
    baseName: baseName,
    guessKind: guessKind,
    makeItem: makeItem,
    makeItems: makeItems,
    emptyState: emptyState,
    deserializeState: deserializeState,
    serializeState: serializeState,
    activeShelf: activeShelf,
    findShelf: findShelf,
    normalizeWorkingShelves: normalizeWorkingShelves,
    ensureActiveShelf: ensureActiveShelf,
    addItems: addItems,
    removeItem: removeItem,
    removeItemByPath: removeItemByPath,
    clearActive: clearActive,
    repointMovedPath: repointMovedPath,
    repointItemsPath: repointItemsPath,
    archiveSnapshot: archiveSnapshot,
    archiveCurrent: archiveCurrent,
    reopenShelf: reopenShelf,
    deleteShelf: deleteShelf,
    totalActiveCount: totalActiveCount,
    countActiveItemsText: countActiveItemsText,
    findBarEntry: findBarEntry,
    monitorFor: monitorFor,
    shelfAnchor: shelfAnchor,
    parseCaptureResult: parseCaptureResult
  }
}
