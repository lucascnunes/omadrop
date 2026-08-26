// Node test runner for ShelfModel.js — mirrors the house pattern used by
// omarchy.clock's Model.js tests. Run: node tests/shelf-model-test.js

var M = require("../ShelfModel.js")

var failures = 0
var passed = 0

function t(name, fn) {
  try {
    fn()
    passed++
  } catch (e) {
    failures++
    console.log("FAIL " + name + ": " + e.message)
  }
}

function eq(actual, expected, label) {
  var a = JSON.stringify(actual)
  var b = JSON.stringify(expected)
  if (a !== b) throw new Error((label || "") + " expected " + b + ", got " + a)
}

function ok(value, label) {
  if (!value) throw new Error((label || "") + " expected truthy, got " + JSON.stringify(value))
}

// ---------------------------------------------------------------------------
// Settings

t("normalizeSettings falls back to defaults", function() {
  var s = M.normalizeSettings(null)
  eq(s.shakeEnabled, M.DEFAULTS.shakeEnabled)
  eq(s.shakeReversals, M.DEFAULTS.shakeReversals)
  eq(s.shelfPosition, "cursor")
})

t("normalizeSettings coerces strings from shell.json", function() {
  var s = M.normalizeSettings({
    shakeEnabled: "false",
    shakeReversals: "9",
    shelfPosition: "bottomRight",
    maxItems: "5",
    showNotifications: "yes"
  })
  eq(s.shakeEnabled, false)
  eq(s.shakeReversals, M.REVERSALS_MAX)
  eq(s.shelfPosition, "bottomRight")
  eq(s.maxItems, 5)
  eq(s.showNotifications, true)
})

t("normalizeSettings ignores unknown keys (id stays out)", function() {
  var s = M.normalizeSettings({ id: "lucas.omadrop", bogus: 1 })
  ok(!("bogus" in s), "no bogus key")
})

t("findBarEntry locates the plugin entry in bar.layout", function() {
  var cfg = { bar: { layout: { left: [], center: [], right: [{ id: "omarchy.tray" }, { id: "lucas.omadrop", shakeEnabled: false }] } } }
  var entry = M.findBarEntry(cfg, "lucas.omadrop")
  ok(entry && entry.shakeEnabled === false, "found right-section entry")
  eq(M.findBarEntry({ bar: { layout: { left: [], center: [], right: [] } } }, "lucas.omadrop"), null)
})

// ---------------------------------------------------------------------------
// URIs and paths

t("uriToPath decodes percent escapes", function() {
  eq(M.uriToPath("file:///home/me/my%20file%20%C3%A7.txt"), "/home/me/my file ç.txt")
  eq(M.uriToPath("file://localhost/tmp/a"), "/tmp/a")
  eq(M.uriToPath("https://example.com/x"), null)
  eq(M.uriToPath("/bare/path"), "/bare/path")
})

t("pathToUri round-trips through uriToPath", function() {
  var p = "/home/me/pasta (1)/arquivo ç.pdf"
  eq(M.uriToPath(M.pathToUri(p)), p)
})

t("baseName strips directories", function() {
  eq(M.baseName("/a/b/c.txt"), "c.txt")
  eq(M.baseName("/a/b/dir/"), "dir")
})

t("guessKind buckets common extensions", function() {
  eq(M.guessKind("foto.PNG"), "image")
  eq(M.guessKind("clip.mkv"), "video")
  eq(M.guessKind("song.flac"), "audio")
  eq(M.guessKind("relatório.pdf"), "pdf")
  eq(M.guessKind("backup.tar.gz"), "archive")
  eq(M.guessKind("semext"), "file")
})

// ---------------------------------------------------------------------------
// Items and shelves

t("makeItem accepts paths and URIs, rejects junk", function() {
  var item = M.makeItem("file:///home/me/foto.png")
  ok(item && item.path === "/home/me/foto.png" && item.name === "foto.png" && item.kind === "image")

  var fromPath = M.makeItem("/tmp/nota.txt")
  ok(fromPath && fromPath.kind === "text" && fromPath.uri.indexOf("file://") === 0)

  eq(M.makeItem("palavra-solta"), null)
  eq(M.makeItem(""), null)
})

t("addItems dedupes against the active shelf and caps items", function() {
  var st = M.emptyState()
  var first = M.addItems(st, ["/a.txt", "/b.png"], { maxItems: 10 })
  eq(first.added, 2)

  var second = M.addItems(st, ["/b.png", "/c.md"], { maxItems: 10 })
  eq(second.added, 1)
  eq(second.duplicates, 1)

  var shelf = M.activeShelf(st)
  eq(shelf.items.map(function(i) { return i.path }), ["/a.txt", "/b.png", "/c.md"])

  for (var i = 0; i < 30; i++) M.addItems(st, ["/f" + i + ".txt"], { maxItems: 5 })
  eq(M.activeShelf(st).items.length, 5)
})

t("removeItem and clearActive work on the active shelf", function() {
  var st = M.emptyState()
  M.addItems(st, ["/x.txt", "/y.txt"], {})
  var id = M.activeShelf(st).items[0].id
  ok(M.removeItem(st, id))
  eq(M.activeShelf(st).items.length, 1)
  ok(M.clearActive(st))
  eq(M.activeShelf(st).items.length, 0)
})

t("archiveCurrent opens a fresh shelf and keeps history", function() {
  var st = M.emptyState()
  M.addItems(st, ["/one.txt"], {})
  var oldShelfId = M.activeShelf(st).id

  M.archiveCurrent(st, {})
  ok(M.activeShelf(st).id !== oldShelfId, "new active shelf")
  eq(M.activeShelf(st).items.length, 0)
  eq(st.shelves.length, 2)

  ok(M.reopenShelf(st, oldShelfId))
  eq(M.activeShelf(st).id, oldShelfId)
  eq(M.activeShelf(st).items.length, 1)
})

t("deleteShelf promotes another working shelf", function() {
  var st = M.emptyState()
  M.addItems(st, ["/a.txt"], {})
  var first = M.activeShelf(st).id
  M.archiveCurrent(st, {})
  var second = M.activeShelf(st).id

  // Two working shelves: reopening the first leaves the second working too.
  ok(M.reopenShelf(st, first))
  ok(M.deleteShelf(st, first))
  eq(st.activeShelfId, second, "promotes the remaining working shelf")
})

t("deleteShelf allows zero working shelves until the next capture", function() {
  var st = M.emptyState()
  M.addItems(st, ["/a.txt"], {})
  M.archiveCurrent(st, {})
  var second = M.activeShelf(st).id

  ok(M.deleteShelf(st, second))
  eq(st.activeShelfId, null, "nothing working left to promote")
  eq(M.totalActiveCount(st), 0)
})

t("totalActiveCount counts only the active shelf", function() {
  var st = M.emptyState()
  M.addItems(st, ["/a", "/b", "/c"].map(function(p) { return p + ".txt" }), {})
  M.archiveCurrent(st, {})
  M.addItems(st, ["/d.txt"], {})
  eq(M.totalActiveCount(st), 1)
})

// ---------------------------------------------------------------------------
// Serialization round trip

t("serialize/deserialize survives garbage input", function() {
  eq(M.countActiveItemsText(""), 0)
  eq(M.countActiveItemsText("não é json"), 0)
  eq(M.countActiveItemsText("{}"), 0)
})

t("deserializeState restores shelves verbatim", function() {
  var st = M.emptyState()
  M.addItems(st, ["/keep me.txt"], {})
  var text = M.serializeState(st)
  var restored = M.deserializeState(text)
  eq(restored.shelves.length, st.shelves.length)
  eq(M.totalActiveCount(restored), 1)
  eq(M.activeShelf(restored).items[0].name, "keep me.txt")
})

t("countActiveItemsText reads a real file payload", function() {
  var st = M.emptyState()
  M.addItems(st, ["/one.txt", "/two.txt"], {})
  eq(M.countActiveItemsText(M.serializeState(st)), 2)
})

// ---------------------------------------------------------------------------
// Capture result parsing

t("parseCaptureResult validates shapes", function() {
  eq(M.parseCaptureResult("").ok, false)
  eq(M.parseCaptureResult("lixo").reason, "bad-output")
  eq(M.parseCaptureResult('{"ok":true,"paths":["/a"],"reason":""}').paths[0], "/a")
  var none = M.parseCaptureResult('{"ok":true,"paths":[],"reason":"no-selection"}')
  eq(none.ok, false)
  eq(none.reason, "no-selection")
})

// ---------------------------------------------------------------------------
// Geometry

t("monitorFor picks the containing output", function() {
  var monitors = [
    { name: "DP-1", x: 0, y: 0, width: 1920, height: 1080 },
    { name: "HDMI-1", x: 1920, y: 0, width: 1280, height: 720 }
  ]
  eq(M.monitorFor(2500, 100, monitors).name, "HDMI-1")
  eq(M.monitorFor(-50, 50, monitors), null)
  eq(M.monitorFor(100, 100, []), null)
})

t("shelfAnchor clamps cursor mode inside the monitor", function() {
  var mon = { x: 1920, y: 0, width: 1280, height: 800 }
  var pos = M.shelfAnchor("cursor", mon, { x: 3195, y: 795 }, 400, 400, 10)
  ok(pos.x >= 10 && pos.x <= 1280 - 400 - 10, "x clamped: " + pos.x)
  ok(pos.y >= 10 && pos.y <= 800 - 400 - 10, "y clamped: " + pos.y)
  ok(pos.x < 3195 - 1920, "biased up-left of the pointer")
})

t("shelfAnchor honors corners", function() {
  var mon = { x: 0, y: 0, width: 1000, height: 1000 }
  eq(M.shelfAnchor("topLeft", mon, null, 300, 300, 12), { x: 12, y: 12 })
  eq(M.shelfAnchor("bottomRight", mon, null, 300, 300, 12), { x: 688, y: 688 })
})

// ---------------------------------------------------------------------------

console.log(passed + " passed, " + failures + " failed")
process.exit(failures === 0 ? 0 : 1)
