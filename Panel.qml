import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Omahours: the bar shows the time of the most recently used project, the
// panel lists all projects. State lives in one JSON file; every bar instance
// (one per monitor) reads it and writes only on a change.
//
// Time is never counted up: a running project stores its start time and the
// display is derived from the wall clock. Automatic pause:
//   - Lock: while a project runs, one instance asks the lock screen every 10 s
//     (`omarchy-shell lock isLocked`). Omarchy locks before every suspend, so
//     closing the lid is covered. Time counts up to the last answer that said
//     "not locked".
//   - Suspend: if more than 45 s pass between two ticks (machine asleep, shell
//     stopped), time ends at the last tick.
//   - Power off, crash: a heartbeat is written every minute to a local file,
//     not to the project file, which may sit in a synced folder and should
//     only change on real actions. A project found running at load time whose
//     last sign of life (heartbeat or start, whichever is later) is older than
//     150 s is counted up to that point and paused.
Panel {
  id: root
  moduleName: "io.github.duderik.omahours"
  ipcTarget: "io.github.duderik.omahours"
  manageIpc: false

  // ------------------------------------------------------------ Colors

  readonly property color green: "#4ade80"
  readonly property color darkRed: "#9e3a3a"
  // Error red follows the theme; the bar keeps its fixed green and dark red.
  readonly property color errorRed: bar ? bar.urgent : Commons.Color.urgent
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dimColor: Qt.darker(fg, 1.55)
  readonly property string fontName: bar ? bar.fontFamily : Style.font.family

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Every row has the same height, editing included: an action button
  // (formula from PanelActionButton) or the text, whichever is taller, plus padding.
  FontMetrics { id: titleMetrics; font.family: root.fontName; font.pixelSize: Style.font.title }
  readonly property int buttonSize: Math.round(Math.max(Style.space(22), Style.font.iconLarge + Style.spacing.sm * 2)) | 1
  readonly property int rowHeight: Math.max(buttonSize, Math.ceil(titleMetrics.height)) + Style.spacing.controlPaddingY * 2
  // Rows align to the top, so a wrapped name keeps its first line level with
  // the time and the buttons; the shorter of text and button is centered on the other.
  readonly property real textOffset: Math.max(0, (buttonSize - Math.ceil(titleMetrics.height)) / 2)
  readonly property real buttonOffset: Math.max(0, (Math.ceil(titleMetrics.height) - buttonSize) / 2)

  // Panel width follows the longest name, at most the Omarchy panel width
  // (380); longer names wrap. Each row needs: inset, name, time, three buttons.
  FontMetrics { id: timeMetrics; font.family: root.fontName; font.pixelSize: Style.font.title; font.features: { "tnum": 1 } }
  readonly property int buttonsWidth: buttonSize * 3 + Style.space(2) * 2
  readonly property int panelChrome: panel.padding * 2 + Border.left(panel.borderSpec) + Border.right(panel.borderSpec)
  readonly property int maxPanelWidth: Style.space(380)
  // Narrowest panel: the editor row keeps a usable name field.
  readonly property int minPanelWidth: Style.space(120) + Style.space(92) + buttonsWidth
    + Style.spacing.controlGap * 2 + panelChrome
  readonly property int panelWidth: unreadable ? maxPanelWidth : Model.fitWidth(store.projects.map(function(p) {
    return Style.space(12) + Math.ceil(titleMetrics.advanceWidth(p.name))
      + Math.ceil(timeMetrics.advanceWidth(Model.format(Model.timeOf(p, now))))
      + Style.spacing.controlGap * 2 + buttonsWidth + panelChrome
  }), minPanelWidth, maxPanelWidth)

  // ------------------------------------------------------------ State

  // Data file from the widget setting `dataFile`; empty means the default.
  readonly property string home: Quickshell.env("HOME")
  // Short name used for folders, IPC and log lines. Renaming the plugin
  // means changing this, moduleName/ipcTarget above and manifest.json.
  readonly property string slug: "omahours"
  readonly property string defaultDataPath: home + "/.local/share/" + slug + "/projects.json"
  readonly property string dataPath: expandPath(setting("dataFile", "")) || defaultDataPath
  property string activePath: ""   // the file actually read and written
  property string dirReadyFor: ""    // activePath whose folder exists
  property string pendingWrite: ""    // a write waiting for its folder
  property bool started: false
  readonly property string heartbeatDir: home + "/.local/state/" + slug
  readonly property string heartbeatPath: heartbeatDir + "/heartbeat"
  property double heartbeat: 0
  property bool heartbeatLoaded: false

  property var store: Model.emptyState()
  property bool isLoaded: false
  property bool unreadable: false     // file unreadable: show it, never write it
  property string lastJson: ""
  property double now: Date.now()
  property double lastTick: 0
  property double lastUnlocked: 0
  property double lockQueryAt: 0
  // Project paused by the lock screen or a suspend; it resumes on unlock.
  // A project that was already paused before locking is never started.
  property string lockPausedName: ""

  // Settings, stored in this widget's entry in shell.json.
  readonly property bool pauseOnLock: setting("pauseOnLock", true) !== false
  readonly property bool coloredBar: setting("coloredBar", true) !== false
  property int settingsChoice: 0     // row under the cursor in the settings view

  // Applied locally first so the panel redraws at once; the shell.json write
  // comes back through the bar with the same value (as the Omarchy clock does).
  function persistSettings(values) {
    var entry = { id: moduleName }
    for (var k in settings) if (k !== "id") entry[k] = settings[k]
    for (var v in values) entry[v] = values[v]
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  function toggleSetting(i) {
    if (i === 0) persistSettings({ pauseOnLock: !pauseOnLock })
    else persistSettings({ coloredBar: !coloredBar })
  }

  readonly property int projectCount: store.projects.length
  readonly property int runningIndex: Model.runningIndex(store.projects)
  readonly property var lastProject: {
    var i = Model.findProject(store.projects, store.last)
    return store.last !== "" && i >= 0 ? store.projects[i] : null
  }

  readonly property string barText: unreadable ? "!"
    : (lastProject ? Model.format(Model.timeOf(lastProject, now)) : "0m")
  // Neutral bar: the color of the other bar icons, dimmed while paused.
  readonly property color barColor: unreadable ? errorRed
    : (!lastProject || !coloredBar ? (bar ? bar.barForeground : fg) : (lastProject.since > 0 ? green : darkRed))
  readonly property bool barDimmed: !unreadable && (!lastProject || (!coloredBar && lastProject.since <= 0))

  // ------------------------------------------------------------ Panel state

  property int selected: 0          // row under the cursor; projectCount = "+ New"
  property string mode: ""        // "", "edit", "new", "delete"
  property int modeIndex: -1
  property int deleteChoice: 0       // 0 Cancel, 1 Delete
  property bool showHelp: false
  property bool nameInvalid: false
  property bool timeInvalid: false
  property string timeAtEditStart: ""

  // ------------------------------------------------------------ File

  function mutate(fn) {
    if (!isLoaded || unreadable) return
    var s = Model.copyState(store)
    if (fn(s) === false) return
    store = s
    now = Date.now()
    saveState()
  }

  function saveState() {
    // Never overwrite an unreadable file: the data in it would be lost.
    if (unreadable) {
      console.warn(slug + ": " + activePath + " is unreadable, nothing saved")
      return
    }
    var json = Model.serialize(store)
    if (json === lastJson || activePath === "") return
    lastJson = json
    if (dirReadyFor === activePath) {
      dataFileView.setText(json)
      return
    }
    // The folder is created on the first write, so an unused default path
    // leaves nothing behind.
    pendingWrite = json
    makeDataDir.command = ["mkdir", "-p", dirOf(activePath)]
    makeDataDir.running = true
  }

  function expandPath(raw) {
    var p = String(raw || "").trim()
    if (p === "") return ""
    if (p === "~") return home
    if (p.indexOf("~/") === 0) return home + p.substring(1)
    if (p.indexOf("$HOME/") === 0) return home + p.substring(5)
    if (p.charAt(0) !== "/") return home + "/" + p
    return p
  }

  function dirOf(raw) {
    var i = raw.lastIndexOf("/")
    return i > 0 ? raw.substring(0, i) : "/"
  }

  // Switch to the configured file. Nothing from the previous file is carried
  // over, so a changed setting never writes one file's projects into another.
  function openDataFile() {
    if (activePath === dataPath) return
    isLoaded = false
    unreadable = false
    lastJson = ""
    pendingWrite = ""
    store = Model.emptyState()
    activePath = dataPath
    dataFileView.reload()
  }

  function ingest(text, readError) {
    var r = Model.check(text)
    var s = r.store
    var json = Model.serialize(s)
    unreadable = !!readError || !r.ok
    if (unreadable) console.warn(slug + ": " + activePath + " opened read-only (broken or unknown format)")
    if (isLoaded && json === lastJson) return
    store = s
    lastJson = json
    isLoaded = true
    now = Date.now()
    checkStale()
    clampSelection()
  }

  // Only once both the project file and the heartbeat file have been read.
  function checkStale() {
    if (!isLoaded || !heartbeatLoaded) return
    var s = Model.copyState(store)
    if (!Model.stopIfStale(s, heartbeat, Date.now())) return
    store = s
    saveState()
  }

  function beat(t) {
    heartbeat = t
    heartbeatFile.setText(String(Math.floor(t)) + "\n")
  }

  // Only one instance (the first) polls the lock screen and writes the heartbeat.
  function isFirstInstance() {
    var w = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    return w.length === 0 || w[0] === root
  }

  // Remembers the project only if one was running; a second pause while
  // locked (nothing running) keeps the remembered name.
  function pauseForLock(until) {
    var name = ""
    mutate(function(s) {
      name = Model.pauseRunning(s, until)
      return name !== ""
    })
    if (name !== "") lockPausedName = name
  }

  function resumeAfterLock(t) {
    if (lockPausedName === "") return
    var name = lockPausedName
    lockPausedName = ""
    mutate(function(s) { return Model.resume(s, name, t) })
    if (runningIndex >= 0) beat(t)
  }

  // ------------------------------------------------------------ Actions

  function toggleProject(i) {
    if (i < 0 || i >= projectCount) return
    var name = store.projects[i].name
    var t = Date.now()
    lockPausedName = ""
    mutate(function(s) { return Model.toggle(s, name, t) })
    if (runningIndex >= 0 && isFirstInstance()) beat(t)
  }

  function toggleLast() {
    if (!lastProject) return
    toggleProject(Model.findProject(store.projects, store.last))
  }

  function startEdit(i) {
    if (i < 0 || i >= projectCount) return
    resetMode()
    selected = i
    modeIndex = i
    mode = "edit"
  }

  function startSettings() {
    resetMode()
    settingsChoice = 0
    mode = "settings"
  }

  function startNew() {
    resetMode()
    selected = projectCount
    modeIndex = -1
    mode = "new"
  }

  function startDelete(i) {
    if (i < 0 || i >= projectCount) return
    resetMode()
    if (store.projects[i].since > 0) toggleProject(i)
    selected = i
    modeIndex = i
    deleteChoice = 0
    mode = "delete"
  }

  function deleteProject(i) {
    if (i < 0 || i >= projectCount) return
    mutate(function(s) {
      if (Model.nameKey(s.last) === Model.nameKey(s.projects[i].name)) s.last = ""
      s.projects.splice(i, 1)
    })
    cancelMode()
  }

  function saveEdit(i, nameText, timeText) {
    var name = String(nameText || "").trim()
    var match = Model.findProject(store.projects, name)
    var nameOk = name !== "" && (match < 0 || match === i)
    var parsed = null
    var timeOk = true
    if (i < 0 || String(timeText).trim() !== timeAtEditStart.trim()) {
      parsed = Model.parseInput(timeText)
      timeOk = parsed !== null
    }
    nameInvalid = !nameOk
    timeInvalid = !timeOk
    if (!nameOk || !timeOk) return

    var newIndex = i
    mutate(function(s) {
      var t = Date.now()
      if (i < 0) {
        s.projects.push({ name: name, ms: parsed ? Model.applyInput(0, parsed) : 0, since: 0 })
        if (s.last === "") s.last = name
        newIndex = s.projects.length - 1
        return
      }
      var p = s.projects[i]
      if (parsed) {
        p.ms = Model.applyInput(Model.timeOf(p, t), parsed)
        if (p.since > 0) p.since = t
      }
      if (s.last === p.name) s.last = name
      p.name = name
    })
    cancelMode()
    selected = newIndex
  }

  function resetMode() {
    mode = ""
    modeIndex = -1
    showHelp = false
    nameInvalid = false
    timeInvalid = false
  }

  function cancelMode() {
    resetMode()
    clampSelection()
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function clampSelection() {
    selected = Math.max(0, Math.min(projectCount, selected))
  }

  // ------------------------------------------------------------ Lifecycle

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    resetMode()
    if (!opened) return
    now = Date.now()
    var i = Model.findProject(store.projects, store.last)
    selected = i >= 0 ? i : 0
    clampSelection()
    if (flick) flick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onRunningIndexChanged: lastTick = Date.now()

  // Deferred so the bar has injected the widget settings first.
  Component.onCompleted: Qt.callLater(function() {
    root.started = true
    makeHeartbeatDir.running = true
    root.openDataFile()
  })
  onDataPathChanged: if (started) openDataFile()

  Process {
    id: makeHeartbeatDir
    command: ["mkdir", "-p", root.heartbeatDir]
    onExited: heartbeatFile.reload()
  }

  Process {
    id: makeDataDir
    onExited: function(code) {
      if (code !== 0) {
        console.warn(root.slug + ": cannot create folder for " + root.activePath)
        root.lastJson = ""
        return
      }
      root.dirReadyFor = root.activePath
      if (root.pendingWrite === "") return
      dataFileView.setText(root.pendingWrite)
      root.pendingWrite = ""
    }
  }

  FileView {
    id: heartbeatFile
    path: root.heartbeatPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var n = Number(String(text()).trim())
      root.heartbeat = isFinite(n) && n > 0 ? n : 0
      root.heartbeatLoaded = true
      root.checkStale()
    }
    onLoadFailed: {
      root.heartbeatLoaded = true
      root.checkStale()
    }
    onFileChanged: reload()
  }

  FileView {
    id: dataFileView
    path: root.activePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.dirReadyFor = root.activePath
      root.ingest(text(), false)
    }
    // Only "file not found" means empty; any other read error blocks writing.
    onLoadFailed: function(error) { root.ingest("", error !== FileViewError.FileNotFound) }
    onFileChanged: reload()
  }

  // Display: minutes are enough, the bar lags at most 5 s.
  Timer {
    interval: root.opened ? 1000 : 5000
    running: root.isLoaded && root.runningIndex >= 0
    repeat: true
    onTriggered: root.now = Date.now()
  }

  // Watch: suspend, heartbeat, lock screen.
  Timer {
    // Faster while waiting for the unlock, so a resumed project loses little time.
    interval: root.lockPausedName !== "" ? 3000 : 10000
    running: root.isLoaded && (root.runningIndex >= 0 || root.lockPausedName !== "")
    repeat: true
    onTriggered: {
      var t = Date.now()
      var isFirst = root.isFirstInstance()
      if (root.lastTick > 0 && t - root.lastTick > 45000) {
        var until = root.lastTick
        root.lastTick = t
        if (isFirst && root.pauseOnLock) root.pauseForLock(until)
        return
      }
      root.lastTick = t
      if (!isFirst) return
      if (root.runningIndex >= 0 && t - root.heartbeat >= 60000) root.beat(t)
      if ((root.pauseOnLock || root.lockPausedName !== "") && !lockQuery.running) {
        root.lockQueryAt = t
        lockQuery.running = true
      }
    }
  }

  Process {
    id: lockQuery
    command: ["omarchy-shell", "lock", "isLocked"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var answer = String(text || "").trim()
        if (answer === "false") {
          root.lastUnlocked = root.lockQueryAt
          root.resumeAfterLock(root.lockQueryAt)
        } else if (answer === "true" && root.pauseOnLock) {
          root.pauseForLock(root.lastUnlocked > 0 ? root.lastUnlocked : root.lockQueryAt)
        }
      }
    }
  }

  ShellIpc {
    target: root.slug

    // Start or pause the most recently used project (same as a right click).
    function toggle(): string {
      root.toggleLast()
      return root.lastProject ? (root.lastProject.since > 0 ? "running" : "paused") : "no project"
    }

    function status(): string {
      return JSON.stringify({ last: root.store.last, display: root.barText, heartbeat: root.heartbeat, unreadable: root.unreadable, file: root.activePath, settings: root.settings, state: root.store })
    }
  }

  // ------------------------------------------------------------ Bar

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    foreground: root.barColor
    dimmed: root.barDimmed
    useActiveColor: false
    tooltipText: root.unreadable ? strings.t("fileUnreadable").arg(root.activePath)
      : (root.lastProject ? root.lastProject.name : "")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleLast()
      else if (b === Qt.LeftButton) root.toggle()
    }
  }

  // ------------------------------------------------------------ Panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: panel.fittedContentHeight(listColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.mode === "edit" || root.mode === "new"

      onMoveRequested: function(dx, dy) {
        if (root.unreadable) return
        if (root.mode === "delete") {
          if (dx !== 0 || dy !== 0) root.deleteChoice = (dx > 0 || dy > 0) ? 1 : 0
          return
        }
        if (root.mode === "settings") {
          if (dy !== 0) root.settingsChoice = dy > 0 ? 1 : 0
          return
        }
        if (dy !== 0) {
          root.selected = Math.max(0, Math.min(root.projectCount, root.selected + dy))
          root.scrollToSelection()
        }
      }
      onActivateRequested: {
        if (root.unreadable) return
        if (root.mode === "delete") {
          if (root.deleteChoice === 1) root.deleteProject(root.modeIndex)
          else root.cancelMode()
          return
        }
        if (root.mode === "settings") {
          root.toggleSetting(root.settingsChoice)
          return
        }
        if (root.selected < root.projectCount) root.toggleProject(root.selected)
        else root.startNew()
      }
      onCloseRequested: {
        if (root.mode !== "") root.cancelMode()
        else root.close()
      }
      onDeleteRequested: if (root.mode === "" && !root.unreadable) root.startDelete(root.selected)
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.unreadable) return
        if (root.mode !== "") return
        if (t === "e") root.startEdit(root.selected)
        else if (t === "d") root.startDelete(root.selected)
        else if (t === "n") root.startNew()
        else if (t === "s") root.startSettings()
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: listColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: listColumn
          width: flick.width
          spacing: Style.space(4)

          // Unreadable file: only this message, no rows and no actions.
          Text {
            visible: root.unreadable
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            text: strings.t("fileUnreadablePanel").arg(root.activePath)
            color: root.errorRed
            font.family: root.fontName
            font.pixelSize: Style.font.body
            bottomPadding: Style.space(4)
          }

          Repeater {
            id: rows
            // Only the count: a start or pause changes the state while the
            // rows (and an open input field) stay in place.
            model: root.unreadable || root.mode === "settings" ? 0 : root.projectCount
            delegate: ProjectRow {}
          }

          // Settings view: replaces the list until the gear is clicked again.
          Column {
            visible: root.mode === "settings"
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: [
                { label: "settings.pauseOnLock", description: root.pauseOnLock ? "settings.pauseOnLock.on" : "settings.pauseOnLock.off" },
                { label: "settings.coloredBar", description: root.coloredBar ? "settings.coloredBar.on" : "settings.coloredBar.off" }
              ]
              delegate: Toggle {
                required property var modelData
                required property int index
                width: parent.width
                label: strings.t(modelData.label)
                description: strings.t(modelData.description)
                checked: index === 0 ? root.pauseOnLock : root.coloredBar
                foreground: root.fg
                fontFamily: root.fontName
                hasCursor: root.settingsChoice === index
                onHovered: function(on) { if (on) root.settingsChoice = index }
                onClicked: root.toggleSetting(index)
              }
            }
          }

          // Bottom row: "+ New" on the left, the settings gear on the right.
          Item {
            visible: root.mode !== "new" && !root.unreadable
            width: parent.width
            height: newButton.implicitHeight

          Button {
            id: newButton
            visible: root.mode !== "settings"
            anchors.left: parent.left
            anchors.right: gearButton.left
            anchors.rightMargin: Style.spacing.controlGap
            leftAlign: true
            iconText: "󰐕"
            text: strings.t("new")
            fontSize: Style.font.title
            iconSize: Style.font.iconLarge
            foreground: root.fg
            fontFamily: root.fontName
            hasCursor: root.mode === "" && root.selected === root.projectCount
            onHovered: function(on) { if (on && root.mode === "") root.selected = root.projectCount }
            onClicked: root.startNew()
          }

          ActionIcon {
            id: gearButton
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰒓"
            tooltipText: root.mode === "settings" ? strings.t("settings.back") : strings.t("settings")
            foreground: root.mode === "settings" ? root.fg : root.dimColor
            onClicked: root.mode === "settings" ? root.cancelMode() : root.startSettings()
          }
          }

          Loader {
            width: parent.width
            height: item ? item.implicitHeight : 0
            active: root.mode === "new"
            sourceComponent: Component { EditorRow { projectIndex: -1 } }
          }
        }
      }
    }
  }

  function scrollToSelection() {
    var item = selected < projectCount ? rows.itemAt(selected) : newButton
    if (!item || !flick) return
    Qt.callLater(function() {
      var topY = item.mapToItem(flick.contentItem, 0, 0).y
      var bottomY = topY + item.height
      var maxY = Math.max(0, flick.contentHeight - flick.height)
      if (topY < flick.contentY) flick.contentY = Math.max(0, topY)
      else if (bottomY > flick.contentY + flick.height) flick.contentY = Math.min(maxY, bottomY - flick.height)
    })
  }

  // ------------------------------------------------------------ Components

  component ActionIcon: PanelActionButton {
    foreground: root.fg
    fontFamily: root.fontName
    fontSize: Style.font.iconLarge
    Layout.alignment: Qt.AlignVCenter
  }

  // Enter and Esc are consumed here: after `accepted`, TextInput would pass
  // Enter on to the panel keys, which would start the project. Editing ends
  // deferred so the field is not destroyed inside its own key press.
  component InputField: TextField {
    property bool invalid: false
    signal saveRequested()
    foreground: root.fg
    font.family: root.fontName
    font.pixelSize: Style.font.title
    Keys.onEscapePressed: function(e) { e.accepted = true; Qt.callLater(root.cancelMode) }
    Keys.onReturnPressed: function(e) { e.accepted = true; Qt.callLater(saveRequested) }
    Keys.onEnterPressed: function(e) { e.accepted = true; Qt.callLater(saveRequested) }
    verticalPadding: 0
    verticalAlignment: TextInput.AlignVCenter
    Layout.preferredHeight: root.rowHeight

    Rectangle {
      anchors.fill: parent
      visible: parent.invalid
      color: "transparent"
      border.color: root.errorRed
      border.width: Math.max(2, Style.space(2))
      radius: Style.cornerRadius
    }
  }

  component ProjectRow: Column {
    id: row
    required property int index
    readonly property var p: root.store.projects[index] || ({ name: "", ms: 0, since: 0 })
    readonly property bool isRunning: p.since > 0
    readonly property bool isEditing: root.mode === "edit" && root.modeIndex === index
    readonly property bool isDeleting: root.mode === "delete" && root.modeIndex === index
    readonly property color rowColor: isRunning ? root.green : root.fg

    width: parent ? parent.width : 0
    spacing: Style.space(6)

    CursorSurface {
      id: surface
      visible: !row.isEditing
      width: parent.width
      height: Math.max(root.rowHeight, rowContent.implicitHeight + Style.spacing.controlPaddingY * 2)
      hasCursor: root.mode === "" && root.selected === row.index
      foreground: root.fg

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: if (root.mode === "") root.selected = row.index
        onClicked: if (root.mode === "") root.toggleProject(row.index)
      }

      RowLayout {
        id: rowContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: Style.spacing.controlPaddingY
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(4)
        spacing: Style.spacing.controlGap

        // Name on the left, using the free space; long names wrap, beyond
        // three lines they end with "…".
        Text {
          textFormat: Text.PlainText
          text: row.p.name
          color: row.rowColor
          font.family: root.fontName
          font.pixelSize: Style.font.title
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignTop
          topPadding: root.textOffset
        }

        // Times of all rows form a right-aligned column just before play/pause
        // (buttons are equally wide in every row, digits are tabular).
        Text {
          textFormat: Text.PlainText
          text: Model.format(Model.timeOf(row.p, root.now))
          color: row.rowColor
          font.family: root.fontName
          font.pixelSize: Style.font.title
          font.features: { "tnum": 1 }
          horizontalAlignment: Text.AlignRight
          Layout.alignment: Qt.AlignTop
          topPadding: root.textOffset
        }

        RowLayout {
          id: rowButtons
          spacing: Style.space(2)
          Layout.alignment: Qt.AlignTop
          Layout.topMargin: root.buttonOffset

          ActionIcon {
            iconText: row.isRunning ? "󰏤" : "󰐊"
            tooltipText: row.isRunning ? strings.t("pause") : strings.t("start")
            foreground: row.rowColor
            hoverColor: row.rowColor
            onClicked: root.toggleProject(row.index)
          }
          ActionIcon {
            iconText: "󰏫"
            tooltipText: strings.t("edit")
            onClicked: root.startEdit(row.index)
          }
          ActionIcon {
            iconText: "󰆴"
            tooltipText: strings.t("delete")
            hoverColor: root.errorRed
            onClicked: root.startDelete(row.index)
          }
        }
      }
    }

    Loader {
      width: parent.width
      height: item ? item.implicitHeight : 0
      active: row.isEditing
      sourceComponent: Component { EditorRow { projectIndex: row.index } }
    }

    Row {
      visible: row.isDeleting
      // Anchors follow LayoutMirroring in right-to-left languages; a plain x would not.
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      spacing: Style.spacing.controlGap
      bottomPadding: Style.space(4)

      Button {
        id: cancelButton
        text: strings.t("cancel")
        fontSize: Style.font.title
        foreground: root.fg
        fontFamily: root.fontName
        bordered: true
        hasCursor: root.deleteChoice === 0
        onHovered: function(on) { if (on) root.deleteChoice = 0 }
        onClicked: root.cancelMode()
      }

      // Shorten long names so "Delete" stays readable.
      TextMetrics {
        id: deleteName
        font.family: root.fontName
        font.pixelSize: Style.font.title
        text: row.p.name
        elide: Text.ElideRight
        elideWidth: Math.max(Style.space(40), row.width - Style.space(8) - cancelButton.implicitWidth
          - Style.spacing.controlGap - deleteRest.advanceWidth - Style.spacing.controlPaddingX * 2 - Style.space(8))
      }
      TextMetrics {
        id: deleteRest
        font.family: root.fontName
        font.pixelSize: Style.font.title
        text: strings.t("deleteNamed").arg("")
      }

      Button {
        id: deleteButton
        text: strings.t("deleteNamed").arg(deleteName.elidedText)
        fontSize: Style.font.title
        foreground: "#ffffff"
        fontFamily: root.fontName
        hasCursor: root.deleteChoice === 1
        color: hot ? Qt.lighter(root.darkRed, 1.25) : root.darkRed
        onHovered: function(on) { if (on) root.deleteChoice = 1 }
        onClicked: root.deleteProject(row.index)
      }
    }
  }

  // A row for creating or editing: name, time, check, question mark, cross.
  component EditorRow: ColumnLayout {
    id: editor
    property int projectIndex: -1
    spacing: Style.space(6)

    function submit() { root.saveEdit(projectIndex, nameField.text, timeField.text) }

    Component.onCompleted: {
      var p = projectIndex >= 0 ? root.store.projects[projectIndex] : null
      nameField.text = p ? p.name : ""
      timeField.text = p ? Model.format(Model.timeOf(p, Date.now())) : "0m"
      root.timeAtEditStart = timeField.text
      root.nameInvalid = false
      root.timeInvalid = false
      Qt.callLater(function() {
        if (p) { timeField.forceActiveFocus(); timeField.selectAll() }
        else nameField.forceActiveFocus()
      })
    }

    RowLayout {
      Layout.fillWidth: true
      Layout.preferredHeight: root.rowHeight
      spacing: Style.spacing.controlGap

      InputField {
        id: nameField
        Layout.fillWidth: true
        invalid: root.nameInvalid
        onTextChanged: root.nameInvalid = false
        onSaveRequested: editor.submit()
      }

      InputField {
        id: timeField
        Layout.preferredWidth: Style.space(92)
        invalid: root.timeInvalid
        onTextChanged: root.timeInvalid = false
        onSaveRequested: editor.submit()
      }

      RowLayout {
        spacing: Style.space(2)
        Layout.alignment: Qt.AlignVCenter

        ActionIcon { iconText: "󰄬"; tooltipText: strings.t("save"); onClicked: editor.submit() }
        ActionIcon {
          iconText: "󰘥"
          tooltipText: strings.t("help")
          foreground: root.showHelp ? root.fg : root.dimColor
          onClicked: root.showHelp = !root.showHelp
        }
        ActionIcon { iconText: "󰅖"; tooltipText: strings.t("cancel"); onClicked: root.cancelMode() }
      }
    }

    // Help: one rule per line, example on the left, effect on the right.
    GridLayout {
      visible: root.showHelp
      Layout.fillWidth: true
      Layout.leftMargin: Style.space(8)
      Layout.bottomMargin: Style.space(4)
      columns: 2
      columnSpacing: Style.space(12)
      rowSpacing: Style.space(2)

      // Example and effect alternate so each rule fills one grid row.
      Repeater {
        model: ["help.set.example", "help.set", "help.add.example", "help.add",
          "help.subtract.example", "help.subtract",
          "help.reset.example", "help.reset"]
        delegate: HelpText {
          required property string modelData
          required property int index
          text: strings.t(modelData)
          color: index % 2 === 0 ? root.fg : root.dimColor
        }
      }
      HelpText { Layout.columnSpan: 2; text: strings.t("help.keys") }
    }
  }

  component HelpText: Text {
    textFormat: Text.PlainText
    color: root.dimColor
    font.family: root.fontName
    font.pixelSize: Style.font.bodySmall
  }
}
