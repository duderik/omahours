.pragma library

// Pure functions for Omahours, no QML. Time is never counted up: a running
// project stores its wall-clock start `since` (ms), and its total is `ms` plus
// the span since then.

var MINUTE = 60000

// A heartbeat older than this counts as stale. It is written every minute to
// a local file, never to the project file, which may sit in a synced folder.
var HEARTBEAT_STALE_MS = 150000

// Largest time a single input may set, add or subtract.
var INPUT_MAX_MINUTES = 99999 * 60

function emptyState() {
  return { version: 1, last: "", projects: [] }
}

function toCount(value) {
  var n = Number(value)
  return isFinite(n) && n > 0 ? Math.floor(n) : 0
}

// A valid time value in the file: missing, or an integer 0 … MAX_SAFE_INTEGER.
function isValidTime(value) {
  if (value === undefined || value === null) return true
  var n = typeof value === "string" && value.trim() !== "" ? Number(value) : value
  return typeof n === "number" && isFinite(n) && n >= 0 && n <= Number.MAX_SAFE_INTEGER
}

// Reads and checks the project file. Returns { store, ok }. `ok` is false as
// soon as reading would lose something (broken JSON, unknown format or
// fields, an unusable entry, a duplicate name, a number out of range). The file must
// then never be overwritten. An empty or missing file is fine: it holds
// nothing that could be lost.
// True if the object has no keys besides `allowed`: an unknown field would
// be dropped on the next write.
function onlyKeys(o, allowed) {
  for (var k in o) if (o.hasOwnProperty(k) && allowed.indexOf(k) < 0) return false
  return true
}

function check(text) {
  var store = emptyState()
  var raw = String(text === undefined || text === null ? "" : text)
  if (raw.trim() === "") return { store: store, ok: true }
  var d = null
  try { d = JSON.parse(raw) } catch (e) { return { store: store, ok: false } }
  if (!d || typeof d !== "object" || Array.isArray(d)) return { store: store, ok: false }
  if (!onlyKeys(d, ["version", "last", "projects"])) return { store: store, ok: false }
  if (d.version !== undefined && d.version !== 1) return { store: store, ok: false }
  if (d.projects !== undefined && !Array.isArray(d.projects)) return { store: store, ok: false }
  if (d.last !== undefined && d.last !== null && typeof d.last !== "string") return { store: store, ok: false }
  var ok = true
  var names = {}
  var list = d.projects || []
  var isRunning = false
  for (var i = 0; i < list.length; i++) {
    var p = list[i]
    if (!p || typeof p !== "object" || Array.isArray(p) || typeof p.name !== "string"
        || !onlyKeys(p, ["name", "ms", "since"])) { ok = false; continue }
    var name = p.name.trim()
    if (name === "" || names.hasOwnProperty("#" + name)) { ok = false; continue }
    if (!isValidTime(p.ms) || !isValidTime(p.since)) { ok = false; continue }
    names["#" + name] = true
    var since = toCount(p.since)
    if (since > 0 && isRunning) { ok = false; since = 0 }
    if (since > 0) isRunning = true
    store.projects.push({ name: name, ms: toCount(p.ms), since: since })
  }
  var last = String(d.last || "")
  store.last = findProject(store.projects, last) >= 0 ? last : ""
  return { store: store, ok: ok }
}

function read(text) {
  return check(text).store
}

function serialize(store) {
  return JSON.stringify({
    version: 1,
    last: store.last,
    projects: store.projects.map(function(p) { return { name: p.name, ms: p.ms, since: p.since } })
  }, null, 2) + "\n"
}

function copyState(store) {
  return {
    version: 1,
    last: store.last,
    projects: store.projects.map(function(p) { return { name: p.name, ms: p.ms, since: p.since } })
  }
}

// Names compare exactly as typed: "abc" and "ABC" are two projects.
function nameKey(name) {
  return String(name).trim()
}

function findProject(projects, name) {
  var s = nameKey(name)
  for (var i = 0; i < projects.length; i++) if (nameKey(projects[i].name) === s) return i
  return -1
}

function runningIndex(projects) {
  for (var i = 0; i < projects.length; i++) if (projects[i].since > 0) return i
  return -1
}

function timeOf(p, now) {
  if (!p) return 0
  return Math.min(Number.MAX_SAFE_INTEGER, p.ms + (p.since > 0 ? Math.max(0, now - p.since) : 0))
}

// Credit the running span up to `until` and stop. Capped like applyInput():
// anything larger would make check() lock the file.
function stop(p, until) {
  if (p.since > 0) p.ms = Math.min(Number.MAX_SAFE_INTEGER, p.ms + Math.max(0, until - p.since))
  p.since = 0
}

function stopAll(store, until) {
  var changed = false
  for (var i = 0; i < store.projects.length; i++) {
    if (store.projects[i].since > 0) { stop(store.projects[i], until); changed = true }
  }
  return changed
}

// Pause for the lock screen or a suspend: returns the name of the project
// that was running, or "" when none was, so only that one resumes later.
function pauseRunning(store, until) {
  var i = runningIndex(store.projects)
  if (i < 0) return ""
  var name = store.projects[i].name
  stop(store.projects[i], until)
  return name
}

// After unlocking: start `name` again, but only if it still exists, is
// paused and no other project runs meanwhile.
function resume(store, name, now) {
  if (!name || runningIndex(store.projects) >= 0) return false
  var i = findProject(store.projects, name)
  if (i < 0) return false
  store.projects[i].since = now
  store.last = store.projects[i].name
  return true
}

// Start or pause. Starting a project pauses any other running one.
function toggle(store, name, now) {
  var i = findProject(store.projects, name)
  if (i < 0) return false
  var p = store.projects[i]
  if (p.since > 0) {
    stop(p, now)
  } else {
    stopAll(store, now)
    p.since = now
  }
  store.last = p.name
  return true
}

// A project found running at load time whose last sign of life is stale
// (power off, crash, missed signal) is counted up to that sign and paused.
// The sign of life is the later of heartbeat and start time. Without a
// heartbeat file (heartbeat 0) only the start counts, so a project started
// more than 150 s ago without a heartbeat pauses without gaining time.
function stopIfStale(store, heartbeat, now) {
  var i = runningIndex(store.projects)
  if (i < 0) return false
  var p = store.projects[i]
  var sign = Math.max(p.since, toCount(heartbeat))
  if (now - sign <= HEARTBEAT_STALE_MS) return false
  stop(p, sign)
  return true
}

// 40m, 22h2m; whole minutes, rounded down.
function format(ms) {
  var min = Math.floor(Math.max(0, ms) / MINUTE)
  if (min < 60) return min + "m"
  return Math.floor(min / 60) + "h" + (min % 60) + "m"
}

// Time input. "23h", "1h30", "1h30m", "90m", "90" set the time, a
// leading "+" adds, "-" subtracts, "0" resets. Spaces and case are ignored.
// Returns null for invalid input or more than 99999h.
function parseInput(text) {
  var t = String(text || "").replace(/\s+/g, "").toLowerCase()
  if (t === "") return null
  var kind = "set"
  if (t.charAt(0) === "+") { kind = "add"; t = t.slice(1) }
  else if (t.charAt(0) === "-") { kind = "subtract"; t = t.slice(1) }
  var m = /^(?:(\d{1,7})h)?(?:(\d{1,9})m)?$/.exec(t)
    || /^(\d{1,7})h(\d{1,9})$/.exec(t)
    || /^()(\d{1,9})$/.exec(t)
  if (!m || (!m[1] && !m[2])) return null
  var minutes = Number(m[1] || 0) * 60 + Number(m[2] || 0)
  if (minutes > INPUT_MAX_MINUTES) return null
  return { kind: kind, ms: minutes * MINUTE }
}

// Never below 0 and never above MAX_SAFE_INTEGER: larger values could not be
// stored exactly, and check() would lock the file afterwards.
function applyInput(currentMs, e) {
  var n = e.kind === "add" ? currentMs + e.ms : (e.kind === "subtract" ? currentMs - e.ms : e.ms)
  return Math.min(Number.MAX_SAFE_INTEGER, Math.max(0, n))
}

// Panel width: as wide as the widest row needs, within min … max. Wider rows
// wrap their name instead of widening the panel.
function fitWidth(needs, min, max) {
  var w = min
  for (var i = 0; i < needs.length; i++) if (needs[i] > w) w = needs[i]
  return Math.min(max, w)
}
